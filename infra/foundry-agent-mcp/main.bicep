/*
  Foundry Standard Agent Setup (E2E network isolation) + private MCP tool subnet.
  ----------------------------------------------------------------------------
  Models Microsoft reference template 19 (private-network-agent-tools), tailored
  for this MCAPS subscription (Entra-only / disableLocalAuth everywhere) and the
  existing rg-nsp-demo. Region must equal the VNet region and be Agent-Service
  capable -> eastus.

  Deploy in two passes:
    Pass 1 (deployCapabilityHost=false): VNet (agent/pe/mcp subnets), Foundry
            account w/ networkInjections, model, Cosmos/Storage/Search, all
            private endpoints + DNS, project + connections + role assignments.
    Pass 2 (deployCapabilityHost=true): the project capability host (binds the
            three connections; needs the RBAC from pass 1 to have propagated).

  The MCP server (FastAPI on Container Apps, internal ingress on the mcp subnet)
  and the agent itself are created out-of-band after the infra is up.
*/

@description('Region for all resources. Must be an Agent-Service region and match the VNet region.')
@allowed([
  'eastus'
  'eastus2'
  'westus'
  'westus3'
])
param location string = 'eastus'

@description('Lowercase prefix (2-8 chars) for resource names; a short hash suffix is appended.')
@minLength(2)
@maxLength(8)
param namePrefix string = 'fdyagt'

@description('Chat model to deploy for the agent.')
param modelName string = 'gpt-4o-mini'
param modelFormat string = 'OpenAI'
param modelVersion string = '2024-07-18'
param modelSkuName string = 'GlobalStandard'
param modelCapacity int = 30

@description('Cosmos DB region. eastus is capacity-constrained for Cosmos (AZ) -> default to eastus2; PE is still placed in the eastus VNet cross-region.')
param cosmosLocation string = 'eastus2'

@description('Create the Foundry account private endpoint. Keep false in the main deploy (it races the account network-injection settle); deploy it via foundry-pe.bicep once the account is stable.')
param deployFoundryPe bool = false

@description('VNet address space (RFC1918). Class A 10.x is supported in eastus.')
param vnetAddressPrefix string = '10.50.0.0/16'
param agentSubnetPrefix string = '10.50.0.0/24'
param peSubnetPrefix string = '10.50.1.0/24'
param mcpSubnetPrefix string = '10.50.2.0/24'

@description('Pass 2 switch: create the project capability host once pass-1 RBAC has propagated.')
param deployCapabilityHost bool = false

@description('Optional: object id of a user to grant data-plane roles (Foundry/Search/Cosmos/Storage) for local testing. Empty = skip.')
param developerObjectId string = ''

// --- Names ------------------------------------------------------------------
var token = substring(uniqueString(resourceGroup().id, 'foundry-agent-mcp'), 0, 6)
var accountName = toLower('${namePrefix}${token}')
var projectName = toLower('proj${token}')
var cosmosName = toLower('cos${token}')
var storageName = toLower('stag${token}')
var searchName = toLower('srchag${token}')
var projectCapHost = 'caphost${token}'

var agentSubnetName = 'snet-agent'
var peSubnetName = 'snet-pe'
var mcpSubnetName = 'snet-mcp'

// --- Built-in role definition ids ------------------------------------------
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleStorageBlobDataOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'
var roleCosmosOperator = '230815da-be43-4aae-9cb4-875f7bd000aa'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'

// --- DNS zone names ---------------------------------------------------------
var dnsOpenAi = 'privatelink.openai.azure.com'
var dnsCognitive = 'privatelink.cognitiveservices.azure.com'
var dnsServicesAi = 'privatelink.services.ai.azure.com'
var dnsCosmos = 'privatelink.documents.azure.com'
var dnsBlob = 'privatelink.blob.${environment().suffixes.storage}'
var dnsSearch = 'privatelink.search.windows.net'

// ============================================================================
// Network
// ============================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-agent-${token}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: mcpSubnetName
        properties: {
          addressPrefix: mcpSubnetPrefix
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
    ]
  }
}

resource agentSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: agentSubnetName
}
resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: peSubnetName
}

// Private DNS zones + VNet links
var dnsZoneNames = [
  dnsOpenAi
  dnsCognitive
  dnsServicesAi
  dnsCosmos
  dnsBlob
  dnsSearch
]
resource dnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for z in dnsZoneNames: {
  name: z
  location: 'global'
}]
resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (z, i) in dnsZoneNames: {
  parent: dnsZones[i]
  name: 'link-${token}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

// ============================================================================
// Foundry account (network injection) + model + project
// ============================================================================
#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: 'Deny'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    publicNetworkAccess: 'Disabled'
    networkInjections: [
      {
        scenario: 'agent'
        subnetArmId: agentSubnet.id
        useMicrosoftManagedNetwork: false
      }
    ]
    disableLocalAuth: true
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: modelName
  sku: {
    name: modelSkuName
    capacity: modelCapacity
  }
  properties: {
    model: {
      name: modelName
      format: modelFormat
      version: modelVersion
    }
  }
}

