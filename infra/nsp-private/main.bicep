// =============================================================================
// BYO-VNet PRIVATE variant: Microsoft Foundry + Azure AI Search with public
// network access DISABLED, reached only through Private Endpoints + Private DNS.
// -----------------------------------------------------------------------------
// Contrast with infra/nsp/ (the Network Security Perimeter demo), which keeps
// PUBLIC endpoints and controls access with perimeter rules. This template
// instead removes the resources from the public internet entirely:
//
//   * A virtual network with a private-endpoint subnet and a delegated
//     Azure Container Instance subnet (the in-VNet test runner).
//   * A Microsoft Foundry (AIServices) account in `location`, publicNetworkAccess
//     = Disabled, reachable only via a Private Endpoint (group id 'account').
//   * An Azure AI Search service in `searchLocation` (a DIFFERENT region),
//     publicNetworkAccess = disabled, reachable only via a Private Endpoint
//     (group id 'searchService'). The endpoint is created in the VNet region and
//     links cross-region to the Search resource.
//   * Private DNS zones for every Foundry/Search FQDN, linked to the VNet, so the
//     public hostnames resolve to the private endpoint IPs from inside the VNet.
//   * A VNet-injected Azure Container Instance that probes DNS + HTTPS for each
//     endpoint to prove private reachability (no VM quota required).
//   * A network security group on the ACI subnet that DENIES general internet
//     egress but ALLOWS the AzureActiveDirectory service tag, so the in-VNet
//     client can still acquire Entra ID tokens (user-assigned managed identity)
//     and reach the private endpoints. The probe makes an AUTHENTICATED data-plane
//     call (Bearer token) and expects HTTP 200 through the private endpoint —
//     proving AAD-authenticated private access works while the internet is locked
//     down and public network access is disabled.
//
// Why ACI for testing: with public access disabled there is no line of sight
// from the deploy machine; validation must originate inside the VNet. This
// subscription has zero VM quota, so an ACI container group is the test client.
//
// Deploy (RG-scoped, works for a least-privilege RG-scoped principal; RG must
// already exist):
//   az deployment group create -g <rg> -f infra/nsp-private/main.bicep \
//     -p environmentName=nsp-priv location=eastus searchLocation=westus2
// =============================================================================
targetScope = 'resourceGroup'

@minLength(1)
@maxLength(60)
@description('Short name used to derive resource names.')
param environmentName string = 'nsp-priv'

@description('Primary region for the VNet, private endpoints, Foundry, and the ACI test runner.')
param location string = resourceGroup().location

@description('Secondary region for the Azure AI Search service. MUST differ from `location` to exercise the cross-region private scenario.')
param searchLocation string = 'westus2'

@description('Object ID of a user/principal granted data-plane roles (optional). Useful if you later reach the private endpoints from a peered network or VPN.')
param principalId string = ''

@description('Deploy the in-VNet ACI probe that validates private connectivity. Set false to provision infrastructure only.')
param deployTester bool = true

@description('Deploy the in-VNet ACI report server that runs the validation suite and serves an HTML summary on a private IP (port 80).')
param deployReport bool = true

@description('Refresh interval (seconds) for the HTML report server to re-run the validation suite.')
param reportRefreshSeconds int = 180

@description('Address space for the virtual network.')
param vnetAddressPrefix string = '10.40.0.0/16'

@description('Subnet prefix for private endpoints.')
param peSubnetPrefix string = '10.40.1.0/24'

@description('Subnet prefix for the delegated Azure Container Instance test runner.')
param aciSubnetPrefix string = '10.40.2.0/24'

@description('Subnet prefix for the delegated Azure Container Instance HTML report server.')
param webSubnetPrefix string = '10.40.3.0/24'

@description('Deploy an Application Gateway (Standard_v2) to publish the private HTML report to the internet, restricted by NSG to a single client IP.')
param deployAppGateway bool = false

@description('Public client IP (no mask) allowed to reach the Application Gateway listener. Required when deployAppGateway = true.')
param allowedClientIp string = ''

@description('Subnet prefix for the dedicated Application Gateway subnet.')
param agwSubnetPrefix string = '10.40.4.0/24'

