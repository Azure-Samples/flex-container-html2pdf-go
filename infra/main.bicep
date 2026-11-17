targetScope = 'subscription'

@minLength(1)
@maxLength(32)
@description('Azure Developer CLI environment name.')
param environmentName string

@description('Standard Azure region used for the resource group and supporting resources.')
param location string

@description('Preview region used for the Flex Consumption plan, Function App, and virtual network.')
param functionLocation string

var abbrs = loadJsonContent('./abbreviations.json')
var tags = {
  'azd-env-name': environmentName
}
var resourceGroupName = '${abbrs.resourcesResourceGroups}${environmentName}-${take(toLower(uniqueString(subscription().id, environmentName, location)), 6)}'

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module foundation './app/foundation.bicep' = {
  name: 'foundation'
  scope: resourceGroup
  params: {
    name: environmentName
    location: location
    functionLocation: functionLocation
    tags: tags
  }
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_LOCATION string = location
output AZURE_FUNCTION_LOCATION string = functionLocation
output AZURE_CONTAINER_REGISTRY_NAME string = foundation.outputs.containerRegistryName
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = foundation.outputs.containerRegistryEndpoint
output AZURE_IMAGE_REPOSITORY string = foundation.outputs.imageRepository
output AZURE_ACR_SCOPE_MAP_NAME string = foundation.outputs.scopeMapName
output AZURE_ACR_TOKEN_NAME string = foundation.outputs.tokenName
output AZURE_FUNCTION_NAME string = foundation.outputs.functionAppName
output AZURE_FUNCTION_APP_ID string = foundation.outputs.functionAppId
output AZURE_APP_SERVICE_PLAN_ID string = foundation.outputs.appServicePlanId
output AZURE_STORAGE_ACCOUNT_NAME string = foundation.outputs.storageAccountName
output AZURE_APPLICATION_INSIGHTS_NAME string = foundation.outputs.applicationInsightsName
output AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING string = foundation.outputs.applicationInsightsConnectionString
output AZURE_USER_ASSIGNED_IDENTITY_ID string = foundation.outputs.userAssignedIdentityId
output AZURE_USER_ASSIGNED_IDENTITY_CLIENT_ID string = foundation.outputs.userAssignedIdentityClientId
output AZURE_FUNCTION_SUBNET_ID string = foundation.outputs.functionSubnetId
output API_URL string = 'https://${foundation.outputs.functionAppName}.azurewebsites.net'
