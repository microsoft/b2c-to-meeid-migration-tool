targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'eastus'

@description('Name of the resource group to create.')
param resourceGroupName string = 'rg-b2c-migration'

@description('Storage account name (3-24 lowercase alphanumeric, globally unique).')
param storageAccountName string

@description('Number of worker VMs to deploy (default: 5 — 1 master + 2 user-workers + 2 phone-workers).')
param vmCount int = 5

@description('VM size for each worker node. Standard_B2s (2 vCPU / 4 GB) is sufficient for HTTP-bound workloads.')
param vmSize string = 'Standard_B2s'

@description('Local admin username for the VMs.')
param adminUsername string = 'azureuser'

@description('SSH public key used for VM admin access (recommended over password auth).')
@secure()
param adminSshPublicKey string

@description('Include cloud-init customData on VMs. Set to false when redeploying to existing VMs (Azure rejects customData changes).')
param includeCustomData bool = true

@description('Deploy Azure Bastion for SSH access to VMs (adds ~$5/day). Can be stopped when not needed.')
param deployBastion bool = true

param tags object = {
  project: 'b2c-migration'
  managedBy: 'bicep'
}

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  name: 'network'
  scope: rg
  params: {
    location: location
    tags: tags
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    location: location
    storageAccountName: storageAccountName
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
    tags: tags
  }
}

module workers 'modules/vm.bicep' = [for i in range(0, vmCount): {
  name: 'worker-${i}'
  scope: rg
  params: {
    location: location
    vmName: 'vm-b2c-worker${i + 1}'
    vmSize: vmSize
    adminUsername: adminUsername
    adminSshPublicKey: adminSshPublicKey
    workersSubnetId: network.outputs.workersSubnetId
    storageAccountName: storage.outputs.storageAccountName
    includeCustomData: includeCustomData
    tags: tags
  }
}]

// Key Vault — stores app registration secrets; VMs access via Managed Identity.
module keyvault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  scope: rg
  params: {
    location: location
    tags: tags
    peSubnetId: network.outputs.peSubnetId
    vnetId: network.outputs.vnetId
    vmPrincipalIds: [for i in range(0, vmCount): workers[i].outputs.vmPrincipalId]
  }
}

// Azure Bastion — optional, for SSH access to VMs without public IPs.
module bastion 'modules/bastion.bicep' = if (deployBastion) {
  name: 'bastion'
  scope: rg
  params: {
    location: location
    tags: tags
    vnetName: 'vnet-b2c-migration'
  }
  dependsOn: [network]
}

output resourceGroupName string = rg.name
output storageAccountName string = storage.outputs.storageAccountName
output storageQueueEndpoint string = storage.outputs.storageQueueEndpoint
output storageBlobEndpoint string = storage.outputs.storageBlobEndpoint
output storageTableEndpoint string = storage.outputs.storageTableEndpoint
output keyVaultName string = keyvault.outputs.keyVaultName
output keyVaultUri string = keyvault.outputs.keyVaultUri