var resourceToken = uniqueString(subscription().id, location, environmentName)
var tags = {
  'azd-env-name': environmentName
  project: 'foundry-nsp-private'
  scenario: 'foundry-to-search-cross-region-private'
}

var foundryName = 'foundry${resourceToken}'
var searchName = 'srch${resourceToken}'
var hasPrincipal = !empty(principalId)

// Built-in role definition IDs (data plane).
var roleCognitiveServicesUser = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var roleCognitiveServicesOpenAIUser = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'
var roleSearchIndexDataContributor = '8ebe5a00-799e-43f5-93ac-243d3dce84a7'
var roleSearchServiceContributor = '7ca78c08-252a-4471-8644-bb5ff32d4ba0'

// --- User-assigned identity for the in-VNet ACI probe -----------------------
// Used by the probe to acquire Entra ID (AAD) tokens via managed identity and
// call the PRIVATE data-plane endpoints. RBAC is granted to THIS identity below
// before the container runs, so authenticated calls succeed inside the VNet.
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aci-${resourceToken}'
  location: location
  tags: tags
}

// --- NSG for the ACI subnet -------------------------------------------------
// Locks down egress: denies general internet but explicitly ALLOWS the
// AzureActiveDirectory service tag (Entra ID token acquisition), Azure infra
// (ACR/MCR image pull, ARM, Storage), and intra-VNet traffic (private endpoints).
resource nsgAci 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-aci-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Outbound-AzureActiveDirectory'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          description: 'Allow Entra ID (AAD) token acquisition for managed-identity auth.'
        }
      }
      {
        name: 'Allow-Outbound-AzureCloud'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
          description: 'Allow Azure infra egress (MCR image pull, ARM, Storage).'
        }
      }
      {
        name: 'Allow-Outbound-VirtualNetwork'
        properties: {
          priority: 300
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          description: 'Allow reaching the private endpoints inside the VNet.'
        }
      }
      {
        name: 'Deny-Outbound-Internet'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
          description: 'Deny all other internet egress; only AAD + Azure infra + VNet allowed.'
        }
      }
    ]
  }
}

// --- NSG for the report (web) subnet ---------------------------------------
// Same locked-down egress as the probe subnet, plus an explicit inbound rule
// allowing HTTP/80 from anywhere INSIDE the VNet so the report is viewable from
// a peered network / Bastion / VPN — but never from the public internet.
resource nsgWeb 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-web-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Inbound-Http-FromVNet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
          description: 'Allow viewing the HTML report on port 80 from inside the VNet only.'
        }
      }
      {
        name: 'Deny-Inbound-Internet'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          description: 'No inbound from the public internet.'
        }
      }
      {
        name: 'Allow-Outbound-AzureActiveDirectory'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureActiveDirectory'
          description: 'Allow Entra ID (AAD) token acquisition for managed-identity auth.'
        }
      }
      {
        name: 'Allow-Outbound-AzureCloud'
        properties: {
          priority: 200
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
          description: 'Allow Azure infra egress (MCR image pull, ARM, Storage).'
        }
      }
      {
        name: 'Allow-Outbound-VirtualNetwork'
        properties: {
          priority: 300
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          description: 'Allow reaching the private endpoints inside the VNet.'
        }
      }
      {
        name: 'Deny-Outbound-Internet'
        properties: {
          priority: 4000
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
          description: 'Deny all other internet egress; only AAD + Azure infra + VNet allowed.'
        }
      }
    ]
  }
}

