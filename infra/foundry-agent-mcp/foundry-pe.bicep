/*
  Standalone Foundry account private endpoint + DNS group.
  Deployed AFTER main.bicep (deployFoundryPe=false) so the PE never races the
  Foundry account's network-injection settle. Contains NO account resource, so
  it cannot push the account back to 'Accepted'.
*/
@description('Existing Foundry (AIServices) account name.')
param accountName string

@description('Resource id of the private-endpoint subnet (snet-pe in the agent VNet).')
param peSubnetId string

@description('Short token used in the resource names (matches main.bicep).')
param token string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

var dnsOpenAi = 'privatelink.openai.azure.com'
var dnsCognitive = 'privatelink.cognitiveservices.azure.com'
var dnsServicesAi = 'privatelink.services.ai.azure.com'

resource zoneOpenAi 'Microsoft.Network/privateDnsZones@2020-06-01' existing = { name: dnsOpenAi }
resource zoneCognitive 'Microsoft.Network/privateDnsZones@2020-06-01' existing = { name: dnsCognitive }
resource zoneServicesAi 'Microsoft.Network/privateDnsZones@2020-06-01' existing = { name: dnsServicesAi }

resource accountPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-foundry-${token}'
  location: resourceGroup().location
  properties: {
    subnet: {
      id: peSubnetId
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

resource accountPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: accountPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      { name: 'openai', properties: { privateDnsZoneId: zoneOpenAi.id } }
      { name: 'cognitive', properties: { privateDnsZoneId: zoneCognitive.id } }
      { name: 'servicesai', properties: { privateDnsZoneId: zoneServicesAi.id } }
    ]
  }
}
