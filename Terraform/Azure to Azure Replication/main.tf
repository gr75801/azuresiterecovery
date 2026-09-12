terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "azurerm" {
  features {}
  # Set ARM_SUBSCRIPTION_ID env var, or uncomment:
  # subscription_id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}

provider "azapi" {}

# ---------------- Existing source VM (read-only) ----------------
data "azurerm_resource_group" "source" {
  name = var.source_vm_resource_group_name
}

# azapi is used because the azurerm VM data source doesn't return NIC / OS-disk IDs.
data "azapi_resource" "vm" {
  type      = "Microsoft.Compute/virtualMachines@2024-03-01"
  name      = var.source_vm_name
  parent_id = data.azurerm_resource_group.source.id

  response_export_values = ["*"]
}

locals {
  source_vm_id      = data.azapi_resource.vm.id
  source_location   = data.azapi_resource.vm.output.location
  source_nic_id     = data.azapi_resource.vm.output.properties.networkProfile.networkInterfaces[0].id
  source_os_disk_id = data.azapi_resource.vm.output.properties.storageProfile.osDisk.managedDisk.id
}

# ---------------- Existing target network + cache (read-only) ----------------
data "azurerm_resource_group" "target" {
  name = var.target_network_resource_group_name
}

data "azurerm_virtual_network" "target" {
  name                = var.target_virtual_network_name
  resource_group_name = var.target_network_resource_group_name
}

data "azurerm_storage_account" "cache" {
  name                = var.cache_storage_account_name
  resource_group_name = var.cache_storage_account_resource_group_name
}

# ---------------- Recovery Services Vault ----------------
resource "azurerm_resource_group" "vault" {
  name     = var.vault_resource_group_name
  location = var.vault_location
}

resource "azurerm_recovery_services_vault" "vault" {
  name                = var.vault_name
  location            = azurerm_resource_group.vault.location
  resource_group_name = azurerm_resource_group.vault.name
  sku                 = "Standard"

  identity {
    type = "SystemAssigned"
  }
}

# ---------------- Vault MSI access to the cache storage account ----------------
# Required because the cache account blocks shared-key auth, so ASR uses the vault identity.
resource "azurerm_role_assignment" "vault_cache_contributor" {
  scope                = data.azurerm_storage_account.cache.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_recovery_services_vault.vault.identity[0].principal_id
}

resource "azurerm_role_assignment" "vault_cache_blob_contributor" {
  scope                = data.azurerm_storage_account.cache.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_recovery_services_vault.vault.identity[0].principal_id
}

# Give RBAC time to propagate before enabling replication.
resource "time_sleep" "rbac_propagation" {
  depends_on = [
    azurerm_role_assignment.vault_cache_contributor,
    azurerm_role_assignment.vault_cache_blob_contributor,
  ]
  create_duration = "120s"
}

# ---------------- Site Recovery: fabrics ----------------
resource "azurerm_site_recovery_fabric" "primary" {
  name                = "primary-fabric"
  resource_group_name = azurerm_resource_group.vault.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name
  location            = local.source_location
}

resource "azurerm_site_recovery_fabric" "secondary" {
  name                = "secondary-fabric"
  resource_group_name = azurerm_resource_group.vault.name
  recovery_vault_name = azurerm_recovery_services_vault.vault.name
  location            = data.azurerm_virtual_network.target.location
}

# ---------------- Protection containers ----------------
resource "azurerm_site_recovery_protection_container" "primary" {
  name                 = "primary-protection-container"
  resource_group_name  = azurerm_resource_group.vault.name
  recovery_vault_name  = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name = azurerm_site_recovery_fabric.primary.name
}

resource "azurerm_site_recovery_protection_container" "secondary" {
  name                 = "secondary-protection-container"
  resource_group_name  = azurerm_resource_group.vault.name
  recovery_vault_name  = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name = azurerm_site_recovery_fabric.secondary.name
}

# ---------------- Replication policy + mapping ----------------
resource "azurerm_site_recovery_replication_policy" "policy" {
  name                                                 = "policy"
  resource_group_name                                  = azurerm_resource_group.vault.name
  recovery_vault_name                                  = azurerm_recovery_services_vault.vault.name
  recovery_point_retention_in_minutes                  = var.recovery_point_retention_in_minutes
  application_consistent_snapshot_frequency_in_minutes = var.app_consistent_snapshot_frequency_in_minutes
}

resource "azurerm_site_recovery_protection_container_mapping" "container-mapping" {
  name                                      = "container-mapping"
  resource_group_name                       = azurerm_resource_group.vault.name
  recovery_vault_name                       = azurerm_recovery_services_vault.vault.name
  recovery_fabric_name                      = azurerm_site_recovery_fabric.primary.name
  recovery_source_protection_container_name = azurerm_site_recovery_protection_container.primary.name
  recovery_target_protection_container_id   = azurerm_site_recovery_protection_container.secondary.id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.policy.id
}

# ---------------- Enable replication for the existing VM ----------------
resource "azurerm_site_recovery_replicated_vm" "vm-replication" {
  name                                      = "${var.source_vm_name}-replication"
  resource_group_name                       = azurerm_resource_group.vault.name
  recovery_vault_name                       = azurerm_recovery_services_vault.vault.name
  source_recovery_fabric_name               = azurerm_site_recovery_fabric.primary.name
  source_vm_id                              = local.source_vm_id
  recovery_replication_policy_id            = azurerm_site_recovery_replication_policy.policy.id
  source_recovery_protection_container_name = azurerm_site_recovery_protection_container.primary.name

  target_resource_group_id                = data.azurerm_resource_group.target.id
  target_recovery_fabric_id               = azurerm_site_recovery_fabric.secondary.id
  target_recovery_protection_container_id = azurerm_site_recovery_protection_container.secondary.id
  target_network_id                       = data.azurerm_virtual_network.target.id

  managed_disk {
    disk_id                    = local.source_os_disk_id
    staging_storage_account_id = data.azurerm_storage_account.cache.id
    target_resource_group_id   = data.azurerm_resource_group.target.id
    target_disk_type           = "Premium_LRS"
    target_replica_disk_type   = "Premium_LRS"
  }

  network_interface {
    source_network_interface_id = local.source_nic_id
    target_subnet_name          = var.target_subnet_name
  }

  depends_on = [
    azurerm_site_recovery_protection_container_mapping.container-mapping,
    time_sleep.rbac_propagation,
  ]
}