// --- NSG for the Application Gateway subnet ---------------------------------
// Restricts the public listener to a single client IP, and includes the
// GatewayManager inbound rule that Application Gateway v2 requires to function.
// NOTE on App Gateway v2 + NSG client-IP filtering:
// AGW v2 frontend client traffic reaches the gateway SUBNET tagged as the
// 'Internet' service tag (NOT the original client source IP), because the v2
// data path flows through Azure-managed frontend infrastructure. A per-client-IP
// inbound allow on :80 therefore NEVER matches the real flow, and the implicit
// DenyAllInBound (or an explicit Deny-Internet) silently drops every client
// request -> the gateway returns an empty reply (curl 52 / HTTP 000) even though
// the backend is Healthy. The listener port MUST be allowed from 'Internet'.
// To genuinely restrict by client IP on AGW v2, use the WAF_v2 SKU with a custom
// rule matching RemoteAddr -- the subnet NSG cannot do it. allowedClientIp is kept
// for documentation/WAF use but is no longer used to gate the NSG.
resource nsgAgw 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-agw-${resourceToken}'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-Inbound-Http-Internet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
          description: 'AGW v2 client traffic is Internet-tagged at the subnet NSG; allow :80 from Internet or all client requests are dropped.'
        }
      }
      {
        name: 'Allow-Inbound-GatewayManager'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
          description: 'Required by Application Gateway v2 for health/management traffic.'
        }
      }
      {
        name: 'Allow-Inbound-AzureLoadBalancer'
        properties: {
          priority: 120
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          description: 'Allow Azure Load Balancer health probes.'
        }
      }
    ]
  }
}

// --- Virtual network --------------------------------------------------------
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${resourceToken}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        // Private endpoints land here.
        name: 'snet-pe'
        properties: {
          addressPrefix: peSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Delegated to Azure Container Instances for the VNet-injected probe.
        name: 'snet-aci'
        properties: {
          addressPrefix: aciSubnetPrefix
          networkSecurityGroup: {
            id: nsgAci.id
          }
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        // Delegated to Azure Container Instances for the HTML report server.
        name: 'snet-web'
        properties: {
          addressPrefix: webSubnetPrefix
          networkSecurityGroup: {
            id: nsgWeb.id
          }
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        // Dedicated subnet for the Application Gateway (no delegation).
        name: 'snet-agw'
        properties: {
          addressPrefix: agwSubnetPrefix
          networkSecurityGroup: {
            id: nsgAgw.id
          }
        }
      }
    ]
  }
}

resource peSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-pe'
}

resource aciSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-aci'
}

resource webSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-web'
}

resource agwSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: vnet
  name: 'snet-agw'
}

// --- Microsoft Foundry (AIServices) — primary region, PRIVATE ---------------
resource foundry 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: foundryName
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
    // Custom subdomain is required for Entra auth and private DNS resolution.
    customSubDomainName: foundryName
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    networkAcls: {
      defaultAction: 'Deny'
    }
  }
}

// --- Azure AI Search — secondary region, PRIVATE ----------------------------
resource search 'Microsoft.Search/searchServices@2024-03-01-preview' = {
  name: searchName
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
    publicNetworkAccess: 'disabled'
    disableLocalAuth: true
  }
}

// --- Private DNS zones ------------------------------------------------------
resource dnsCognitive 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.cognitiveservices.azure.com'
  location: 'global'
  tags: tags
}

resource dnsOpenai 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.openai.azure.com'
  location: 'global'
  tags: tags
}

resource dnsServices 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.services.ai.azure.com'
  location: 'global'
  tags: tags
}

resource dnsSearch 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.search.windows.net'
  location: 'global'
  tags: tags
}

// Link every zone to the VNet so in-VNet lookups resolve to private IPs.
resource linkCognitive 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsCognitive
  name: 'link-${resourceToken}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource linkOpenai 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsOpenai
  name: 'link-${resourceToken}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource linkServices 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsServices
  name: 'link-${resourceToken}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource linkSearch 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsSearch
  name: 'link-${resourceToken}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// --- Private endpoint: Foundry ('account') ----------------------------------
resource foundryPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-foundry-${resourceToken}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'foundry'
        properties: {
          privateLinkServiceId: foundry.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

resource foundryPeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: foundryPe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'cognitiveservices'
        properties: {
          privateDnsZoneId: dnsCognitive.id
        }
      }
      {
        name: 'openai'
        properties: {
          privateDnsZoneId: dnsOpenai.id
        }
      }
      {
        name: 'servicesai'
        properties: {
          privateDnsZoneId: dnsServices.id
        }
      }
    ]
  }
}

