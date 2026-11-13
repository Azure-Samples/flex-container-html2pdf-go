targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param tags object = {}

var privateEndpointSubnetName = 'private-endpoints'
var functionSubnetName = 'function-integration'

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'vnet'
  params: {
    name: name
    location: location
    tags: tags
    addressPrefixes: [
      '10.0.0.0/16'
    ]
    subnets: [
      {
        name: privateEndpointSubnetName
        addressPrefix: '10.0.1.0/24'
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
      {
        name: functionSubnetName
        addressPrefix: '10.0.2.0/27'
        privateEndpointNetworkPolicies: 'Enabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
        delegation: 'Microsoft.App/environments'
      }
    ]
  }
}

output virtualNetworkId string = virtualNetwork.outputs.resourceId
output privateEndpointSubnetId string = '${virtualNetwork.outputs.resourceId}/subnets/${privateEndpointSubnetName}'
output functionSubnetId string = '${virtualNetwork.outputs.resourceId}/subnets/${functionSubnetName}'
