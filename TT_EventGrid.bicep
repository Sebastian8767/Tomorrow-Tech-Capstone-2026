/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_EventGrid.bicep `
  --parameters `
    storageAccountName=<Storage Account Name> `
    functionAppName=<Function App Name>

*/

@description('Name of the existing storage account (output from TT_Storage_Account.bicep)')
param storageAccountName string

@description('Name of the existing Function App (output from TT_FunctionApp.bicep)')
param functionAppName string

@description('Location')
param location string = resourceGroup().location

// Matches the "<storageaccountname>-topic" pattern visible in the portal
var systemTopicName = '${storageAccountName}-topic'

// Reference existing resources
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

resource functionApp 'Microsoft.Web/sites@2023-01-01' existing = {
  name: functionAppName
}

// Event Grid System Topic scoped to the storage account
resource systemTopic 'Microsoft.EventGrid/systemTopics@2023-12-15-preview' = {
  name: systemTopicName
  location: location
  properties: {
    source: storageAccount.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

// Event subscription: blob created in sensor-csv/incoming/*.csv → Function App
resource eventSubscription 'Microsoft.EventGrid/systemTopics/eventSubscriptions@2023-12-15-preview' = {
  name: 'csv-blob-trigger-subscription'
  parent: systemTopic
  properties: {
    destination: {
      endpointType: 'AzureFunction'
      properties: {
        resourceId: '${functionApp.id}/functions/CsvBlobTrigger'
        maxEventsPerBatch: 1
        preferredBatchSizeInKilobytes: 64
      }
    }
    filter: {
      includedEventTypes: [
        'Microsoft.Storage.BlobCreated'
      ]
      subjectBeginsWith: '/blobServices/default/containers/sensor-csv/blobs/incoming/'
      subjectEndsWith: '.csv'
    }
    eventDeliverySchema: 'EventGridSchema'
    retryPolicy: {
      maxDeliveryAttempts: 30
      eventTimeToLiveInMinutes: 1440
    }
  }
}

output systemTopicName string = systemTopic.name
output eventSubscriptionName string = eventSubscription.name
