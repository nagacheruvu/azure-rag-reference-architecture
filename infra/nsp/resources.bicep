// =============================================================================
// Resource-group scoped resources for the Foundry + AI Search NSP demo.
// =============================================================================

@description('Primary region (Foundry, NSP, Log Analytics).')
param location string

@description('Secondary region (Azure AI Search) — different from `location`.')
param searchLocation string

@description('Deterministic token used to build globally-unique resource names.')
param resourceToken string

@description('Tags applied to every resource.')
param tags object

@description('Object ID of the signed-in principal granted data-plane roles for testing.')
param principalId string

@description('NSP association access mode: Learning, Enforced, or Audit.')
param accessMode string

@description('Public IP address (or CIDR) allowed inbound by the NSP profile. Leave empty to skip the inbound IP rule. Using an IP rule keeps the deploy least-privilege (a subscription-based rule needs joinPerimeterRule/action at subscription scope).')
param clientIpAddress string = ''

var hasPrincipal = !empty(principalId)
var hasClientIp = !empty(clientIpAddress)
var clientIpPrefix = hasClientIp ? (indexOf(clientIpAddress, '/') >= 0 ? clientIpAddress : '${clientIpAddress}/32') : ''

// Built-in role definition IDs
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

// --- Observability ----------------------------------------------------------
// NSP access decisions (allow/deny) are streamed here as the NspAccessLogs table.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${resourceToken}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// --- Microsoft Foundry (AIServices) — primary region ------------------------
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: 'foundry${resourceToken}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: 'foundry${resourceToken}'
    // Learning mode still honours publicNetworkAccess while you assess logs;
    // Enforced mode lets NSP inbound rules take precedence. Keep Enabled so the
    // in-perimeter test client can reach the data plane.
    publicNetworkAccess: 'Enabled'
    disableLocalAuth: true
  }
}

// --- Azure AI Search — secondary region (cross-region scenario) -------------
resource search 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: 'srch${resourceToken}'
  location: searchLocation
  tags: tags
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
    semanticSearch: 'standard'
    publicNetworkAccess: 'enabled'
    disableLocalAuth: true
  }
}

// --- Cross-resource keyless trust (managed identity) ------------------------
// Foundry's identity can query the Search index (e.g. "On Your Data").
resource foundryReadsSearch 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, foundry.id, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: foundry.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Search's identity can call Foundry embeddings during indexing.
resource searchReadsFoundry 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, search.id, roleCognitiveServicesOpenAIUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: search.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Test-client (signed-in user) data-plane roles --------------------------
resource userFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(foundry.id, principalId, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalId: principalId
    principalType: 'User'
  }
}

resource userFoundryOpenAIUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(foundry.id, principalId, roleCognitiveServicesOpenAIUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: principalId
    principalType: 'User'
  }
}

resource userSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(search.id, principalId, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: principalId
    principalType: 'User'
  }
}

resource userSearchIndexContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(search.id, principalId, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: principalId
    principalType: 'User'
  }
}

// --- Network Security Perimeter ---------------------------------------------
resource nsp 'Microsoft.Network/networkSecurityPerimeters@2024-07-01' = {
  name: 'nsp-${resourceToken}'
  location: location
  tags: tags
}

// A single profile both resources are associated to. Resources sharing a
// profile trust each other implicitly (managed-identity / role-based) without
// explicit access rules — including across regions.
resource profile 'Microsoft.Network/networkSecurityPerimeters/profiles@2024-07-01' = {
  parent: nsp
  name: 'foundry-search-profile'
}

// Inbound rule: allow the test client's public IP. An IP-address-range rule is
// authored entirely within the perimeter's RG scope, so it works for a
// least-privilege (RG-scoped) deployer. A subscription-based rule would instead
// require Microsoft.Network/networkSecurityPerimeters/joinPerimeterRule/action
// at subscription scope. Skipped when no client IP is supplied.
resource inboundFromClientIp 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = if (hasClientIp) {
  parent: profile
  name: 'allow-inbound-client-ip'
  properties: {
    direction: 'Inbound'
    addressPrefixes: [
      clientIpPrefix
    ]
  }
}

// Outbound rule: exact FQDNs of the deployed Foundry/Search endpoints. NSP
// outbound FQDN rules require fully-qualified names — wildcard prefixes (e.g.
// '*.openai.azure.com') are rejected with 'Invalid FQDN names supplied.'
resource outboundFqdns 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = {
  parent: profile
  name: 'allow-outbound-fqdns'
  properties: {
    direction: 'Outbound'
    fullyQualifiedDomainNames: [
      '${foundry.name}.openai.azure.com'
      '${foundry.name}.cognitiveservices.azure.com'
      '${search.name}.search.windows.net'
    ]
  }
}

// Associate Microsoft Foundry with the NSP profile.
resource foundryAssociation 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2024-07-01' = {
  parent: nsp
  name: 'assoc-foundry'
  properties: {
    accessMode: accessMode
    privateLinkResource: {
      id: foundry.id
    }
    profile: {
      id: profile.id
    }
  }
}

// Associate Azure AI Search (secondary region) with the SAME NSP profile.
resource searchAssociation 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2024-07-01' = {
  parent: nsp
  name: 'assoc-search'
  properties: {
    accessMode: accessMode
    privateLinkResource: {
      id: search.id
    }
    profile: {
      id: profile.id
    }
  }
}

// --- NSP diagnostic logging -> Log Analytics (NspAccessLogs) -----------------
resource nspDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'nsp-alllogs'
  scope: nsp
  properties: {
    workspaceId: logAnalytics.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

output foundryEndpoint string = foundry.properties.endpoint
output searchEndpoint string = 'https://${search.name}.search.windows.net'
output nspId string = nsp.id
output nspProfileId string = profile.id
output logAnalyticsWorkspaceCustomerId string = logAnalytics.properties.customerId
output logAnalyticsWorkspaceId string = logAnalytics.id
