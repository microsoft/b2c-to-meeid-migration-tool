using './main.bicep'

// Azure region — choose one close to your B2C and EEID tenants.
param location = 'eastus'

// Resource group that will be created.
param resourceGroupName = 'rg-b2c-migration'

// Storage account names must be globally unique, 3-24 lowercase alphanumeric chars.
// Run: az storage account check-name --name <name>
param storageAccountName = 'stb2cmig<SUFFIX>'

// 5 VMs: 1 master (harvest) + 2 user-workers (worker-migrate) + 2 phone-workers (phone-registration).
param vmCount = 5

// Standard_B2s: 2 vCPU / 4 GB — suitable for HTTP-bound migration workloads.
// Upgrade to Standard_D2s_v5 if you observe CPU saturation.
param vmSize = 'Standard_B2s'

param adminUsername = 'azureuser'

// Paste the contents of your SSH public key file (id_rsa.pub / id_ed25519.pub).
// Generate: ssh-keygen -t ed25519 -C "b2c-migration"
@secure()
param adminSshPublicKey = '<YOUR_SSH_PUBLIC_KEY>'

// Deploy Azure Bastion for SSH access (adds ~$5/day, stop when not needed).
param deployBastion = true

param tags = {
  project: 'b2c-migration'
  managedBy: 'bicep'
}
