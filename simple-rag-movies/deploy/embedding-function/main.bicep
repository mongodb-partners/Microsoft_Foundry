@description('Location of resources')
param location string = resourceGroup().location

@description('Name of the Function App')
param functionAppName string = 'embedding-api-func'

@description('Azure OpenAI Endpoint URL')
param azureOpenAIEndpoint string

@secure()
@description('Azure OpenAI API Key')
param azureOpenAIKey string

@description('Embedding Model Deployment Name')
param embeddingModel string = 'text-embedding-ada-002'

@description('URL of the MongoDB MCP server (e.g. https://<app>.azurecontainerapps.io/mcp). This function asks that server to run the search; it never connects to MongoDB itself, so it holds no database credential.')
param mcpServerUrl string = ''

// Variables
var storageAccountName = 'st${uniqueString(resourceGroup().id)}'

// Storage Account (required for Function App)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    // Some subscriptions disable shared-key auth by default/policy, which breaks the
    // Functions runtime (AzureWebJobsStorage) and key-based zip deploy. Enable it explicitly.
    allowSharedKeyAccess: true
    minimumTlsVersion: 'TLS1_2'
  }
}

// Blob container that Flex Consumption uses to store the deployment package.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'deploymentpackage'
}

// App Service Plan (Flex Consumption). Flex is the supported serverless plan for the Azure
// Functions MCP extension; the retired Linux Consumption (Y1) plan does not support it
// (tool discovery / tools\/list fails there). Flex also builds Python deps remotely (Oryx).
resource hostingPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Linux
  }
}

// Function App (Flex Consumption uses functionAppConfig instead of siteConfig.linuxFxVersion)
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: hostingPlan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}deploymentpackage'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 40
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
        }
        {
          name: 'AZURE_OPENAI_ENDPOINT'
          value: azureOpenAIEndpoint
        }
        {
          name: 'AZURE_OPENAI_API_KEY'
          value: azureOpenAIKey
        }
        {
          name: 'EMBEDDING_MODEL'
          value: embeddingModel
        }
        {
          name: 'MCP_SERVER_URL'
          value: mcpServerUrl
        }
      ]
    }
  }
}

output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}/api/embed'
output functionAppMcpUrl string = 'https://${functionApp.properties.defaultHostName}/runtime/webhooks/mcp'
output functionAppName string = functionApp.name
