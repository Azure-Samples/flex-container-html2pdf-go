targetScope = 'resourceGroup'

param name string
param location string = resourceGroup().location
param storageAccountName string
param subnetResourceId string
param virtualNetworkId string
param tags object = {}

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: storageAccountName
}

var privateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

module privateDnsZone 'br/public:avm/res/network/private-dns-zone:0.7.1' = {
  name: 'blob-private-dns-zone'
  params: {
    name: privateDnsZoneName
    location: 'global'
    tags: tags
    virtualNetworkLinks: [
      {
        name: '${take(name, 50)}-link'
        virtualNetworkResourceId: virtualNetworkId
        registrationEnabled: false
        location: 'global'
        tags: tags
      }
    ]
  }
}

module privateEndpoint 'br/public:avm/res/network/private-endpoint:0.11.0' = {
  name: 'blob-private-endpoint'
  params: {
    name: 'pe-${name}'
    location: location
    tags: tags
    subnetResourceId: subnetResourceId
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
    customDnsConfigs: []
    privateDnsZoneGroup: {
      name: 'blob'
      privateDnsZoneGroupConfigs: [
        {
          name: 'blob'
          privateDnsZoneResourceId: privateDnsZone.outputs.resourceId
        }
      ]
    }
  }
}
