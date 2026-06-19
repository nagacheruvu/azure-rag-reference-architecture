@description('Primary Azure region for all resources.')
param location string

@description('Deterministic token used to build globally-unique resource names.')
param resourceToken string

@description('Tags applied to every resource.')
param tags object

@description('Object ID of the signed-in user/principal for local-dev data-plane roles.')
param principalId string

@description('Production posture toggle (replicas / partitions).')
param isProduction bool

@description('Provision a Service Bus namespace for optional priority lanes.')
param deployServiceBus bool

@description('Name of the Azure AI Search index the API queries for RAG grounding.')
param searchIndexName string = 'askmaya-index'

@description('Azure AI Search SKU. Empty => basic (MVP) / standard (prod). Set to standard, standard2, etc. to scale for a large corpus.')
param searchSkuName string = ''

@description('Provision an APIM AI-gateway + second-region Azure OpenAI for resiliency.')
param deployApim bool = false

@description('Secondary Azure region for the failover Azure OpenAI account.')
param secondaryLocation string = 'eastus2'

@description('APIM SKU.')
param apimSkuName string = 'Basicv2'

@description('Publisher email for APIM.')
param apimPublisherEmail string = 'admin@example.com'

@description('Publisher organization name for APIM.')
param apimPublisherName string = 'Ask Maya'

@description('Per-minute token cap enforced by the APIM gateway.')
param apimTokensPerMinute int = 200000

@description('Provision an Azure Front Door (Standard) in front of the web app for global entry + failover.')
param deployFrontDoor bool = false

@description('Front Door SKU. Standard_AzureFrontDoor is the low-cost test tier.')
param frontDoorSkuName string = 'Standard_AzureFrontDoor'

@description('Multi-region resiliency: Cosmos goes provisioned/autoscale multi-region with automatic failover, plus a standby Azure AI Search in the secondary region. (AOAI failover is driven by deployApim, which main.bicep ORs with this flag.)')
param deployMultiRegion bool = false

// Built-in role definition IDs
var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleStorageBlobDataReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleKeyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var roleKeyVaultSecretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var roleAppConfigDataReader = '516239f1-63e1-4d78-a4de-a74fb236a071'
var roleAppConfigDataOwner = '5ae67dd6-50cb-40e7-96ff-dc2bfa4b606b'
var cosmosDataContributorRoleId = '00000000-0000-0000-0000-000000000002'

var hasPrincipal = !empty(principalId)

// User-assigned managed identity (used by the API container app)
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'azid${resourceToken}'
  location: location
  tags: tags
}

// Monitoring
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'azlog${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'azappi${resourceToken}'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
  }
}

// Container registry (azd pushes the API image here)
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: 'azcr${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerRegistry.id, uami.id, roleAcrPull)
  scope: containerRegistry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAcrPull)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Document landing zone
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'azst${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource documentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'documents'
  properties: {
    publicAccess: 'None'
  }
}

resource storageBlobUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, uami.id, roleStorageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Signed-in user gets blob write access so they can upload documents from their machine.
resource storageBlobUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(storage.id, principalId, roleStorageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: principalId
    principalType: 'User'
  }
}

// Azure AI Search (vector + semantic)
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'azsrch${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: !empty(searchSkuName) ? searchSkuName : (isProduction ? 'standard' : 'basic')
  }
  properties: {
    replicaCount: isProduction ? 2 : 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'standard'
    authOptions: null
    disableLocalAuth: true
  }
  identity: {
    type: 'SystemAssigned'
  }
}

resource searchIndexUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, uami.id, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// The search service's system identity reads blobs during indexing (keyless data source).
resource searchStorageReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, search.id, roleStorageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchServiceUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(search.id, principalId, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: principalId
    principalType: 'User'
  }
}

// --- Resiliency: second-region Azure AI Search (optional) -------------------------------
// Standby search service in the secondary region so the API can fail reads over when the
// primary search region is unavailable. Index replication is a data-plane step (re-run the
// indexer against this service); infra provisions the service + the same keyless roles the
// primary search has (index data contributor for the API identity, blob reader + OpenAI user
// for this service's own identity to (re)build the vector index).
resource searchSecondary 'Microsoft.Search/searchServices@2024-06-01-preview' = if (deployMultiRegion) {
  name: 'azsrch2${resourceToken}'
  location: secondaryLocation
  tags: tags
  sku: {
    name: !empty(searchSkuName) ? searchSkuName : (isProduction ? 'standard' : 'basic')
  }
  properties: {
    replicaCount: isProduction ? 2 : 1
    partitionCount: 1
    hostingMode: 'default'
    semanticSearch: 'standard'
    disableLocalAuth: true
  }
  identity: {
    type: 'SystemAssigned'
  }
}

