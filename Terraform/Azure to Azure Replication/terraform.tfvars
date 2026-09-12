vault_name                = "Recovery-Vault-Terraform"
vault_resource_group_name = "Hyper-V-Recovery-Vault_Terraform1"
vault_location            = "Central US"

source_vm_name                = "somwin1"
source_vm_resource_group_name = "somvm"

target_virtual_network_name        = "somvmvnet-asr"
target_network_resource_group_name = "somasrdr"
target_subnet_name                 = "somsub"

cache_storage_account_name                = "ij4n2usomasrwestasrcache"
cache_storage_account_resource_group_name = "somasrwestus"
