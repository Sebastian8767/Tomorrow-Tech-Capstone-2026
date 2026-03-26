/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
    --resource-group GBTAC-RG `
    --template-file TT_Storage_Account.bicep `
    --query "properties.outputs.storageAccountName.value" `
    --output tsv ; Write-Host "^^^ COPY THIS ^^^"
    
*/

@description('Base name for the storage account')
param storageAccountBaseName string = 'gbtacstorage'

var storageAccountName = '${storageAccountBaseName}${substring(uniqueString(resourceGroup().id), 0, 8)}'

@description('Location')
param location string = resourceGroup().location

// Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: {
    name: 'Standard_RAGRS' // Read-access geo-redundant storage (RA-GRS)
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: true
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Blob service settings — soft delete for blobs and containers
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

// sensor-csv container with Blob-level anonymous access
resource sensorCsvContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'sensor-csv'
  parent: blobService
  properties: {
    publicAccess: 'Blob'
  }
}

output storageAccountName string = storageAccount.name
