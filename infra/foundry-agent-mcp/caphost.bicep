/*
  Standalone project capability host (Agents). Deployed AFTER main.bicep Pass 1
  (project + connections + role assignments already exist) so it never re-PUTs
  the Foundry account (which would flip it to 'Accepted' and race this child op).

  The account capability host is auto-created by the platform when the account is
  created with networkInjections.scenario='agent', so only the PROJECT capability
  host is declared here.
*/
@description('Existing Foundry (AIServices) account name.')
param accountName string

@description('Existing project name.')
param projectName string

@description('Capability host name.')
param capHostName string

@description('Cosmos DB connection name (= cosmos account name from Pass 1).')
param cosmosConnectionName string

@description('Storage connection name (= storage account name from Pass 1).')
param storageConnectionName string

@description('AI Search connection name (= search service name from Pass 1).')
param searchConnectionName string

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

#disable-next-line BCP081
resource projectCapabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: capHostName
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
    threadStorageConnections: [cosmosConnectionName]
    storageConnections: [storageConnectionName]
    vectorStoreConnections: [searchConnectionName]
  }
}