resource searchIndexUamiSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployMultiRegion) {
  name: guid('search2', uami.id, roleSearchIndexDataContributor)
  scope: searchSecondary
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource searchStorageReaderSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployMultiRegion) {
  name: guid('search2', storage.id, roleStorageBlobDataReader)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataReader)
    principalId: searchSecondary!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource openaiSearchAccessSecondary 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployMultiRegion) {
  name: guid('search2', openai.id, roleCognitiveServicesOpenAIUser)
  scope: openai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: searchSecondary!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Azure OpenAI (gpt-5.4-mini + embeddings)
resource openai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'azcog${resourceToken}'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: 'azcog${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openai
  name: 'gpt-5.4-mini'
  sku: {
    name: 'GlobalStandard'
    capacity: isProduction ? 50 : 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-mini'
      version: '2026-03-17'
    }
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: openai
  name: 'text-embedding-3-small'
  sku: {
    name: 'GlobalStandard'
    capacity: isProduction ? 50 : 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
  }
  dependsOn: [
    chatDeployment
  ]
}

resource openaiUserUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openai.id, uami.id, roleCognitiveServicesOpenAIUser)
  scope: openai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource openaiSearchAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(openai.id, search.id, roleCognitiveServicesOpenAIUser)
  scope: openai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Resiliency: second-region Azure OpenAI + APIM AI-gateway (optional) ----------------
// Deployed only when deployApim is true. Identical model deployments in a second region give
// the APIM backend pool somewhere to fail over when the primary is throttled (429) or down.
resource openaiSecondary 'Microsoft.CognitiveServices/accounts@2024-10-01' = if (deployApim) {
  name: 'azcog2${resourceToken}'
  location: secondaryLocation
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: 'azcog2${resourceToken}'
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

// Deployment NAME must match the primary so the APIM gateway can fail a request for
// 'gpt-5.4-mini' over to this backend without a 404. (Confirm the model is available in
// secondaryLocation; this whole branch is gated behind the optional resiliency flag.)
resource chatDeploymentSecondary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployApim) {
  parent: openaiSecondary
  name: 'gpt-5.4-mini'
  sku: {
    name: 'GlobalStandard'
    capacity: isProduction ? 50 : 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-mini'
      version: '2026-03-17'
    }
  }
}

resource embeddingDeploymentSecondary 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = if (deployApim) {
  parent: openaiSecondary
  name: 'text-embedding-3-small'
  sku: {
    name: 'Standard'
    capacity: isProduction ? 50 : 10
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
  }
  dependsOn: [
    chatDeploymentSecondary
  ]
}

module apim 'apim.bicep' = if (deployApim) {
  name: 'apim'
  params: {
    name: 'azapim${resourceToken}'
    location: location
    skuName: apimSkuName
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
    tenantId: subscription().tenantId
    primaryAoaiHost: '${openai.name}.openai.azure.com'
    secondaryAoaiHost: '${openaiSecondary.name}.openai.azure.com'
    tokensPerMinute: apimTokensPerMinute
    tags: tags
  }
}

// APIM's managed identity needs OpenAI access on BOTH accounts so it can mint backend tokens.
resource apimOpenaiPrimaryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApim) {
  name: guid(openai.id, 'apim', roleCognitiveServicesOpenAIUser)
  scope: openai
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: deployApim ? apim!.outputs.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

resource apimOpenaiSecondaryAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployApim) {
  name: guid(openaiSecondary.id, 'apim', roleCognitiveServicesOpenAIUser)
  scope: openaiSecondary
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: deployApim ? apim!.outputs.principalId : ''
    principalType: 'ServicePrincipal'
  }
}

// Cosmos DB (chat history) — serverless for MVP, provisioned multi-region when resiliency is on.
// Serverless accounts are single-region only, so the multi-region posture switches to autoscale
// provisioned throughput with an automatic-failover read replica in the secondary region.
var cosmosLocations = deployMultiRegion ? [
  {
    locationName: location
    failoverPriority: 0
    isZoneRedundant: false
  }
  {
    locationName: secondaryLocation
    failoverPriority: 1
    isZoneRedundant: false
  }
] : [
  {
    locationName: location
    failoverPriority: 0
    isZoneRedundant: false
  }
]

resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-11-15' = {
  name: 'azcosmos${resourceToken}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    enableFreeTier: false
    capabilities: deployMultiRegion ? [] : [
      {
        name: 'EnableServerless'
      }
    ]
    enableAutomaticFailover: deployMultiRegion
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: cosmosLocations
    ipRules: [
      {
        ipAddressOrRange: '0.0.0.0'
      }
    ]
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-11-15' = {
  parent: cosmos
  name: 'askmaya'
  properties: {
    resource: {
      id: 'askmaya'
    }
    // Serverless ignores throughput; multi-region (provisioned) needs db-level autoscale.
    options: deployMultiRegion ? {
      autoscaleSettings: {
        maxThroughput: 1000
      }
    } : {}
  }
}

resource chatHistoryContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-11-15' = {
  parent: cosmosDb
  name: 'chat_history'
  properties: {
    resource: {
      id: 'chat_history'
      partitionKey: {
        paths: [
          '/sessionId'
        ]
        kind: 'Hash'
      }
    }
  }
}

resource cosmosDataUami 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = {
  parent: cosmos
  name: guid(cosmos.id, uami.id, cosmosDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributorRoleId}'
    principalId: uami.properties.principalId
    scope: cosmos.id
  }
}

resource cosmosDataUser 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-11-15' = if (hasPrincipal) {
  parent: cosmos
  name: guid(cosmos.id, principalId, cosmosDataContributorRoleId)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributorRoleId}'
    principalId: principalId
    scope: cosmos.id
  }
}

// Key Vault (RBAC, secretless app config refs)
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'azkv${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource kvSecretsOfficerUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, uami.id, roleKeyVaultSecretsOfficer)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsOfficer)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource kvSecretsUserUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, uami.id, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// App Configuration (env parity, feature flags)
resource appConfig 'Microsoft.AppConfiguration/configurationStores@2024-05-01' = {
  name: 'azappcs${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Free'
  }
  properties: {
    disableLocalAuth: true
    dataPlaneProxy: {
      authenticationMode: 'Pass-through'
    }
    publicNetworkAccess: 'Enabled'
  }
}

resource appConfigReaderUami 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appConfig.id, uami.id, roleAppConfigDataReader)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAppConfigDataReader)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource appConfigOwnerUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(appConfig.id, principalId, roleAppConfigDataOwner)
  scope: appConfig
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleAppConfigDataOwner)
    principalId: principalId
    principalType: 'User'
  }
}

// Optional Service Bus (priority/standard async lanes)
resource serviceBus 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = if (deployServiceBus) {
  name: 'azsb${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
}

resource priorityQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBus
  name: 'priority'
}

resource standardQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = if (deployServiceBus) {
  parent: serviceBus
  name: 'standard'
}

// Container Apps environment + API
resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'azcae${resourceToken}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    zoneRedundant: isProduction
  }
}

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'azca${resourceToken}'
  location: location
  tags: union(tags, {
    'azd-service-name': 'api'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        corsPolicy: {
          allowedOrigins: [
            '*'
          ]
          allowedMethods: [
            'GET'
            'POST'
            'OPTIONS'
          ]
          allowedHeaders: [
            '*'
          ]
        }
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'api'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          env: [
            {
              name: 'AZURE_CLIENT_ID'
              value: uami.properties.clientId
            }
            {
              name: 'AZURE_OPENAI_ENDPOINT'
              value: deployApim ? apim!.outputs.gatewayUrl : openai.properties.endpoint
            }
            {
              name: 'AZURE_OPENAI_CHAT_DEPLOYMENT'
              value: chatDeployment.name
            }
            {
              name: 'AZURE_OPENAI_EMBEDDING_DEPLOYMENT'
              value: embeddingDeployment.name
            }
            {
              name: 'AZURE_SEARCH_ENDPOINT'
              value: 'https://${search.name}.search.windows.net'
            }
            {
              name: 'AZURE_SEARCH_INDEX'
              value: searchIndexName
            }
            {
              // Standby search endpoint the API can fail reads over to (empty unless multi-region).
              name: 'AZURE_SEARCH_ENDPOINT_SECONDARY'
              value: deployMultiRegion ? 'https://${searchSecondary!.name}.search.windows.net' : ''
            }
            {
              name: 'SEMANTIC_CACHE_ENABLED'
              value: 'true'
            }
            {
              name: 'AZURE_COSMOS_ENDPOINT'
              value: cosmos.properties.documentEndpoint
            }
            {
              name: 'AZURE_COSMOS_DATABASE'
              value: cosmosDb.name
            }
            {
              name: 'AZURE_COSMOS_CONTAINER'
              value: chatHistoryContainer.name
            }
            {
              name: 'AZURE_APP_CONFIG_ENDPOINT'
              value: appConfig.properties.endpoint
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
          ]
        }
      ]
      scale: {
        minReplicas: isProduction ? 2 : 0
        maxReplicas: 10
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: '50'
              }
            }
          }
        ]
      }
    }
  }
  dependsOn: [
    acrPullAssignment
  ]
}

