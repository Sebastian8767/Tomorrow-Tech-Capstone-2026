/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_VirtualMachines.bicep `
  --parameters adminPassword=P@ssw0rd!123! `
  --query "[properties.outputs.yabePublicIp.value, properties.outputs.mqttPublicIp.value]" `
  --output tsv ; Write-Host "^^^ COPY YABE IP (line 1) AND MQTT IP (line 2) ^^^"

Post-deployment Step 1 — Add SQL firewall rules via Azure CLI.
Replace <YABE_IP> and <MQTT_IP> with the IPs printed above, <LOCAL_IP> with your machine public IP,
and <SQL_SERVER_NAME> with the server name output from TT_SQL.bicep (e.g. gbtac-sql--<uniqueSuffix>):

az sql server firewall-rule create `
  --resource-group GBTAC-RG `
  --server <SQL_SERVER_NAME> `
  --name "Yabe-VM" `
  --start-ip-address <YABE_IP> `
  --end-ip-address <YABE_IP>

az sql server firewall-rule create `
  --resource-group GBTAC-RG `
  --server <SQL_SERVER_NAME> `
  --name "MQTT-VM" `
  --start-ip-address <MQTT_IP> `
  --end-ip-address <MQTT_IP>

az sql server firewall-rule create `
  --resource-group GBTAC-RG `
  --server <SQL_SERVER_NAME> `
  --name "LocalDev" `
  --start-ip-address <LOCAL_IP> `
  --end-ip-address <LOCAL_IP>

Post-deployment Step 2 — Run inside MQTT VM via Bastion as Administrator in PowerShell:

  netsh advfirewall firewall add rule name="Datagen WebSocket" dir=in action=allow protocol=TCP localport=9000
  netsh advfirewall firewall add rule name="Pi WebSocket"      dir=in action=allow protocol=TCP localport=9001
  netsh advfirewall firewall add rule name="MQTT Broker"       dir=in action=allow protocol=TCP localport=1883

Post-deployment Step 3 — Run inside Yabe VM via Bastion as Administrator in PowerShell:

  netsh advfirewall firewall add rule name="Flask BMS" dir=in action=allow protocol=TCP localport=5000

*/

@description('Location')
param location string = resourceGroup().location

@description('Admin username for both VMs')
param adminUsername string = 'GBTAC-admin'

@secure()
@description('Admin password for both VMs')
param adminPassword string

// Reference existing VNet and subnet
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' existing = {
  name: 'Yabe-vnet'
}

resource defaultSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-04-01' existing = {
  name: 'default'
  parent: vnet
}

// --- YABE VM (VM2 — BMS Server) ---

resource yabePublicIp 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'Yabe-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource yabeNsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'Yabe-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'RDP'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Flask_BMS'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '5000'
        }
      }
    ]
  }
}

resource yabeNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'yabe693_z2'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: defaultSubnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: yabePublicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: yabeNsg.id
    }
  }
}

resource yabeVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'Yabe'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2als_v2'
    }
    osProfile: {
      computerName: 'Yabe'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'Yabe-OsDisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: yabeNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'Standard'
    }
    additionalCapabilities: {
      hibernationEnabled: false
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// --- MQTT VM (VM1 — Datagen / MQTT / Client) ---

resource mqttPublicIp 'Microsoft.Network/publicIPAddresses@2023-04-01' = {
  name: 'MQTT-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource mqttNsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'MQTT-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'RDP'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'HTTP'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        // datagen.py WebSocket server — client.py connects here
        name: 'Datagen_WebSocket'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '9000'
        }
      }
      {
        // FIX: Added missing rule — Raspberry Pi WebSocket connection to client.py
        name: 'Pi_WebSocket'
        properties: {
          priority: 125
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '9001'
        }
      }
      {
        name: 'MQTT'
        properties: {
          priority: 130
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '1883'
        }
      }
    ]
  }
}

resource mqttNic 'Microsoft.Network/networkInterfaces@2023-04-01' = {
  name: 'mqtt272_z2'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: defaultSubnet.id
          }
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: mqttPublicIp.id
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: mqttNsg.id
    }
  }
}

resource mqttVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'MQTT'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: 'Standard_B2als_v2'
    }
    osProfile: {
      computerName: 'MQTT'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2025-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'MQTT-OsDisk'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: mqttNic.id
        }
      ]
    }
    securityProfile: {
      securityType: 'Standard'
    }
    additionalCapabilities: {
      hibernationEnabled: false
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

output yabeVmName string = yabeVm.name
output mqttVmName string = mqttVm.name
output yabePublicIp string = yabePublicIp.properties.ipAddress
output mqttPublicIp string = mqttPublicIp.properties.ipAddress
// FIX: Added sqlServerName output so callers have the exact name needed for firewall rule CLI commands
output sqlServerNameHint string = 'Use TT_SQL.bicep output sqlServerName for firewall rule --server parameter'
