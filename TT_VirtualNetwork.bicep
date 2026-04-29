/*
Azure CLI command to deploy this Bicep file:

az deployment group create `
  --resource-group GBTAC-RG `
  --template-file TT_VirtualNetwork.bicep

*/

@description('Location')
param location string = resourceGroup().location

// ── Subnet-level NSG ──────────────────────────────────────────────────────────
// Applied to the default subnet (10.0.0.0/24) as a second layer of defence
// behind the per-NIC NSGs on each VM.  Rules here cover all inter-VM traffic
// so any future VM added to the subnet inherits them automatically.
// The AzureBastionSubnet intentionally has NO NSG — Developer-tier Bastion
// manages its own access and Azure blocks NSGs on that subnet.
resource defaultSubnetNsg 'Microsoft.Network/networkSecurityGroups@2023-04-01' = {
  name: 'default-subnet-nsg'
  location: location
  properties: {
    securityRules: [

      // ── Inbound — allow RDP from anywhere (locked down further by per-NIC NSGs) ──
      {
        name: 'Allow_RDP_Inbound'
        properties: {
          priority:                 100
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '3389'
        }
      }

      // ── Inbound — Flask BMS (VM2 port 5000, called by VM1 client.py) ──
      {
        name: 'Allow_Flask_BMS_Inbound'
        properties: {
          priority:                 110
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '5000'
        }
      }

      // ── Inbound — Datagen WebSocket (VM1 port 9000, datagen.py → client.py) ──
      {
        name: 'Allow_Datagen_WebSocket_Inbound'
        properties: {
          priority:                 120
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '9000'
        }
      }

      // ── Inbound — Pi WebSocket (VM1 port 9001, Raspberry Pi → client.py) ──
      {
        name: 'Allow_Pi_WebSocket_Inbound'
        properties: {
          priority:                 125
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '9001'
        }
      }

      // ── Inbound — MQTT broker (VM1 port 1883) ──
      {
        name: 'Allow_MQTT_Inbound'
        properties: {
          priority:                 130
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '1883'
        }
      }

      // ── Inbound — HTTP (general, VM1 port 80) ──
      {
        name: 'Allow_HTTP_Inbound'
        properties: {
          priority:                 140
          protocol:                 'Tcp'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange:     '80'
        }
      }

      // ── Inbound — Azure infrastructure (load balancer health probes etc.) ──
      {
        name: 'Allow_AzureLoadBalancer_Inbound'
        properties: {
          priority:                 150
          protocol:                 '*'
          access:                   'Allow'
          direction:                'Inbound'
          sourceAddressPrefix:      'AzureLoadBalancer'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }

      // ── Inbound — deny everything else ──
      {
        name: 'Deny_All_Inbound'
        properties: {
          priority:                 4096
          protocol:                 '*'
          access:                   'Deny'
          direction:                'Inbound'
          sourceAddressPrefix:      '*'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }

      // ── Outbound — allow all (VMs need to reach Azure SQL, Blob, Web App, internet) ──
      {
        name: 'Allow_All_Outbound'
        properties: {
          priority:                 100
          protocol:                 '*'
          access:                   'Allow'
          direction:                'Outbound'
          sourceAddressPrefix:      'VirtualNetwork'
          sourcePortRange:          '*'
          destinationAddressPrefix: '*'
          destinationPortRange:     '*'
        }
      }
    ]
  }
}

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
          // Attach subnet-level NSG — all VMs on this subnet inherit these rules
          networkSecurityGroup: {
            id: defaultSubnetNsg.id
          }
        }
      }
      {
        // Required dedicated subnet for Azure Bastion — name must be exactly AzureBastionSubnet
        // Developer-tier Bastion does NOT support an NSG on this subnet
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: '10.0.1.0/26'
        }
      }
    ]
  }
}

// Azure Bastion — Developer tier
// The Developer SKU requires virtualNetwork.id to be explicitly provided in properties.
// API version 2024-01-01 includes virtualNetwork in the BastionHostPropertiesFormat
// schema so both the Bicep linter and the ARM API accept it without warnings.
resource bastion 'Microsoft.Network/bastionHosts@2024-01-01' = {
  name: 'Yabe-vnet-bastion'
  location: location
  sku: {
    name: 'Developer'
  }
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
  }
}

output vnetName string = vnet.name
output vnetId string = vnet.id
output defaultSubnetId string = vnet.properties.subnets[0].id
output bastionName string = bastion.name
output defaultSubnetNsgName string = defaultSubnetNsg.name
