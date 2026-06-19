// =============================================================================
// Microsoft Foundry + Azure AI Search inside a Network Security Perimeter (NSP)
// -----------------------------------------------------------------------------
// Standalone template that reproduces the Microsoft Learn how-to:
//   "Add Microsoft Foundry to a network security perimeter"
//   https://learn.microsoft.com/azure/foundry/how-to/add-foundry-to-network-security-perimeter
//
// Scenario validated by scripts/test_nsp.py:
//   * A Microsoft Foundry (AIServices) account in `location`
//   * An Azure AI Search service in `searchLocation` (a DIFFERENT region)
//   * Both associated to ONE NSP profile so they trust each other across regions
//   * NSP access logs streamed to Log Analytics for allow/deny validation
//
// Deploy:  az deployment sub create -l <loc> -f infra/nsp/main.bicep \
//            -p @infra/nsp/main.parameters.json
// =============================================================================
targetScope = 'subscription'

@minLength(1)
@maxLength(60)
@description('Short name used to derive the resource group and resource names.')
param environmentName string = 'nsp-demo'

@description('Primary region for the Microsoft Foundry (AIServices) account, NSP and Log Analytics.')
param location string = 'eastus'

@description('Secondary region for the Azure AI Search service. MUST differ from `location` to exercise the cross-region NSP scenario.')
param searchLocation string = 'westus2'

@description('Object ID of the signed-in user/principal — granted data-plane roles so the test client can call Foundry and Search.')
param principalId string = ''

@description('NSP access mode for the resource associations. Start with Learning, then switch to Enforced once access logs look correct.')
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

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}'
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  scope: rg
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

@description('Microsoft Foundry (AIServices) data-plane endpoint.')
output foundryEndpoint string = resources.outputs.foundryEndpoint

@description('Azure AI Search data-plane endpoint (secondary region).')
output searchEndpoint string = resources.outputs.searchEndpoint

@description('Resource ID of the network security perimeter.')
output nspId string = resources.outputs.nspId

@description('Resource ID of the NSP profile both resources are associated with.')
output nspProfileId string = resources.outputs.nspProfileId

@description('Customer-immutable ID of the Log Analytics workspace holding NspAccessLogs.')
output logAnalyticsWorkspaceCustomerId string = resources.outputs.logAnalyticsWorkspaceCustomerId

@description('Resource ID of the Log Analytics workspace holding NspAccessLogs.')
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId

@description('Effective access mode applied to the associations.')
output accessMode string = accessMode

@description('Resource group the demo was deployed into.')
output resourceGroupName string = rg.name
