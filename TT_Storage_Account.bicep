/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
    --resource-group GBTAC-RG `
    --template-file TT_Storage_Account.bicep `
    --query "properties.outputs.storageAccountName.value" `
    --output tsv ; Write-Host "^^ Copy Storeage Account Name Above ^^"
    
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

// Required by the Function App runtime for internal operations
resource webjobsHostsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'azure-webjobs-hosts'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// Required by the Function App runtime to store function keys and secrets
resource webjobsSecretsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'azure-webjobs-secrets'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// Required by Kudu (deployment engine) to stage zip deployments
resource scmReleasesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'scm-releases'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

// Required by Flex Consumption plan to store function deployment packages
resource functionReleasesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  name: 'function-releases'
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

output storageAccountName string = storageAccount.name
