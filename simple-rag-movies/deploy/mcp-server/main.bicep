@description('Location of resources')
param location string = resourceGroup().location

@description('Name of the Container App')
param containerAppName string = 'mongo-mcp-server'

@description('Docker image to deploy')
param containerImage string = 'mongodb/mongodb-mcp-server:latest'

@description('Container CPU cores')
@allowed(['0.25', '0.5', '1.0'])
param containerCpu string = '0.5'

@description('Container Memory')
@allowed(['0.5Gi', '1Gi', '2Gi'])
param containerMemory string = '1Gi'

@description('Enable read-only mode (recommended)')
param readOnlyMode bool = true

@secure()
@description('MongoDB Atlas Connection String')
param mdbConnectionString string

// Variables
var containerCpuNumber = json(containerCpu)

// Create Container App Environment
resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-02-02-preview' = {
  name: 'mcp-env-${uniqueString(resourceGroup().id)}'
  location: location
  properties: {}
}

// Deploy MongoDB MCP Server Container App
resource containerApp 'Microsoft.App/containerApps@2024-02-02-preview' = {
  name: containerAppName
  location: location
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      ingress: {
        external: true
        targetPort: 8080
        transport: 'auto'
      }
      secrets: [
        {
          name: 'mdb-connection-string'
          value: mdbConnectionString
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'mcp-server'
          image: containerImage
          resources: {
            cpu: containerCpuNumber
            memory: containerMemory
          }
          env: [
            {
              name: 'MDB_MCP_CONNECTION_STRING'
              secretRef: 'mdb-connection-string'
            }
            {
              name: 'MDB_MCP_READ_ONLY'
              value: readOnlyMode ? 'true' : 'false'
            }
            {
              name: 'MDB_MCP_HTTP_PORT'
              value: '8080'
            }
            {
              name: 'MDB_MCP_HTTP_HOST'
              value: '::'
            }
            {
              name: 'MDB_MCP_TRANSPORT'
              value: 'http'
            }
            {
              name: 'MDB_MCP_HTTP_AUTH_MODE'
              value: 'none'
            }
            {
              // NOTE: do NOT set MDB_MCP_HTTP_RESPONSE_TYPE=json here. It makes the server reply
              // with Content-Type: application/json instead of the MCP default SSE framing, and
              // Foundry's MCP client then reports the tool call as successful while handing the
              // model no readable result - the agent answers "the lookup failed" even though the
              // server logged "Executed tool find". The embedding function's MCP client parses
              // both framings, so it does not need this either.
              // 'export' writes results to a file and returns an exported-data:// URI. Agents
              // pick it for ordinary queries and then answer with a link the user cannot open,
              // instead of the actual rows. Remove it so results always come back inline.
              name: 'MDB_MCP_DISABLED_TOOLS'
              value: 'export'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

output mcpServerUrl string = 'https://${containerApp.properties.configuration.ingress.fqdn}/mcp'
output containerAppName string = containerApp.name