// Foundry private endpoint (groupId 'account') + DNS group.
// Gated: deploying it inside this template races the account's network-injection
// settle (the account PUT flips to 'Accepted' each run). Deploy via foundry-pe.bicep
// once the account is stable.
resource accountPe 'Microsoft.Network/privateEndpoints@2024-05-01' = if (deployFoundryPe) {
  name: 'pe-foundry-${token}'
  location: location
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-foundry-${token}'
        properties: {
          privateLinkServiceId: account.id
          groupIds: ['account']
        }
      }
    ]
  }
}
resource accountPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (deployFoundryPe) {
  parent: accountPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'openai', properties: { privateDnsZoneId: dnsZones[0].id } }
      { name: 'cognitive', properties: { privateDnsZoneId: dnsZones[1].id } }
      { name: 'servicesai', properties: { privateDnsZoneId: dnsZones[2].id } }
    ]
  }
}

// ============================================================================
// BYO data resources (Cosmos / Storage / Search) - all Entra-only + private
// ============================================================================
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-12-01-preview' = {
  name: cosmosName
  location: cosmosLocation
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    minimalTlsVersion: 'Tls12'
    publicNetworkAccess: 'Disabled'
    locations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}
resource cosmosPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-cosmos-${token}'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'pe-cosmos-${token}'
        properties: {
          privateLinkServiceId: cosmos.id
          groupIds: ['Sql']
        }
      }
    ]
  }
}
resource cosmosPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: cosmosPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'cosmos', properties: { privateDnsZoneId: dnsZones[3].id } }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}
resource storagePe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-stg-${token}'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'pe-stg-${token}'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}
resource storagePeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: storagePe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'blob', properties: { privateDnsZoneId: dnsZones[4].id } }
    ]
  }
}

resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: searchName
  location: location
  sku: {
    name: 'basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
    authOptions: null
  }
}
resource searchPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-search-${token}'
  location: location
  properties: {
    subnet: { id: peSubnet.id }
    privateLinkServiceConnections: [
      {
        name: 'pe-search-${token}'
        properties: {
          privateLinkServiceId: search.id
          groupIds: ['searchService']
        }
      }
    ]
  }
}
resource searchPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: searchPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'search', properties: { privateDnsZoneId: dnsZones[5].id } }
    ]
  }
}

// ============================================================================
// Project + connections (Cosmos / Storage / Search), Entra (AAD) auth
// ============================================================================
resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Network-secured agent project with private MCP tool'
    displayName: projectName
  }

  resource connCosmos 'connections@2025-04-01-preview' = {
    name: cosmosName
    properties: {
      category: 'CosmosDB'
      target: cosmos.properties.documentEndpoint
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: cosmos.id
        location: cosmos.location
      }
    }
  }

  resource connStorage 'connections@2025-04-01-preview' = {
    name: storageName
    properties: {
      category: 'AzureStorageAccount'
      target: storage.properties.primaryEndpoints.blob
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: storage.id
        location: storage.location
      }
    }
    dependsOn: [connCosmos]
  }

  resource connSearch 'connections@2025-04-01-preview' = {
    name: searchName
    properties: {
      category: 'CognitiveSearch'
      target: 'https://${searchName}.search.windows.net'
      authType: 'AAD'
      metadata: {
        ApiType: 'Azure'
        ResourceId: search.id
        location: search.location
      }
    }
    dependsOn: [connStorage]
  }
}

// ============================================================================
// Role assignments: project MI -> data resources (required before caphost)
// ============================================================================
resource raSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, project.id, roleSearchIndexDataContributor)
  scope: search
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalType: 'ServicePrincipal'
  }
}
resource raSearchService 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, project.id, roleSearchServiceContributor)
  scope: search
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalType: 'ServicePrincipal'
  }
}
resource raStorageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, project.id, roleStorageBlobDataOwner)
  scope: storage
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataOwner)
    principalType: 'ServicePrincipal'
  }
}
resource raCosmosOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(cosmos.id, project.id, roleCosmosOperator)
  scope: cosmos
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCosmosOperator)
    principalType: 'ServicePrincipal'
  }
}
// Cosmos data-plane (SQL) role: Built-in Data Contributor for the project MI.
resource cosmosDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-12-01-preview' = {
  parent: cosmos
  name: guid(cosmos.id, project.id, '00000000-0000-0000-0000-000000000002')
  properties: {
    principalId: project.identity.principalId
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    scope: cosmos.id
  }
}

// Optional developer data-plane roles for local testing.
resource raDevOpenAi 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (developerObjectId != '') {
  name: guid(account.id, developerObjectId, roleCognitiveServicesOpenAIUser)
  scope: account
  properties: {
    principalId: developerObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalType: 'User'
  }
}
resource raDevCogUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (developerObjectId != '') {
  name: guid(account.id, developerObjectId, roleCognitiveServicesUser)
  scope: account
  properties: {
    principalId: developerObjectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalType: 'User'
  }
}

// ============================================================================
// Capability host (Pass 2)
// ============================================================================
#disable-next-line BCP081
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = if (deployCapabilityHost) {
  parent: project
  name: projectCapHost
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    threadStorageConnections: [cosmosName]
    storageConnections: [storageName]
    vectorStoreConnections: [searchName]
  }
  dependsOn: [
    raSearchIndex
    raSearchService
    raStorageBlob
    raCosmosOperator
    cosmosDataContributor
  ]
}

// ============================================================================
// Outputs
// ============================================================================
output accountNameOut string = accountName
output projectNameOut string = projectName
output projectEndpoint string = 'https://${accountName}.services.ai.azure.com/api/projects/${projectName}'
output vnetName string = vnet.name
output mcpSubnetId string = '${vnet.id}/subnets/${mcpSubnetName}'
output agentSubnetId string = agentSubnet.id
output cosmosNameOut string = cosmosName
output storageNameOut string = storageName
output searchNameOut string = searchName
output modelNameOut string = modelName
