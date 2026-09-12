# ---------- Recovery Services Vault (prompted) ----------
variable "vault_name" {
  type        = string
  description = "Name of the Recovery Services Vault to create"
}

variable "vault_resource_group_name" {
  type        = string
  description = "Resource group to create for the vault"
}

variable "vault_location" {
  type        = string
  description = "Region for the vault (usually the target/recovery region)"
}

# ---------- Existing source VM (prompted) ----------
variable "source_vm_name" {
  type        = string
  description = "Name of the existing VM to replicate"
}

variable "source_vm_resource_group_name" {
  type        = string
  description = "Resource group of the existing VM"
}

# ---------- Target network + cache (prompted) ----------
variable "target_virtual_network_name" {
  type        = string
  description = "Name of the existing target (recovery) virtual network"
}

variable "target_network_resource_group_name" {
  type        = string
  description = "Resource group of the target virtual network (failover VM lands here)"
}

variable "target_subnet_name" {
  type        = string
  description = "Name of the target subnet used after failover"
}

variable "cache_storage_account_name" {
  type        = string
  description = "Name of the existing cache/staging storage account"
}

variable "cache_storage_account_resource_group_name" {
  type        = string
  description = "Resource group of the cache storage account"
}

# ---------- Optional (have defaults, won't prompt) ----------
variable "recovery_point_retention_in_minutes" {
  type    = number
  default = 1440
}

variable "app_consistent_snapshot_frequency_in_minutes" {
  type    = number
  default = 240
}
