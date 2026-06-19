// APIM AI-gateway in front of (up to) two Azure OpenAI accounts in different regions.
// Provides resiliency against regional outages and 429 throttling via:
//   - a priority-based backend POOL (primary first, secondary on failover),
//   - per-backend CIRCUIT BREAKERS that trip on repeated 429/5xx,
//   - a RETRY policy that re-routes to a healthy backend,
//   - an azure-openai-token-limit policy that caps TPM at the gateway.
// Auth is keyless: callers present an Entra token (audience = cognitiveservices); APIM
// validates it, then uses its own managed identity to call the AOAI backends.

@description('APIM service name.')
param name string

@description('Location for the APIM instance.')
param location string

@description('APIM SKU (Basicv2 / Standardv2 recommended for the AI-gateway policies).')
param skuName string

@description('Publisher email (required by APIM).')
param publisherEmail string

@description('Publisher organization name.')
param publisherName string

@description('Tenant id used to validate inbound Entra tokens.')
param tenantId string

@description('Hostname of the primary Azure OpenAI account, e.g. azcog123.openai.azure.com.')
param primaryAoaiHost string

@description('Hostname of the secondary (failover) Azure OpenAI account.')
param secondaryAoaiHost string

@description('Per-minute token cap enforced at the gateway.')
param tokensPerMinute int

@description('Tags applied to the APIM service.')
param tags object

var aoaiScope = 'https://cognitiveservices.azure.com'
var openidConfigUrl = '${environment().authentication.loginEndpoint}${tenantId}/.well-known/openid-configuration'

// Inbound: validate the caller's Entra token, cap tokens-per-minute, then attach APIM's
// managed identity and route to the failover pool. Backend: retry on 429/5xx so a tripped
// primary transparently rolls over to the secondary region. buffer-response=false keeps SSE
// token streaming intact.
var apimPolicyXml = '<policies><inbound><base /><validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized" require-scheme="Bearer"><openid-config url="${openidConfigUrl}" /><audiences><audience>${aoaiScope}</audience></audiences></validate-jwt><azure-openai-token-limit counter-key="askmaya" tokens-per-minute="${tokensPerMinute}" estimate-prompt-tokens="false" remaining-tokens-header-name="x-ratelimit-remaining-tokens" /><authentication-managed-identity resource="${aoaiScope}" /><set-backend-service backend-id="aoai-pool" /></inbound><backend><retry condition="@(context.Response.StatusCode == 429 || context.Response.StatusCode >= 500)" count="2" interval="1" first-fast-retry="true"><forward-request buffer-response="false" /></retry></backend><outbound><base /></outbound><on-error><base /></on-error></policies>'

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
  }
}

resource backendPrimary 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: 'aoai-primary'
  properties: {
    protocol: 'http'
    url: 'https://${primaryAoaiHost}'
    circuitBreaker: {
      rules: [
        {
          name: 'breaker'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

resource backendSecondary 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: 'aoai-secondary'
  properties: {
    protocol: 'http'
    url: 'https://${secondaryAoaiHost}'
    circuitBreaker: {
      rules: [
        {
          name: 'breaker'
          failureCondition: {
            count: 3
            interval: 'PT1M'
            statusCodeRanges: [
              {
                min: 429
                max: 429
              }
              {
                min: 500
                max: 599
              }
            ]
          }
          tripDuration: 'PT1M'
          acceptRetryAfter: true
        }
      ]
    }
  }
}

// Priority pool: route to primary (priority 1); on a tripped breaker, roll to secondary (2).
resource backendPool 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: 'aoai-pool'
  properties: {
    type: 'Pool'
    pool: {
      services: [
        {
          id: backendPrimary.id
          priority: 1
          weight: 1
        }
        {
          id: backendSecondary.id
          priority: 2
          weight: 1
        }
      ]
    }
  }
}

resource openaiApi 'Microsoft.ApiManagement/service/apis@2023-09-01-preview' = {
  parent: apim
  name: 'aoai'
  properties: {
    displayName: 'Azure OpenAI'
    path: ''
    protocols: [
      'https'
    ]
    subscriptionRequired: false
    type: 'http'
  }
}

// Single catch-all operation: the AzureOpenAI SDK calls /openai/responses,
// /openai/deployments/{name}/embeddings, etc. — all POST under /openai.
resource proxyOperation 'Microsoft.ApiManagement/service/apis/operations@2023-09-01-preview' = {
  parent: openaiApi
  name: 'proxy'
  properties: {
    displayName: 'OpenAI proxy'
    method: 'POST'
    urlTemplate: '/openai/*'
    responses: []
  }
}

resource apiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: openaiApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: apimPolicyXml
  }
  dependsOn: [
    backendPool
    proxyOperation
  ]
}

output gatewayUrl string = apim.properties.gatewayUrl
output principalId string = apim.identity.principalId
output name string = apim.name
