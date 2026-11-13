targetScope = 'resourceGroup'

param environmentName string
param functionAppName string
param functionLocation string
param appServicePlanId string
param applicationInsightsConnectionString string
param storageAccountName string
param userAssignedIdentityId string
param userAssignedIdentityClientId string
param virtualNetworkSubnetId string
param registryImage string
param registryUsername string

@secure()
param registryPassword string

var tags = {
  'azd-env-name': environmentName
  'azd-service-name': 'api'
}
var applicationInsightsAuthentication = 'ClientId=${userAssignedIdentityClientId};Authorization=AAD'

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

resource functionApp 'Microsoft.Web/sites@2026-08-01' = {
  name: functionAppName
  location: functionLocation
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userAssignedIdentityId}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlanId
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    virtualNetworkSubnetId: virtualNetworkSubnetId
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'Registry'
          value: registryImage
          authentication: {
            type: 'Basic'
            usernameSettingName: 'FLEX_CONTAINER_REGISTRY_USERNAME'
            passwordSettingName: 'FLEX_CONTAINER_REGISTRY_PASSWORD'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 2
      }
      siteUpdateStrategy: {
        type: 'Recreate'
      }
    }
    siteConfig: {
      alwaysOn: false
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
      remoteDebuggingEnabled: false
      scmMinTlsVersion: '1.2'
      appSettings: [
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: applicationInsightsAuthentication
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: storageAccount.properties.primaryEndpoints.blob
        }
        {
          name: 'AzureWebJobsStorage__clientId'
          value: userAssignedIdentityClientId
        }
        {
          name: 'AzureWebJobsStorage__credential'
          value: 'managedidentity'
        }
        {
          name: 'FLEX_CONTAINER_REGISTRY_PASSWORD'
          value: registryPassword
        }
        {
          name: 'FLEX_CONTAINER_REGISTRY_USERNAME'
          value: registryUsername
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
      ]
    }
  }
}

resource scmBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2022-03-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpBasicAuth 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2022-03-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

output API_URL string = 'https://${functionApp.properties.defaultHostName}'
output FUNCTION_APP_NAME string = functionApp.name