// --- Private endpoint: Search ('searchService'), cross-region ---------------
resource searchPe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-search-${resourceToken}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'search'
        properties: {
          privateLinkServiceId: search.id
          groupIds: [
            'searchService'
          ]
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
      {
        name: 'search'
        properties: {
          privateDnsZoneId: dnsSearch.id
        }
      }
    ]
  }
}

// --- Storage account: blob download channel for the report ------------------
// The in-VNet report container uploads its rendered HTML here using its managed
// identity through a PRIVATE endpoint (blob), so the write keeps working even if
// publicNetworkAccess is disabled by policy. No shared keys, no anonymous blob
// access (Entra ID only). To download the report from outside the VNet, briefly
// enable public network access and read the blob with your own AAD credentials
// (Storage Blob Data Reader). DNS for the blob FQDN resolves to the private
// endpoint IP inside the VNet and to the public endpoint everywhere else.
var storageName = 'st${resourceToken}'
var blobContainerName = 'report'
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = if (deployReport) {
  name: storageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = if (deployReport) {
  parent: storage
  name: 'default'
}

resource reportBlobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = if (deployReport) {
  parent: blobService
  name: blobContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource dnsBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = if (deployReport) {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource linkBlob 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (deployReport) {
  parent: dnsBlob
  name: 'link-${resourceToken}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

resource storagePe 'Microsoft.Network/privateEndpoints@2024-05-01' = if (deployReport) {
  name: 'pe-blob-${resourceToken}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: peSubnet.id
    }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource storagePeDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (deployReport) {
  parent: storagePe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: {
          privateDnsZoneId: dnsBlob.id
        }
      }
    ]
  }
}

// Let the report container's identity WRITE the rendered HTML to the blob.
resource aciStorageBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployReport) {
  name: guid(storageName, uami.id, roleStorageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Optional user data-plane role assignments ------------------------------
resource userFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(foundry.id, principalId, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalId: principalId
    principalType: 'User'
  }
}

resource userFoundryOpenAi 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
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

resource userSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasPrincipal) {
  name: guid(search.id, principalId, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: principalId
    principalType: 'User'
  }
}

// --- ACI managed-identity data-plane role assignments -----------------------
// Granted to the user-assigned identity so the in-VNet probe can authenticate
// with Entra ID and call the PRIVATE data-plane endpoints (expect HTTP 200).
resource aciFoundryOpenAi 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, uami.id, roleCognitiveServicesOpenAIUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesOpenAIUser)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aciFoundryUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(foundry.id, uami.id, roleCognitiveServicesUser)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleCognitiveServicesUser)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aciSearchContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, uami.id, roleSearchServiceContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchServiceContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aciSearchIndex 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(search.id, uami.id, roleSearchIndexDataContributor)
  scope: search
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleSearchIndexDataContributor)
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- In-VNet ACI probe ------------------------------------------------------
// Acquires an Entra ID (AAD) token via the user-assigned managed identity (the
// NSG AzureActiveDirectory rule permits this), resolves DNS (expect private
// 10.40.1.x), proves general internet egress is BLOCKED by the NSG, and makes an
// AUTHENTICATED data-plane call to each private endpoint (expect HTTP 200).
// restartPolicy Never => runs once; read results with `az container logs`.
var probeHosts = [
  '${foundryName}.cognitiveservices.azure.com'
  '${foundryName}.openai.azure.com'
  '${foundryName}.services.ai.azure.com'
  '${searchName}.search.windows.net'
]
var foundryAuthHost = '${foundryName}.openai.azure.com'
var searchAuthHost = '${searchName}.search.windows.net'
var reportScript = loadTextContent('../../scripts/nsp_report.py')

