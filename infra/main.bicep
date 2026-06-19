// yaml-language-server: $schema=https://raw.githubusercontent.com/Azure/azure-dev/refs/heads/main/schemas/v1.0/azure.yaml.json
targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the azd environment — used to derive resource names and tags.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Object ID of the signed-in user/principal — granted data-plane roles for local dev (App Config, Search, Cosmos).')
param principalId string = ''

@description('Provision a zone-redundant / multi-replica posture (prod). When false, runs the cheap MVP posture.')
param isProduction bool = false

@description('Provision a Service Bus namespace for optional priority/standard async lanes.')
param deployServiceBus bool = false

@description('Provision an APIM AI-gateway + a second-region Azure OpenAI account for resiliency (circuit breaker, retry, token-limit failover). Off by default to keep the MVP cheap.')
param deployApim bool = false

@description('Secondary Azure region for the failover Azure OpenAI account (used only when deployApim is true).')
param secondaryLocation string = 'eastus2'

@description('APIM SKU (used only when deployApim is true).')
param apimSkuName string = 'Basicv2'

@description('Publisher email for APIM (used only when deployApim is true).')
param apimPublisherEmail string = 'admin@example.com'

@description('Publisher organization name for APIM.')
param apimPublisherName string = 'Ask Maya'

@description('Per-minute token cap enforced by the APIM gateway.')
param apimTokensPerMinute int = 200000

@description('Azure AI Search SKU. Empty => basic (MVP) / standard (prod). Set to standard, standard2, etc. for a large (10-50 GB) corpus.')
param searchSkuName string = ''

@description('Name of the Azure AI Search index used for RAG grounding.')
param searchIndexName string = 'askmaya-index'

@description('Provision an Azure Front Door (Standard) in front of the web app. Off by default.')
param deployFrontDoor bool = false

@description('Front Door SKU. Standard_AzureFrontDoor is the low-cost test tier.')
param frontDoorSkuName string = 'Standard_AzureFrontDoor'

@description('Optional multi-region resiliency. When true: routes Azure OpenAI through the APIM gateway with a second-region failover account, and makes Cosmos DB multi-region (autoscale + automatic failover) with a standby Azure AI Search in the secondary region. Off by default to keep the MVP cheap and single-region.')
param deployMultiRegion bool = false

var resourceToken = uniqueString(subscription().id, location, environmentName)
var tags = {
  'azd-env-name': environmentName
  project: 'askmaya'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  scope: rg
  params: {
    location: location
    resourceToken: resourceToken
    tags: tags
    principalId: principalId
    isProduction: isProduction
    deployServiceBus: deployServiceBus
    deployApim: deployApim || deployMultiRegion
    deployMultiRegion: deployMultiRegion
    secondaryLocation: secondaryLocation
    apimSkuName: apimSkuName
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    apimTokensPerMinute: apimTokensPerMinute
    searchSkuName: searchSkuName
    searchIndexName: searchIndexName
    deployFrontDoor: deployFrontDoor
    frontDoorSkuName: frontDoorSkuName
  }
}

output RESOURCE_GROUP_ID string = rg.id
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = resources.outputs.AZURE_CONTAINER_REGISTRY_ENDPOINT
output AZURE_CONTAINER_APP_ENDPOINT string = resources.outputs.AZURE_CONTAINER_APP_ENDPOINT
output AZURE_WEB_APP_ENDPOINT string = resources.outputs.AZURE_WEB_APP_ENDPOINT
output AZURE_FRONT_DOOR_ENDPOINT string = resources.outputs.AZURE_FRONT_DOOR_ENDPOINT
output AZURE_OPENAI_ENDPOINT string = resources.outputs.AZURE_OPENAI_ENDPOINT
output AZURE_OPENAI_GATEWAY_URL string = resources.outputs.AZURE_OPENAI_GATEWAY_URL
output AZURE_SEARCH_ENDPOINT string = resources.outputs.AZURE_SEARCH_ENDPOINT
output AZURE_SEARCH_INDEX string = resources.outputs.AZURE_SEARCH_INDEX
output AZURE_OPENAI_EMBEDDING_DEPLOYMENT string = resources.outputs.AZURE_OPENAI_EMBEDDING_DEPLOYMENT
output AZURE_STORAGE_ACCOUNT string = resources.outputs.AZURE_STORAGE_ACCOUNT
output AZURE_STORAGE_BLOB_ENDPOINT string = resources.outputs.AZURE_STORAGE_BLOB_ENDPOINT
output AZURE_STORAGE_RESOURCE_ID string = resources.outputs.AZURE_STORAGE_RESOURCE_ID
output AZURE_STORAGE_CONTAINER string = resources.outputs.AZURE_STORAGE_CONTAINER
output AZURE_COSMOS_ENDPOINT string = resources.outputs.AZURE_COSMOS_ENDPOINT
output AZURE_APP_CONFIG_ENDPOINT string = resources.outputs.AZURE_APP_CONFIG_ENDPOINT
output AZURE_KEY_VAULT_ENDPOINT string = resources.outputs.AZURE_KEY_VAULT_ENDPOINT
output APPLICATIONINSIGHTS_CONNECTION_STRING string = resources.outputs.APPLICATIONINSIGHTS_CONNECTION_STRING
