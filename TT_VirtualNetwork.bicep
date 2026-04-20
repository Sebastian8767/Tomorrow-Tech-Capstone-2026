/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_VirtualNetwork.bicep

*/

@description('Location')
param location string = resourceGroup().location

// Virtual Network
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: 'Yabe-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.0.0.0/24'
        }
      }
      {
        // Required dedicated subnet for Azure Bastion — name must be exactly AzureBastionSubnet
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.1.0/26'
        }
      }
    ]
  }
}

// Azure Bastion — Developer tier
// Developer tier associates to the VNet via the AzureBastionSubnet automatically
resource bastion 'Microsoft.Network/bastionHosts@2023-04-01' = {
  name: 'Yabe-vnet-bastion'
  location: location
  sku: {
    name: 'Developer'
  }
  dependsOn: [
    vnet
  ]
  properties: {}
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output defaultSubnetId string = vnet.properties.subnets[0].id
output bastionName string = bastion.name