// Structured configuration surfaced in the HTML report tabs (Network / DNS /
// Services / NSG / Deployment). Serialized to JSON and injected as CONFIG_JSON.
var portalDeploymentsUrl = 'https://portal.azure.com/#@${tenant().tenantId}/resource/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/deployments'
var portalResourceGroupUrl = 'https://portal.azure.com/#@${tenant().tenantId}/resource/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/overview'
var reportConfig = {
  subscriptionId: subscription().subscriptionId
  resourceGroup: resourceGroup().name
  location: location
  searchLocation: searchLocation
  environmentName: environmentName
  resourceToken: resourceToken
  templatePath: 'infra/nsp-private/main.bicep'
  portalDeploymentsUrl: portalDeploymentsUrl
  portalResourceGroupUrl: portalResourceGroupUrl
  vnet: {
    name: 'vnet-${resourceToken}'
    addressSpace: vnetAddressPrefix
    subnets: [
      {
        name: 'snet-pe'
        prefix: peSubnetPrefix
        delegation: '(none)'
        nsg: '(none)'
        purpose: 'Private endpoints for Foundry + Search (PE NICs land here)'
      }
      {
        name: 'snet-aci'
        prefix: aciSubnetPrefix
        delegation: 'Microsoft.ContainerInstance/containerGroups'
        nsg: 'nsg-aci-${resourceToken}'
        purpose: 'One-shot connectivity tester (VNet-injected ACI)'
      }
      {
        name: 'snet-web'
        prefix: webSubnetPrefix
        delegation: 'Microsoft.ContainerInstance/containerGroups'
        nsg: 'nsg-web-${resourceToken}'
        purpose: 'HTML report server (VNet-injected ACI) - this page'
      }
      {
        name: 'snet-agw'
        prefix: agwSubnetPrefix
        delegation: '(none)'
        nsg: 'nsg-agw-${resourceToken}'
        purpose: 'Application Gateway public ingress (restricted to one client IP)'
      }
    ]
  }
  dnsZones: [
    {
      zone: 'privatelink.cognitiveservices.azure.com'
      service: 'Foundry (Cognitive Services data plane)'
      linkedToVnet: true
    }
    {
      zone: 'privatelink.openai.azure.com'
      service: 'Foundry (Azure OpenAI data plane)'
      linkedToVnet: true
    }
    {
      zone: 'privatelink.services.ai.azure.com'
      service: 'Foundry (AI Services data plane)'
      linkedToVnet: true
    }
    {
      zone: 'privatelink.search.windows.net'
      service: 'Azure AI Search data plane (cross-region)'
      linkedToVnet: true
    }
  ]
  foundry: {
    name: foundryName
    region: location
    kind: 'AIServices (Microsoft Foundry)'
    sku: 'S0'
    publicNetworkAccess: 'Disabled'
    authMode: 'Entra ID only (local auth disabled)'
    privateEndpoint: 'pe-foundry-${resourceToken}'
    peSubnet: 'snet-pe'
    endpoints: [
      '${foundryName}.cognitiveservices.azure.com'
      '${foundryName}.openai.azure.com'
      '${foundryName}.services.ai.azure.com'
    ]
  }
  search: {
    name: searchName
    region: searchLocation
    kind: 'Azure AI Search'
    sku: 'basic'
    publicNetworkAccess: 'disabled'
    authMode: 'Entra ID only (local auth disabled)'
    privateEndpoint: 'pe-search-${resourceToken}'
    peSubnet: 'snet-pe'
    endpoints: [
      '${searchName}.search.windows.net'
    ]
  }
  nsgs: [
    {
      name: 'nsg-aci-${resourceToken}'
      appliesTo: 'snet-aci'
      summary: 'Outbound: allow AzureActiveDirectory + AzureCloud + VirtualNetwork; deny Internet. Inbound: default.'
    }
    {
      name: 'nsg-web-${resourceToken}'
      appliesTo: 'snet-web'
      summary: 'Inbound: allow HTTP 80 from VirtualNetwork; deny Internet. Outbound: allow AAD + AzureCloud + VNet; deny Internet.'
    }
    {
      name: 'nsg-agw-${resourceToken}'
      appliesTo: 'snet-agw'
      summary: 'Inbound: allow client IP :80 + GatewayManager 65200-65535 + AzureLoadBalancer; deny Internet. Outbound: allow AAD + AzureCloud + VNet; deny Internet.'
    }
  ]
}
var probeScript = 'echo PROBE_START; CID="${uami.properties.clientId}"; TURL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01"; echo "Acquiring AAD tokens via managed identity (NSG AzureActiveDirectory tag permits this)..."; COGT=""; SRCT=""; n=0; while [ $n -lt 18 ]; do COGT=$(curl -s -m 20 -H "Metadata: true" "$TURL&resource=https://cognitiveservices.azure.com&client_id=$CID" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\'access_token\',\'\'))" 2>/dev/null); if [ -n "$COGT" ]; then break; fi; n=$((n+1)); echo "token retry $n"; sleep 10; done; SRCT=$(curl -s -m 20 -H "Metadata: true" "$TURL&resource=https://search.azure.com&client_id=$CID" | python3 -c "import sys,json;print(json.load(sys.stdin).get(\'access_token\',\'\'))" 2>/dev/null); if [ -n "$COGT" ]; then echo COG_TOKEN=present; else echo COG_TOKEN=EMPTY; fi; if [ -n "$SRCT" ]; then echo SRCH_TOKEN=present; else echo SRCH_TOKEN=EMPTY; fi; echo "--- DNS (expect private 10.40.1.x) ---"; for h in ${join(probeHosts, ' ')}; do printf "RESOLVED %s -> " "$h"; getent hosts $h 2>/dev/null | head -n1 || printf DNSFAIL; echo ""; done; echo "--- Internet egress (expect BLOCKED by NSG Deny-Internet) ---"; printf "INTERNET 1.1.1.1 = "; curl -sS -k -m 12 -o /dev/null -w "%{http_code}" https://1.1.1.1/ 2>/dev/null && echo " (REACHED)" || echo BLOCKED; echo "--- Authenticated data-plane via private endpoint (expect 200) ---"; u="https://${foundryAuthHost}/openai/models?api-version=2024-10-21"; s=000; j=0; while [ $j -lt 18 ]; do s=$(curl -sS -k -m 20 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $COGT" "$u"); if [ "$s" != "403" ] && [ "$s" != "000" ]; then break; fi; j=$((j+1)); sleep 10; done; echo "AUTHSTATUS foundry openai/models = $s"; u="https://${searchAuthHost}/indexes?api-version=2023-11-01"; s=000; j=0; while [ $j -lt 18 ]; do s=$(curl -sS -k -m 20 -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $SRCT" "$u"); if [ "$s" != "403" ] && [ "$s" != "000" ]; then break; fi; j=$((j+1)); sleep 10; done; echo "AUTHSTATUS search indexes = $s"; echo PROBE_DONE'

