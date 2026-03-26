/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_FunctionApp.bicep `
  --parameters `
    storageAccountName=<Storage Account Name> `
    sqlConnectionString="Server=tcp:<SQL FQDN>,1433;Initial Catalog=GBTAC-Database;User ID=gbtacadmin;Password=<password>;Encrypt=True;TrustServerCertificate=False;" `
  --query "properties.outputs.functionAppName.value" `
  --output tsv ; Write-Host "^^^ COPY THIS ^^^"
  
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

@description('Instance memory in MB for Flex Consumption plan')
param instanceMemoryMB int = 2048

@description('Maximum instance count for Flex Consumption plan')
param maximumInstanceCount int = 100

var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)
var functionAppName = '${functionAppBaseName}-${uniqueSuffix}'

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

// Flex Consumption Plan (FC1) — matches portal "Flex Consumption" plan type
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: '${functionAppName}-plan'
  location: location
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  kind: 'functionapp'
  properties: {
    reserved: true // Required for Linux
  }
}

// Function App (Flex Consumption / Linux / Python)
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageAccount.properties.primaryEndpoints.blob}deployments'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'AzureWebJobsStorage'
          }
        }
      }
      scaleAndConcurrency: {
        instanceMemoryMB: instanceMemoryMB
        maximumInstanceCount: maximumInstanceCount
      }
      runtime: {
        name: 'python'
        version: '3.11'
      }
    }
  }
}

// App settings as separate resource — required pattern for Flex Consumption
resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  name: 'appsettings'
  parent: functionApp
  properties: {
    AzureWebJobsStorage: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net'
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    SqlConnectionString: sqlConnectionString
  }
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output appInsightsName string = appInsights.name
output appServicePlanName string = appServicePlan.name
