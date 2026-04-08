/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_FunctionApp.bicep `
  --parameters `
    storageAccountName=<Storage Account Name> `
    sqlConnectionString="Server=tcp:<SQL FQDN>,1433;Initial Catalog=GBTAC-Database;User ID=gbtacadmin;Password=<password>;Encrypt=True;TrustServerCertificate=False;" `
  --query "properties.outputs.functionAppName.value" `
  --output tsv ; Write-Host "^^ Copy Function App Name Above ^^"
*/

@description('Name of the existing storage account (output from TT_Storage_Account.bicep)')
param storageAccountName string

@description('Full SQL connection string for the database')
@secure()
param sqlConnectionString string

@description('Location')
param location string = resourceGroup().location

@description('Base name for the Function App')
param functionAppBaseName string = 'gbtac-csv-loader'

@description('Name for Application Insights')
param appInsightsName string = 'gbtac-csv-loader-insights'

var functionAppName = '${functionAppBaseName}-${substring(uniqueString(resourceGroup().id), 0, 4)}'

// Reference the existing storage account
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' existing = {
  name: storageAccountName
}

// Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    RetentionInDays: 90
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// Flex Consumption plan — required for zip deploy to work correctly with Python on Linux
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${functionAppName}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

// Function App
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'AzureWebJobsStorage__accountName'
          value: storageAccount.name
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'SqlConnectionString'
          value: sqlConnectionString
        }
      ]
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: 'https://${storageAccount.name}.blob.${environment().suffixes.storage}/function-releases'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
  }
}

// Grant the Function App's managed identity Storage Blob Data Contributor on the storage account
// Required for Flex Consumption to read/write deployment packages
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, functionApp.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output appInsightsName string = appInsights.name
output appServicePlanName string = appServicePlan.name