resource tester 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (deployTester) {
  name: 'aci-nsp-tester-${resourceToken}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Never'
    subnetIds: [
      {
        id: aciSubnet.id
      }
    ]
    containers: [
      {
        name: 'probe'
        properties: {
          image: 'mcr.microsoft.com/azure-cli:latest'
          command: [
            '/bin/sh'
            '-c'
            probeScript
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: json('1.5')
            }
          }
        }
      }
    ]
  }
  dependsOn: [
    foundryPeDns
    searchPeDns
    linkCognitive
    linkOpenai
    linkServices
    linkSearch
    aciFoundryOpenAi
    aciFoundryUser
    aciSearchContributor
    aciSearchIndex
  ]
}

// --- In-VNet ACI report server ----------------------------------------------
// Long-running (restartPolicy Always) container in a dedicated subnet. Re-runs
// the private-connectivity validation suite (DNS, internet-block, authenticated
// Foundry + cross-region Search calls) on a timer and serves a styled HTML
// summary on a PRIVATE IP, port 80 — viewable only from inside the VNet.
resource report 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = if (deployReport) {
  name: 'aci-nsp-report-${resourceToken}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    subnetIds: [
      {
        id: webSubnet.id
      }
    ]
    ipAddress: {
      type: 'Private'
      ports: [
        {
          protocol: 'TCP'
          port: 80
        }
      ]
    }
    containers: [
      {
        name: 'report'
        properties: {
          image: 'mcr.microsoft.com/azure-cli:latest'
          command: [
            'python3'
            '-c'
            reportScript
          ]
          ports: [
            {
              protocol: 'TCP'
              port: 80
            }
          ]
          environmentVariables: [
            {
              name: 'CLIENT_ID'
              value: uami.properties.clientId
            }
            {
              name: 'FOUNDRY_HOST'
              value: foundryAuthHost
            }
            {
              name: 'FOUNDRY_REGION'
              value: location
            }
            {
              name: 'SEARCH_HOST'
              value: searchAuthHost
            }
            {
              name: 'SEARCH_REGION'
              value: searchLocation
            }
            {
              name: 'DNS_HOSTS'
              value: join(probeHosts, ' ')
            }
            {
              name: 'REFRESH_SECONDS'
              value: string(reportRefreshSeconds)
            }
            {
              name: 'CONFIG_JSON'
              value: string(reportConfig)
            }
            {
              name: 'STORAGE_ACCOUNT'
              value: storageName
            }
            {
              name: 'STORAGE_CONTAINER'
              value: blobContainerName
            }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: json('1.5')
            }
          }
        }
      }
    ]
  }
  dependsOn: [
    foundryPeDns
    searchPeDns
    linkCognitive
    linkOpenai
    linkServices
    linkSearch
    aciFoundryOpenAi
    aciFoundryUser
    aciSearchContributor
    aciSearchIndex
    storagePeDns
    aciStorageBlob
  ]
}

