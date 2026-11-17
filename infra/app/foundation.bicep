targetScope = 'resourceGroup'

@minLength(1)
@maxLength(32)
param name string

param location string = resourceGroup().location
param functionLocation string
param tags object = {}

var abbrs = loadJsonContent('../abbreviations.json')
var resourceToken = take(toLower(uniqueString(subscription().id, resourceGroup().id, name, location, functionLocation)), 10)
var compactName = take(replace(replace(toLower(name), '-', ''), '_', ''), 10)
var storageAccountName = '${abbrs.storageStorageAccounts}${compactName}${resourceToken}'
var containerRegistryName = '${abbrs.containerRegistryRegistries}${compactName}${resourceToken}'
var logAnalyticsName = '${abbrs.operationalInsightsWorkspaces}${take(name, 20)}-${take(resourceToken, 6)}'
var applicationInsightsName = '${abbrs.insightsComponents}${take(name, 18)}-${take(resourceToken, 6)}'
var appServicePlanName = '${abbrs.webServerFarms}${take(name, 18)}-${take(resourceToken, 6)}'
var functionAppName = '${abbrs.webSitesFunctions}${take(name, 18)}-${take(resourceToken, 8)}'
var identityName = '${abbrs.managedIdentityUserAssignedIdentities}${take(name, 18)}-${take(resourceToken, 6)}'
var virtualNetworkName = '${abbrs.networkVirtualNetworks}${take(name, 18)}-${take(resourceToken, 6)}'
var imageRepository = 'flex-container-html2pdf-go'
var scopeMapName = 'pull-${take(resourceToken, 10)}-ro'
var tokenName = 'pull-${take(resourceToken, 10)}'

module userAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: 'user-assigned-identity'
  params: {
    name: identityName
    location: functionLocation
    tags: tags
  }
}

module storage 'br/public:avm/res/storage/storage-account:0.8.3' = {
  name: 'storage'
  params: {
    name: storageAccountName
    location: location
    tags: tags
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    dnsEndpointType: 'Standard'
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
    minimumTlsVersion: 'TLS1_2'
  }
}

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.7.0' = {
  name: 'log-analytics'
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    dataRetention: 30
  }
}

module applicationInsights 'br/public:avm/res/insights/component:0.4.1' = {
  name: 'application-insights'
  params: {
    name: applicationInsightsName
    location: location
    tags: tags
    workspaceResourceId: logAnalytics.outputs.resourceId
    disableLocalAuth: true
  }
}

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: containerRegistryName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    dataEndpointEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource scopeMap 'Microsoft.ContainerRegistry/registries/scopeMaps@2025-04-01' = {
  parent: containerRegistry
  name: scopeMapName
  properties: {
    actions: [
      'repositories/${imageRepository}/content/read'
      'repositories/${imageRepository}/metadata/read'
    ]
    description: 'Read-only pull access for the Flex Consumption Function App.'
  }
}

resource pullToken 'Microsoft.ContainerRegistry/registries/tokens@2025-04-01' = {
  parent: containerRegistry
  name: tokenName
  properties: {
    scopeMapId: scopeMap.id
    status: 'enabled'
  }
}

module appServicePlan 'br/public:avm/res/web/serverfarm:0.1.1' = {
  name: 'app-service-plan'
  params: {
    name: appServicePlanName
    location: functionLocation
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
    reserved: true
  }
}

module virtualNetwork './vnet.bicep' = {
  name: 'virtual-network'
  params: {
    name: virtualNetworkName
    location: functionLocation
    tags: tags
  }
}

module storagePrivateEndpoint './storage-private-endpoint.bicep' = {
  name: 'storage-private-endpoint'
  params: {
    name: '${take(storageAccountName, 18)}-${take(resourceToken, 4)}'
    location: functionLocation
    storageAccountName: storageAccountName
    subnetResourceId: virtualNetwork.outputs.privateEndpointSubnetId
    virtualNetworkId: virtualNetwork.outputs.virtualNetworkId
    tags: tags
  }
  dependsOn: [
    storage
  ]
}

module runtimeRbac './rbac.bicep' = {
  name: 'runtime-rbac'
  params: {
    applicationInsightsName: applicationInsightsName
    managedIdentityPrincipalId: userAssignedIdentity.outputs.principalId
    storageAccountName: storageAccountName
  }
  dependsOn: [
    applicationInsights
    storage
  ]
}

output containerRegistryName string = containerRegistry.name
output containerRegistryEndpoint string = containerRegistry.properties.loginServer
output imageRepository string = imageRepository
output scopeMapName string = scopeMap.name
output tokenName string = pullToken.name
output functionAppName string = functionAppName
output functionAppId string = resourceId('Microsoft.Web/sites', functionAppName)
output appServicePlanId string = appServicePlan.outputs.resourceId
output storageAccountName string = storage.outputs.name
output applicationInsightsName string = applicationInsights.outputs.name
output applicationInsightsConnectionString string = applicationInsights.outputs.connectionString
output userAssignedIdentityId string = userAssignedIdentity.outputs.resourceId
output userAssignedIdentityClientId string = userAssignedIdentity.outputs.clientId
output functionSubnetId string = virtualNetwork.outputs.functionSubnetId
