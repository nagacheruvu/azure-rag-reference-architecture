// =============================================================================
// Resource-group scoped entry point for the Foundry + AI Search NSP demo.
// Use this when the deploying identity (e.g. a scoped service principal) only
// has Contributor on the target resource group, not the whole subscription.
// The resource group must already exist.
//
// Deploy:  az deployment group create -g <rg> -f infra/nsp/main-rg.bicep \
//            -p environmentName=nsp-demo location=eastus searchLocation=westus2
// =============================================================================
targetScope = 'resourceGroup'

@minLength(1)
@maxLength(60)
@description('Short name used to derive resource names (must match the RG-scoped deployment).')
param environmentName string = 'nsp-demo'

@description('Primary region for the Microsoft Foundry (AIServices) account, NSP and Log Analytics.')
param location string = resourceGroup().location

@description('Secondary region for the Azure AI Search service. MUST differ from `location`.')
param searchLocation string = 'westus2'

@description('Object ID of the user/principal granted data-plane roles so the test client can call Foundry and Search.')
param principalId string = ''

@description('NSP access mode for the resource associations.')
@allowed([
  'Learning'
  'Enforced'
  'Audit'
])
param accessMode string = 'Learning'

@description('Public IP (or CIDR) allowed inbound by the NSP profile. Empty skips the inbound IP rule.')
param clientIpAddress string = ''

var resourceToken = uniqueString(subscription().id, location, environmentName)
var tags = {
  'azd-env-name': environmentName
  project: 'foundry-nsp'
  scenario: 'foundry-to-search-cross-region'
}

module resources 'resources.bicep' = {
  name: 'foundry-nsp-resources'
  params: {
    location: location
    searchLocation: searchLocation
    resourceToken: resourceToken
    tags: tags
    principalId: principalId
    accessMode: accessMode
    clientIpAddress: clientIpAddress
  }
}

output foundryEndpoint string = resources.outputs.foundryEndpoint
output searchEndpoint string = resources.outputs.searchEndpoint
output nspId string = resources.outputs.nspId
output nspProfileId string = resources.outputs.nspProfileId
output logAnalyticsWorkspaceCustomerId string = resources.outputs.logAnalyticsWorkspaceCustomerId
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId
output accessMode string = accessMode
output resourceGroupName string = resourceGroup().name