// --- Application Gateway (optional public ingress for the report) -----------
// Publishes the private report container to the internet through an L7 gateway,
// with the listener locked down to a single client IP by nsgAgw. Standard_v2,
// autoscale 0..2 to minimise idle cost. HTTP only (port 80) — it serves a
// non-sensitive validation dashboard.
var agwName = 'agw-${resourceToken}'
resource agwPip 'Microsoft.Network/publicIPAddresses@2024-05-01' = if (deployAppGateway) {
  name: 'pip-agw-${resourceToken}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource appgw 'Microsoft.Network/applicationGateways@2024-05-01' = if (deployAppGateway) {
  name: agwName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'gwip'
        properties: {
          subnet: {
            id: agwSubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'feip'
        properties: {
          publicIPAddress: {
            id: agwPip.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'fe80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'bepool'
        properties: {
          backendAddresses: [
            {
              ipAddress: deployReport ? report.properties.ipAddress.ip : ''
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'behttp'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
        }
      }
    ]
    httpListeners: [
      {
        name: 'listener80'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', agwName, 'feip')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', agwName, 'fe80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'rule80'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', agwName, 'listener80')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', agwName, 'bepool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', agwName, 'behttp')
          }
        }
      }
    ]
  }
}

// --- Outputs ----------------------------------------------------------------
output vnetId string = vnet.id
output foundryName string = foundryName
output searchName string = searchName
output foundryHosts array = [
  '${foundryName}.cognitiveservices.azure.com'
  '${foundryName}.openai.azure.com'
  '${foundryName}.services.ai.azure.com'
]
output searchHost string = '${searchName}.search.windows.net'
output testerName string = deployTester ? tester.name : ''
output resourceGroupName string = resourceGroup().name
output readTesterLogsCommand string = deployTester ? 'az container logs -g ${resourceGroup().name} -n aci-nsp-tester-${resourceToken}' : 'tester not deployed'
output reportName string = deployReport ? report.name : ''
output reportPrivateIp string = deployReport ? report.properties.ipAddress.ip : ''
output reportUrl string = deployReport ? 'http://${report.properties.ipAddress.ip}/ (browse from inside the VNet)' : 'report not deployed'
output reportStorageAccount string = deployReport ? storageName : ''
output reportBlobContainer string = deployReport ? blobContainerName : ''
output downloadReportCommand string = deployReport ? 'az storage account update -g ${resourceGroup().name} -n ${storageName} --public-network-access Enabled; az storage blob download --account-name ${storageName} -c ${blobContainerName} -n index.html --auth-mode login -f report.html' : 'report not deployed'
output appGatewayPublicIp string = deployAppGateway ? agwPip.properties.ipAddress : ''
output appGatewayUrl string = deployAppGateway ? 'http://${agwPip.properties.ipAddress}/ (public on :80; AGW v2 NSG cannot filter client IP${empty(allowedClientIp) ? '' : ' - intended client ${allowedClientIp}'} - use WAF_v2 to enforce)' : 'app gateway not deployed'
