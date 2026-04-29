/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_WebApp.bicep `
  --parameters `
    sqlPassword=P@ssw0rd!123! `
  --output none

az deployment group show `
  --resource-group GBTAC-RG `
  --name TT_WebApp `
  --query "properties.outputs.webAppName.value" `
  --output tsv ; Write-Host "^^ Copy Web App Name Above ^^"

az deployment group show `
  --resource-group GBTAC-RG `
  --name TT_WebApp `
  --query "properties.outputs.webAppUrl.value" `
  --output tsv ; Write-Host "^^ Copy Web App URL Above ^^"

Post-deployment Step 1 — Whitelist Web App outbound IPs in Azure SQL firewall.
Replace <SQL_SERVER_NAME> with the server name from TT_SQL.bicep output:

  $ips = az webapp show `
    --name <webAppName from output> `
    --resource-group GBTAC-RG `
    --query "outboundIpAddresses" `
    --output tsv

  $ips.Split(',') | ForEach-Object {
    az sql server firewall-rule create `
      --resource-group GBTAC-RG `
      --server <SQL_SERVER_NAME> `
      --name "WebApp-$_" `
      --start-ip-address $_ `
      --end-ip-address $_
  }

Post-deployment Step 2 — Deploy application files.
From your local gbtac-bms/ project folder (structure must match exactly — see below):

  az login
  az webapp up `
    --name <webAppName from output> `
    --resource-group GBTAC-RG `
    --runtime "PYTHON:3.11"

Post-deployment Step 3 — Update SERVER_URL in server.py on VM1.
Change the SERVER_URL constant to point at the Web App URL from the output above:

  SERVER_URL = "https://<webAppName>.canadacentral-01.azurewebsites.net/update"

Required project folder structure for az webapp up:

  gbtac-bms/
  ├── webapp_server.py
  ├── requirements.txt
  ├── templates/
  │   ├── home.html
  │   ├── historical_data.html
  │   ├── sensor_browser.html
  │   ├── admin.html
  │   ├── superuser.html
  │   ├── user_admin_settings.html
  │   ├── bms_dashboard_with_csv.html
  │   ├── login.html
  │   ├── logout.html
  │   └── about.html
  └── static/
      ├── styleV2.css
      └── scriptsV2.js

*/

@description('Location')
param location string = resourceGroup().location

@description('Base name for the Web App — a unique suffix is appended automatically')
param webAppBaseName string = 'gbtac-bms'

@description('App Service Plan name')
param appServicePlanName string = 'gbtac-bms-plan'

@description('Azure SQL server short name only — do NOT include .database.windows.net (output from TT_SQL.bicep sqlServerName)')
param sqlServerName string = 'gbtac-sql'

@description('Azure SQL database name')
param sqlDatabase string = 'GBTAC-Database'

@description('Azure SQL admin username')
param sqlUsername string = 'gbtacadmin'

@secure()
@description('Azure SQL admin password')
param sqlPassword string

@secure()
@description('Flask secret key — any random string')
param flaskSecretKey string = 'gbtac-secret-2026'

// FIX: Append a unique suffix so the name never conflicts across deployments,
// matching the same pattern used by TT_Storage_Account.bicep and TT_FunctionApp.bicep.
var webAppName = '${webAppBaseName}-${substring(uniqueString(resourceGroup().id), 0, 8)}'

// FIX: Construct the full SQL FQDN using environment() to satisfy the
// no-hardcoded-env-urls linter rule — avoids hardcoding database.windows.net.
var sqlFqdn = '${sqlServerName}${environment().suffixes.sqlServerHostname}'

// ── App Service Plan — Basic B1, Linux ───────────────────────
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true   // required for Linux plans
  }
}

// ── Web App — Python 3.11, Linux ─────────────────────────────
resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appCommandLine: 'gunicorn --bind=0.0.0.0:8000 webapp_server:app'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      appSettings: [
        // Azure SQL connection details — read by webapp_server.py via os.environ
        {
          name:  'AZURE_SQL_SERVER'
          value: sqlFqdn
        }
        {
          name:  'AZURE_SQL_DATABASE'
          value: sqlDatabase
        }
        {
          name:  'AZURE_SQL_USERNAME'
          value: sqlUsername
        }
        {
          name:  'AZURE_SQL_PASSWORD'
          value: sqlPassword
        }
        // Flask session secret
        {
          name:  'FLASK_SECRET_KEY'
          value: flaskSecretKey
        }
        // Tells Kudu to run pip install during zip/az webapp up deployment
        {
          name:  'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
      ]
    }
  }
}

output webAppName string = webApp.name
output webAppUrl  string = 'https://${webApp.properties.defaultHostName}'
output webAppOutboundIps string = webApp.properties.outboundIpAddresses
