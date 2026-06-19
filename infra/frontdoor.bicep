// Azure Front Door (Standard) — low-cost global entry in front of the Blazor web App Service.
// Standard tier gives anycast routing, managed TLS, WebSocket pass-through and cookie-based
// session affinity (needed to pin a Blazor Server SignalR circuit to one origin). Managed WAF
// rulesets require Premium, so none is attached here to keep the test cost low.
//
// The origin group is structured so a second-region App Service origin can be added later for
// true regional failover; for testing it runs a single origin.

@description('Front Door profile name.')
param name string

@description('Front Door SKU. Standard_AzureFrontDoor is the low-cost test tier.')
param skuName string

@description('Token used to build a unique endpoint name.')
param resourceToken string

@description('Default hostname of the web App Service origin (no scheme).')
param webHostName string

@description('Tags applied to the profile.')
param tags object

resource profile 'Microsoft.Cdn/profiles@2024-02-01' = {
  name: name
  location: 'global'
  tags: tags
  sku: {
    name: skuName
  }
}

resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-02-01' = {
  parent: profile
  name: 'web${resourceToken}'
  location: 'global'
  tags: tags
  properties: {
    enabledState: 'Enabled'
  }
}

resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-02-01' = {
  parent: profile
  name: 'web-origin-group'
  properties: {
    loadBalancingSettings: {
      sampleSize: 4
      successfulSamplesRequired: 3
      additionalLatencyInMilliseconds: 50
    }
    healthProbeSettings: {
      probePath: '/'
      probeRequestType: 'HEAD'
      probeProtocol: 'Https'
      probeIntervalInSeconds: 100
    }
    // Cookie-based stickiness keeps a Blazor Server circuit on one origin.
    sessionAffinityState: 'Enabled'
  }
}

resource origin 'Microsoft.Cdn/profiles/originGroups/origins@2024-02-01' = {
  parent: originGroup
  name: 'web-origin'
  properties: {
    hostName: webHostName
    originHostHeader: webHostName
    httpPort: 80
    httpsPort: 443
    priority: 1
    weight: 1000
    enabledState: 'Enabled'
    enforceCertificateNameCheck: true
  }
}

resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-02-01' = {
  parent: endpoint
  name: 'web-route'
  properties: {
    originGroup: {
      id: originGroup.id
    }
    supportedProtocols: [
      'Http'
      'Https'
    ]
    patternsToMatch: [
      '/*'
    ]
    forwardingProtocol: 'HttpsOnly'
    linkToDefaultDomain: 'Enabled'
    httpsRedirect: 'Enabled'
  }
  dependsOn: [
    origin
  ]
}

output endpointHostName string = endpoint.properties.hostName
output profileId string = profile.id
