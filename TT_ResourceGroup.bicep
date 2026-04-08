/*
Azure CLI command to deploy this Bicep file:

az deployment sub create \
  --name create-rg \
  --location canadacentral \
  --template-file TT_ResourceGroup.bicep
  
*/
targetScope = 'subscription'

@description('Name of the resource group')
param resourceGroupName string = 'GBTAC-RG'

@description('Location for the resource group')
param location string = 'canadacentral'

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
}