// Blazor Server web app on Container Apps.
// App Service (Basic/Free) is blocked on this subscription's zero-VM quota, so the stateful
// Blazor Server UI runs as a Container App. Sticky sessions keep each SignalR circuit pinned
// to one replica; min 1 replica keeps active circuits alive (no scale-to-zero mid-conversation).
resource webApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'azweb${resourceToken}'
  location: location
  tags: union(tags, {
    'azd-service-name': 'web'
  })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
        // Pin each Blazor SignalR circuit to a single replica.
        stickySessions: {
          affinity: 'sticky'
        }
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: uami.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'web'
          image: 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: json('0.5')
            memory: '1.0Gi'
          }
          env: [
            {
              name: 'ApiBase'
              value: 'https://${apiApp.properties.configuration.ingress.fqdn}'
            }
            {
              name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
              value: appInsights.properties.ConnectionString
            }
            {
              name: 'ASPNETCORE_ENVIRONMENT'
              value: 'Production'
            }
            {
              // Honor X-Forwarded-Proto from the ingress so HTTPS redirect doesn't loop.
              name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED'
              value: 'true'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: isProduction ? 5 : 2
      }
    }
  }
  dependsOn: [
    acrPullAssignment
  ]
}

// Front Door (Standard) — optional global entry in front of the web app.
module frontDoor 'frontdoor.bicep' = if (deployFrontDoor) {
  name: 'frontdoor'
  params: {
    name: 'azfd${resourceToken}'
    skuName: frontDoorSkuName
    resourceToken: resourceToken
    webHostName: webApp.properties.configuration.ingress.fqdn
    tags: tags
  }
}

output AZURE_CONTAINER_REGISTRY_ENDPOINT string = containerRegistry.properties.loginServer
output AZURE_CONTAINER_APP_ENDPOINT string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output AZURE_WEB_APP_ENDPOINT string = 'https://${webApp.properties.configuration.ingress.fqdn}'
output AZURE_FRONT_DOOR_ENDPOINT string = deployFrontDoor ? 'https://${frontDoor!.outputs.endpointHostName}' : ''
output AZURE_OPENAI_ENDPOINT string = openai.properties.endpoint
output AZURE_OPENAI_GATEWAY_URL string = deployApim ? apim!.outputs.gatewayUrl : ''
output AZURE_OPENAI_EMBEDDING_DEPLOYMENT string = embeddingDeployment.name
output AZURE_SEARCH_ENDPOINT string = 'https://${search.name}.search.windows.net'
output AZURE_SEARCH_ENDPOINT_SECONDARY string = deployMultiRegion ? 'https://${searchSecondary!.name}.search.windows.net' : ''
output AZURE_SEARCH_INDEX string = searchIndexName
output AZURE_MULTI_REGION_ENABLED bool = deployMultiRegion
output AZURE_STORAGE_ACCOUNT string = storage.name
output AZURE_STORAGE_BLOB_ENDPOINT string = storage.properties.primaryEndpoints.blob
output AZURE_STORAGE_RESOURCE_ID string = storage.id
output AZURE_STORAGE_CONTAINER string = documentsContainer.name
output AZURE_COSMOS_ENDPOINT string = cosmos.properties.documentEndpoint
output AZURE_APP_CONFIG_ENDPOINT string = appConfig.properties.endpoint
output AZURE_KEY_VAULT_ENDPOINT string = keyVault.properties.vaultUri
output APPLICATIONINSIGHTS_CONNECTION_STRING string = appInsights.properties.ConnectionString
