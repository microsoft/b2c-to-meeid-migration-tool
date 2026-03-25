param location string
param vmName string
param vmSize string
param adminUsername string
@secure()
param adminSshPublicKey string
param workersSubnetId string
// Storage account name (not ID) is needed to create the 'existing' resource for role assignment scope.
param storageAccountName string
param tags object
// Set to false when redeploying to existing VMs — Azure rejects customData changes.
param includeCustomData bool = true

var storageQueueDataContributorRoleDefId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var storageBlobDataContributorRoleDefId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageTableDataContributorRoleDefId = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'

var cloudInit = base64('''#cloud-config
package_update: true
packages:
  - dotnet-sdk-8.0
  - jq
  - unzip
runcmd:
  - |
    echo "✅ cloud-init prerequisites installed"
''')

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-${vmName}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: workersSubnetId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
        deleteOption: 'Delete'
      }
    }
    osProfile: union({
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
        }
      }
    }, includeCustomData ? { customData: cloudInit } : {})
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: { deleteOption: 'Delete' }
        }
      ]
    }
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Storage Queue Data Contributor — read/dequeue work items
resource queueRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vmName, storageQueueDataContributorRoleDefId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageQueueDataContributorRoleDefId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor — read export blobs + upload telemetry JSONL
resource blobRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vmName, storageBlobDataContributorRoleDefId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleDefId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Table Data Contributor — write audit records (Advanced Mode)
resource tableRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vmName, storageTableDataContributorRoleDefId)
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageTableDataContributorRoleDefId)
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output vmName string = vm.name
output vmPrivateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress
output vmPrincipalId string = vm.identity.principalId
