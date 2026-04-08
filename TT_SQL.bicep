/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_SQL.bicep `
  --parameters `
    adminPassword=P@ssw0rd!123! `
    sqlServerBaseName=gbtac-sql- `
  --query "properties.outputs.sqlServerFqdn.value" `
  --output tsv ; Write-Host "^^ Copy SQL FQDN Above ^^"

*/

@description('Base name for the SQL server (must be globally unique after suffix)')
param sqlServerBaseName string

@description('Database name')
param databaseName string = 'GBTAC-Database'

@description('Location')
param location string = resourceGroup().location

@description('SQL admin username')
param adminUsername string = 'gbtacadmin'

@secure()
@description('SQL admin password')
param adminPassword string

// Generate globally unique SQL server name
var sqlServerName = '${sqlServerBaseName}-${uniqueString(resourceGroup().id)}'

// SQL Server
resource sqlServer 'Microsoft.Sql/servers@2024-11-01-preview' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: adminUsername
    administratorLoginPassword: adminPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    restrictOutboundNetworkAccess: 'Disabled'
  }
}

// SQL Database
resource sqlDatabase 'Microsoft.Sql/servers/databases@2024-11-01-preview' = {
  name: databaseName
  parent: sqlServer
  location: location
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 34359738368
    autoPauseDelay: 60
    readScale: 'Disabled'
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
  }
}

// Displays the FQDN for the connection string used in the next step.
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
