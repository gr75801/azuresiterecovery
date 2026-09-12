# =============================================================================
#  Azure Site Recovery - Hyper-V Recovery Services Vault
#  Chapter 11 reference configuration
# =============================================================================

# Provides configuration details for Terraform
terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.1"
    }
  }
}

# Provides configuration details for the Azure Terraform provider
provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    recovery_service {
      vm_backup_stop_protection_and_retain_data_on_destroy = false
      purge_protected_items_from_vault_on_destroy          = false
    }
  }
}

# -----------------------------------------------------------------------------
#  Variables
# -----------------------------------------------------------------------------

variable "subscription_id" {
  description = "The Azure subscription in which the resources are created."
  type        = string
  default = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}

variable "location" {
  description = "Azure region for the resource group and the vault."
  type        = string
  default     = "East US"
}

variable "resource_group_name" {
  description = "Name of the resource group holding the Site Recovery resources."
  type        = string
  default     = "Hyper-V-Recovery-Vault_Terraform1"
}

variable "vault_name" {
  description = "Name of the Recovery Services vault."
  type        = string
  default     = "Recovery-Vault-Terraform"
}

# -----------------------------------------------------------------------------
#  Resource group
# -----------------------------------------------------------------------------

resource "azurerm_resource_group" "example" {
  name     = var.resource_group_name
  location = var.location

  tags = {
    environment = "Lab"
    purpose     = "Azure Site Recovery"
  }
}

# -----------------------------------------------------------------------------
#  Recovery Services vault
# -----------------------------------------------------------------------------

resource "azurerm_recovery_services_vault" "vault" {
  name                = var.vault_name
  location            = azurerm_resource_group.example.location
  resource_group_name = azurerm_resource_group.example.name
  sku                 = "Standard"

  # Soft delete keeps deleted backup items for 14 days. Leave it enabled in
  # production. To change this behavior, configure soft delete settings
  # outside of this deprecated attribute (the provider has replaced the
  # deprecated "soft_delete_enabled" argument with newer configuration).

  # Enables the system assigned managed identity. Site Recovery uses this
  # identity to reach the cache and target storage accounts, so the role
  # assignments covered in Chapter 9 can be attached to it later.
  identity {
    type = "SystemAssigned"
  }

  storage_mode_type = "GeoRedundant"

  tags = {
    environment = "Lab"
    purpose     = "Azure Site Recovery"
  }
}

# -----------------------------------------------------------------------------
#  Outputs
# -----------------------------------------------------------------------------

output "resource_group_name" {
  description = "Name of the resource group that was created."
  value       = azurerm_resource_group.example.name
}

output "vault_id" {
  description = "Resource ID of the Recovery Services vault."
  value       = azurerm_recovery_services_vault.vault.id
}

output "vault_identity_principal_id" {
  description = "Object ID of the vault managed identity, used for role assignments."
  value       = azurerm_recovery_services_vault.vault.identity[0].principal_id
}
