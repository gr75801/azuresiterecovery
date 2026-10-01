<#
================================================================================
 asr-a2a-lab.ps1
================================================================================
 Deploys a complete Azure Site Recovery (ASR) Azure-to-Azure (A2A) lab that
 replicates a Windows VM from Central US (source) to West US (target), using
 PRIVATE ENDPOINTS for both the Recovery Services vault and the cache storage
 accounts, and MANAGED IDENTITY on the vault for cache-storage access.

 What this builds (all resources prefixed "somb"):
   - 2 resource groups            (somb-rg-cus / somb-rg-wus)
   - 2 VNets                      (source + target)
   - 1 Windows Server 2022 VM     (source, no public IP)
   - 1 Recovery Services vault    (target region) + system-assigned identity
   - 2 cache storage accounts     (public network access disabled)
   - 4 private endpoints          (2 for the vault, 2 for the storage accounts)
   - private DNS (split-horizon)  (so each region resolves the vault to its own PE)
   - full A2A replication objects (fabrics, containers, policy, mapping)
   - enable replication for the VM

 Requirements:
   - Azure CLI (az) + the "site-recovery" extension (installed automatically below)
   - Rights to create the above resources in the target subscription

 NOTE ON IDEMPOTENCY: this is a straight-through deploy script. Re-running it
 will error on resources that already exist. Delete the two resource groups to
 start clean:  az group delete -n somb-rg-cus --yes ; az group delete -n somb-rg-wus --yes
================================================================================
#>

# Stop on the first hard error so we don't build half a lab silently.
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# 0. PARAMETERS  --  edit these to taste
# ------------------------------------------------------------------------------

#subscription details, Please amend thisline with the actual subscription id:
$SubscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

#name prefix for all resources
$Prefix = 'somb'
$SrcRegion  = 'centralus'      # source region
$TgtRegion  = 'westus'         # target / DR region

$SrcRg      = 'somb-rg-cus'    # source resource group
$TgtRg      = 'somb-rg-wus'    # target resource group (also holds the vault)

$SrcVnet    = 'somb-vnet-cus'; $SrcPrefix = '10.10.0.0/16'; $SrcSubnet = '10.10.1.0/24'
$TgtVnet    = 'somb-vnet-wus'; $TgtPrefix = '10.20.0.0/16'; $TgtSubnet = '10.20.1.0/24'
$SubnetName = 'default'

$VmName     = 'somb-vm-cus'
$VmSize     = 'Standard_D2s_v3'
$VmImage    = 'Win2022Datacenter'
$AdminUser  = 'sombadmin'

$VaultName  = 'somb-rsv-wus'

# Storage account names must be GLOBALLY UNIQUE, 3-24 lowercase alphanumerics.
# A short random suffix keeps re-runs from colliding with a previous attempt.
$sfx        = -join ((48..57)+(97..122) | Get-Random -Count 5 | ForEach-Object {[char]$_})
$SrcCacheSA = "sombcache$sfx" + 'c'   # source-region cache/log storage account
$TgtCacheSA = "sombcache$sfx" + 'w'   # target-region cache (needed for re-protect/failback)

# Private endpoint names
$PeStSrc  = 'somb-pe-st-cus';  $PeStTgt  = 'somb-pe-st-wus'   # storage (blob) PEs
$PeRsvSrc = 'somb-pe-rsv-cus'; $PeRsvTgt = 'somb-pe-rsv-wus'  # vault (AzureSiteRecovery) PEs

# Private DNS zone names (fixed by Azure Private Link)
$ZoneBlob = 'privatelink.blob.core.windows.net'
$ZoneSr   = 'privatelink.siterecovery.windowsazure.com'

# ASR object names
$FabricSrc = 'somb-fabric-cus'; $FabricTgt = 'somb-fabric-wus'
$PcSrc     = 'somb-pc-cus';     $PcTgt     = 'somb-pc-wus'
$PolicyName = 'somb-a2a-policy'
$MappingName = 'somb-map-cus-to-wus'

# ------------------------------------------------------------------------------
# 1. LOGIN + SUBSCRIPTION
# ------------------------------------------------------------------------------
# az login            # <- run interactively first if you are not already signed in
az account set --subscription $SubscriptionId

# ------------------------------------------------------------------------------
# 2. RESOURCE PROVIDER + RESOURCE GROUPS
# ------------------------------------------------------------------------------
az provider register --namespace Microsoft.RecoveryServices | Out-Null
az group create -n $SrcRg -l $SrcRegion | Out-Null
az group create -n $TgtRg -l $TgtRegion | Out-Null

# ------------------------------------------------------------------------------
# 3. VNETS  (and disable PE network policies on the subnets so we can drop
#            private endpoints into them)
# ------------------------------------------------------------------------------
az network vnet create -g $SrcRg -n $SrcVnet -l $SrcRegion `
  --address-prefixes $SrcPrefix --subnet-name $SubnetName --subnet-prefixes $SrcSubnet | Out-Null
az network vnet create -g $TgtRg -n $TgtVnet -l $TgtRegion `
  --address-prefixes $TgtPrefix --subnet-name $SubnetName --subnet-prefixes $TgtSubnet | Out-Null

az network vnet subnet update -g $SrcRg --vnet-name $SrcVnet -n $SubnetName --disable-private-endpoint-network-policies true | Out-Null
az network vnet subnet update -g $TgtRg --vnet-name $TgtVnet -n $SubnetName --disable-private-endpoint-network-policies true | Out-Null

# ------------------------------------------------------------------------------
# 4. SOURCE WINDOWS VM  (no public IP, no inbound NSG rule -- ASR needs neither)
# ------------------------------------------------------------------------------
# Generate a strong admin password and stash it locally. Rotate it afterwards.
$AdminPass = 'Somb!' + -join ((48..57)+(65..90)+(97..122) | Get-Random -Count 16 | ForEach-Object {[char]$_})
$AdminPass | Out-File "$env:TEMP\somb_vm_pw.txt" -Encoding ascii -NoNewline
Write-Host "VM admin: $AdminUser / $AdminPass  (also saved to $env:TEMP\somb_vm_pw.txt)"

az vm create -g $SrcRg -n $VmName -l $SrcRegion `
  --image $VmImage --size $VmSize `
  --admin-username $AdminUser --admin-password $AdminPass `
  --vnet-name $SrcVnet --subnet $SubnetName `
  --public-ip-address '""' --nsg-rule NONE | Out-Null

# ------------------------------------------------------------------------------
# 4b. OUTBOUND INTERNET FOR THE SOURCE VM  (NAT GATEWAY)  --  REQUIRED
#
#     The Mobility Service on the source VM must authenticate to Azure AD /
#     Office 365 identity endpoints (login.microsoftonline.com, etc.). Those are
#     PUBLIC endpoints -- there is NO private endpoint for AAD -- so even a fully
#     private-endpoint ASR setup still needs an outbound path to the internet.
#
#     This VM has no public IP, and Azure has RETIRED implicit "default outbound"
#     internet access for new VMs, so without an explicit egress the enable-
#     replication job fails at "Installing Mobility Service and preparing target"
#     with error 151192 ("Connection cannot be established to Office 365
#     authentication and identity IP4 endpoints").
#
#     NOTE: the NSG already allows all outbound to the Internet service tag, so
#     adding outbound service-tag rules alone does NOT fix this -- the problem is
#     the missing egress PATH, which a NAT gateway provides.
# ------------------------------------------------------------------------------
az network public-ip create -g $SrcRg -n "$Prefix-natip-cus" -l $SrcRegion --sku Standard --allocation-method Static | Out-Null
az network nat gateway create -g $SrcRg -n "$Prefix-natgw-cus" -l $SrcRegion --public-ip-addresses "$Prefix-natip-cus" --idle-timeout 10 | Out-Null
az network vnet subnet update -g $SrcRg --vnet-name $SrcVnet -n $SubnetName --nat-gateway "$Prefix-natgw-cus" | Out-Null

# Do the same for the TARGET subnet. After a failover the West US VM becomes the
# source for re-protect/failback, so its Mobility Service also needs outbound to
# the AAD/O365 identity endpoints -- without this, re-protect fails the same way.
az network public-ip create -g $TgtRg -n "$Prefix-natip-wus" -l $TgtRegion --sku Standard --allocation-method Static | Out-Null
az network nat gateway create -g $TgtRg -n "$Prefix-natgw-wus" -l $TgtRegion --public-ip-addresses "$Prefix-natip-wus" --idle-timeout 10 | Out-Null
az network vnet subnet update -g $TgtRg --vnet-name $TgtVnet -n $SubnetName --nat-gateway "$Prefix-natgw-wus" | Out-Null

# ------------------------------------------------------------------------------
# 5. RECOVERY SERVICES VAULT (target region) + SYSTEM-ASSIGNED MANAGED IDENTITY
# ------------------------------------------------------------------------------
az backup vault create -g $TgtRg -n $VaultName -l $TgtRegion | Out-Null
az backup vault identity assign --system-assigned -g $TgtRg -n $VaultName | Out-Null

# Grab the vault MSI principalId -- we grant it rights on the cache storage next.
$VaultMsi = az resource show -g $TgtRg -n $VaultName `
  --resource-type Microsoft.RecoveryServices/vaults --query identity.principalId -o tsv

# ------------------------------------------------------------------------------
# 6. CACHE STORAGE ACCOUNTS  (public network access disabled -> reached only via PE)
# ------------------------------------------------------------------------------
foreach ($sa in @(@{n=$SrcCacheSA;g=$SrcRg;l=$SrcRegion}, @{n=$TgtCacheSA;g=$TgtRg;l=$TgtRegion})) {
  az storage account create -n $sa.n -g $sa.g -l $sa.l `
    --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 `
    --allow-blob-public-access false --public-network-access Disabled `
    --default-action Deny --bypass AzureServices | Out-Null
}

# ------------------------------------------------------------------------------
# 7. ROLE ASSIGNMENTS  --  the vault MSI needs these on BOTH cache accounts
#    BEFORE enabling replication, or the enable job fails to reach the cache.
#      * Contributor                    (manage the cache account)
#      * Storage Blob Data Contributor  (read/write the replication logs blobs)
# ------------------------------------------------------------------------------
$SrcCacheId = az storage account show -n $SrcCacheSA -g $SrcRg --query id -o tsv
$TgtCacheId = az storage account show -n $TgtCacheSA -g $TgtRg --query id -o tsv
foreach ($scope in @($SrcCacheId, $TgtCacheId)) {
  foreach ($role in @('Contributor','Storage Blob Data Contributor')) {
    az role assignment create --assignee-object-id $VaultMsi `
      --assignee-principal-type ServicePrincipal --role $role --scope $scope | Out-Null
  }
}

# ------------------------------------------------------------------------------
# 8. PRIVATE ENDPOINTS
#    a) storage (blob) PE in each region, pointing at that region's cache account
#    b) vault (AzureSiteRecovery) PE in each region, both pointing at the vault
# ------------------------------------------------------------------------------
$SrcSubnetId = az network vnet subnet show -g $SrcRg --vnet-name $SrcVnet -n $SubnetName --query id -o tsv
$TgtSubnetId = az network vnet subnet show -g $TgtRg --vnet-name $TgtVnet -n $SubnetName --query id -o tsv
$VaultId     = az resource show -g $TgtRg -n $VaultName --resource-type Microsoft.RecoveryServices/vaults --query id -o tsv

# a) storage blob PEs
az network private-endpoint create -g $SrcRg -n $PeStSrc -l $SrcRegion `
  --subnet $SrcSubnetId --private-connection-resource-id $SrcCacheId --group-id blob `
  --connection-name "$PeStSrc-conn" | Out-Null
az network private-endpoint create -g $TgtRg -n $PeStTgt -l $TgtRegion `
  --subnet $TgtSubnetId --private-connection-resource-id $TgtCacheId --group-id blob `
  --connection-name "$PeStTgt-conn" | Out-Null

# b) vault PEs (group-id "AzureSiteRecovery"). A PE lives in its subnet's region
#    but can target a vault in another region -- that is exactly what gives the
#    source region a LOCAL entry point to the (target-region) vault.
az network private-endpoint create -g $SrcRg -n $PeRsvSrc -l $SrcRegion `
  --subnet $SrcSubnetId --private-connection-resource-id $VaultId --group-id AzureSiteRecovery `
  --connection-name "$PeRsvSrc-conn" | Out-Null
az network private-endpoint create -g $TgtRg -n $PeRsvTgt -l $TgtRegion `
  --subnet $TgtSubnetId --private-connection-resource-id $VaultId --group-id AzureSiteRecovery `
  --connection-name "$PeRsvTgt-conn" | Out-Null

# ------------------------------------------------------------------------------
# 9. PRIVATE DNS  --  the important, non-obvious part
#
#    BLOB zone: one shared zone linked to both VNets is fine. The two storage
#    accounts have DIFFERENT FQDNs, so their A records coexist without clashing.
#
#    SITERECOVERY zone: must be SPLIT-HORIZON. Both vault PEs publish the SAME
#    set of FQDNs (they front the same vault), so a single shared zone can only
#    hold one region's IPs -- the other region would resolve the vault to
#    unreachable addresses. We therefore create a SEPARATE siterecovery zone per
#    region, each linked to only its own VNet, so each side resolves the vault
#    to its LOCAL private endpoint.
# ------------------------------------------------------------------------------
$SrcVnetId = az network vnet show -g $SrcRg -n $SrcVnet --query id -o tsv
$TgtVnetId = az network vnet show -g $TgtRg -n $TgtVnet --query id -o tsv

# 9a. BLOB zone (shared) -> link both VNets -> zone groups on both storage PEs
az network private-dns zone create -g $TgtRg -n $ZoneBlob | Out-Null
az network private-dns link vnet create -g $TgtRg -z $ZoneBlob -n link-cus --virtual-network $SrcVnetId --registration-enabled false | Out-Null
az network private-dns link vnet create -g $TgtRg -z $ZoneBlob -n link-wus --virtual-network $TgtVnetId --registration-enabled false | Out-Null
$BlobZoneId = az network private-dns zone show -g $TgtRg -n $ZoneBlob --query id -o tsv
az network private-endpoint dns-zone-group create -g $SrcRg --endpoint-name $PeStSrc -n zg --zone-name blob --private-dns-zone $BlobZoneId | Out-Null
az network private-endpoint dns-zone-group create -g $TgtRg --endpoint-name $PeStTgt -n zg --zone-name blob --private-dns-zone $BlobZoneId | Out-Null

# 9b. SITERECOVERY zone -- source region copy (linked to source VNet only)
az network private-dns zone create -g $SrcRg -n $ZoneSr | Out-Null
az network private-dns link vnet create -g $SrcRg -z $ZoneSr -n link-cus --virtual-network $SrcVnetId --registration-enabled false | Out-Null
$SrZoneSrcId = az network private-dns zone show -g $SrcRg -n $ZoneSr --query id -o tsv
az network private-endpoint dns-zone-group create -g $SrcRg --endpoint-name $PeRsvSrc -n zg --zone-name sr --private-dns-zone $SrZoneSrcId | Out-Null

# 9c. SITERECOVERY zone -- target region copy (linked to target VNet only)
az network private-dns zone create -g $TgtRg -n $ZoneSr | Out-Null
az network private-dns link vnet create -g $TgtRg -z $ZoneSr -n link-wus --virtual-network $TgtVnetId --registration-enabled false | Out-Null
$SrZoneTgtId = az network private-dns zone show -g $TgtRg -n $ZoneSr --query id -o tsv
az network private-endpoint dns-zone-group create -g $TgtRg --endpoint-name $PeRsvTgt -n zg --zone-name sr --private-dns-zone $SrZoneTgtId | Out-Null

# ------------------------------------------------------------------------------
# 10. AZURE SITE RECOVERY -- A2A REPLICATION OBJECTS
#     Order: extension -> fabrics -> containers -> policy -> mapping -> enable.
# ------------------------------------------------------------------------------
az extension add -n site-recovery --only-show-errors 2>$null

# 10a. Fabrics: one Azure fabric per region (shorthand: {azure:{location:...}})
az site-recovery fabric create -g $TgtRg --vault-name $VaultName -n $FabricSrc --custom-details "{azure:{location:$SrcRegion}}" | Out-Null
az site-recovery fabric create -g $TgtRg --vault-name $VaultName -n $FabricTgt --custom-details "{azure:{location:$TgtRegion}}" | Out-Null

# 10b. Protection containers: one per fabric (provider-input [{instance-type:A2A}])
az site-recovery protection-container create -g $TgtRg --vault-name $VaultName --fabric-name $FabricSrc -n $PcSrc --provider-input '[{instance-type:A2A}]' | Out-Null
az site-recovery protection-container create -g $TgtRg --vault-name $VaultName --fabric-name $FabricTgt -n $PcTgt --provider-input '[{instance-type:A2A}]' | Out-Null

# 10c. Replication policy:
#        multi-VM sync enabled, 24h (1440 min) recovery-point history,
#        60-min app-consistent, 5-min crash-consistent.
az site-recovery policy create -g $TgtRg --vault-name $VaultName -n $PolicyName `
  --provider-specific-input '{a2a:{multi-vm-sync-status:Enable,recovery-point-history:1440,app-consistent-frequency-in-minutes:60,crash-consistent-frequency-in-minutes:5}}' | Out-Null

# 10d. Container mapping: source container -> target container, bound to the policy.
$PolicyId = az site-recovery policy show -g $TgtRg --vault-name $VaultName -n $PolicyName --query id -o tsv
$TgtPcId  = az site-recovery protection-container show -g $TgtRg --vault-name $VaultName --fabric-name $FabricTgt -n $PcTgt --query id -o tsv
az site-recovery protection-container mapping create -g $TgtRg --vault-name $VaultName `
  --fabric-name $FabricSrc --protection-container $PcSrc -n $MappingName `
  --policy-id $PolicyId --target-container $TgtPcId `
  --provider-input '{a2a:{agent-auto-update-status:Disabled}}' | Out-Null

# ------------------------------------------------------------------------------
# 11. ENABLE REPLICATION (create the protected item)
#     The A2A provider-details carry: the source VM, each managed disk mapped to
#     the source-region cache (primary staging) + target resource group, and the
#     target network/subnet/container. Cache access uses the vault MSI + the role
#     assignments from step 7 (no storage keys involved).
# ------------------------------------------------------------------------------
$VmId    = az vm show -g $SrcRg -n $VmName --query id -o tsv
$OsDisk  = az vm show -g $SrcRg -n $VmName --query storageProfile.osDisk.managedDisk.id -o tsv
$TgtRgId = az group show -n $TgtRg --query id -o tsv

$pd = "{a2a:{fabric-object-id:$VmId," +
      "vm-managed-disks:[{disk-id:$OsDisk,primary-staging-azure-storage-account-id:$SrcCacheId,recovery-resource-group-id:$TgtRgId}]," +
      "recovery-azure-network-id:$TgtVnetId,recovery-container-id:$TgtPcId," +
      "recovery-resource-group-id:$TgtRgId,recovery-subnet-name:$SubnetName}}"

az site-recovery protected-item create -g $TgtRg --vault-name $VaultName `
  --fabric-name $FabricSrc --protection-container $PcSrc -n $VmName `
  --policy-id $PolicyId --provider-details $pd --no-wait

Write-Host ''
Write-Host 'Enable replication submitted. Initial replication runs for ~15-30 min.'
Write-Host 'Track it with:'
Write-Host "  az site-recovery job list -g $TgtRg --vault-name $VaultName --query `"reverse(sort_by([].{name:properties.scenarioName,state:properties.state,target:properties.targetObjectName,start:properties.startTime},&start))[:5]`" -o table"
Write-Host 'The protected item flips to protectionState=Protected once the first recovery point lands:'
Write-Host "  az site-recovery protected-item show -g $TgtRg --vault-name $VaultName --fabric-name $FabricSrc --protection-container $PcSrc -n $VmName --query `"{state:properties.protectionState,health:properties.replicationHealth}`" -o json"

# ==============================================================================
# DR LIFECYCLE: FAILOVER -> COMMIT -> REPROTECT
# Run these ONLY after the protected item reaches protectionState=Protected.
# ==============================================================================

# ------------------------------------------------------------------------------
# 12. WAIT until the item is Protected (first recovery point available)
# ------------------------------------------------------------------------------
do {
  Start-Sleep -Seconds 60
  $ps = az site-recovery protected-item show -g $TgtRg --vault-name $VaultName --fabric-name $FabricSrc --protection-container $PcSrc -n $VmName --query "properties.protectionState" -o tsv
  Write-Host "protectionState = $ps"
} while ($ps -ne 'Protected')

# ------------------------------------------------------------------------------
# 13. UNPLANNED FAILOVER  (Central US -> West US)
#     '{a2a:{}}' = use the LATEST recovery point. --source-site-operations
#     NotRequired means don't try to shut the (still-running) source VM down.
# ------------------------------------------------------------------------------
az site-recovery protected-item unplanned-failover -g $TgtRg --vault-name $VaultName `
  --fabric-name $FabricSrc --protection-container $PcSrc -n $VmName `
  --failover-direction PrimaryToRecovery --source-site-operations NotRequired `
  --provider-details "{a2a:{}}"
# After this the item sits in UnplannedFailoverCommitPendingStatesBegin and the
# replica VM is running in the target region.

# ------------------------------------------------------------------------------
# 14. COMMIT the failover (finalizes it; clears the commit-pending state)
# ------------------------------------------------------------------------------
az site-recovery protected-item failover-commit -g $TgtRg --vault-name $VaultName `
  --fabric-name $FabricSrc --protection-container $PcSrc -n $VmName
# Item state -> UnplannedFailoverCommitted. Replication is now stopped.

# ------------------------------------------------------------------------------
# 15. REPROTECT  (reverse replication: West US -> Central US)
#
#     15a. First create the REVERSE container mapping (target PC -> source PC).
# ------------------------------------------------------------------------------
$SrcPcId = az site-recovery protection-container show -g $TgtRg --vault-name $VaultName --fabric-name $FabricSrc -n $PcSrc --query id -o tsv
az site-recovery protection-container mapping create -g $TgtRg --vault-name $VaultName `
  --fabric-name $FabricTgt --protection-container $PcTgt -n "$Prefix-map-wus-to-cus" `
  --policy-id $PolicyId --target-container $SrcPcId `
  --provider-input '{a2a:{agent-auto-update-status:Disabled}}' | Out-Null

# 15b. Do the reprotect itself with AZURE POWERSHELL (Az.RecoveryServices).
#
#   IMPORTANT: `az site-recovery protected-item reprotect` (and the raw REST
#   reProtect action) only understand the UNMANAGED disk model (vmDisks/diskUri).
#   For a MANAGED-disk VM the reprotect job fails at "Reprotecting virtual
#   machine" with "Managed disk details not provided", and passing vmManagedDisks
#   over REST returns 400 VMDisksMissing. The working path is Az PowerShell
#   Update-AzRecoveryServicesAsrProtectionDirection with a per-disk
#   New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk.
#
#   NOTE on the ASR vault context: Set-AzRecoveryServicesAsrVaultContext can throw
#   "Object reference not set to an instance of an object." The reliable
#   workaround (used below) is to download + import the vault settings file.
#   The ASR context is per-process, so keep the whole block in ONE session.
#
#   Requires: Connect-AzAccount to the subscription's tenant beforehand.
$ErrorActionPreference = 'Stop'
Set-AzContext -Subscription $SubscriptionId | Out-Null

$vault = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $TgtRg
$asrTmp = Join-Path $env:TEMP 'asr'; New-Item -ItemType Directory -Force -Path $asrTmp | Out-Null
$sf = Get-AzRecoveryServicesVaultSettingsFile -Vault $vault -SiteRecovery -Path $asrTmp
Import-AzRecoveryServicesAsrVaultSettingsFile -Path $sf.FilePath | Out-Null

# Protected item currently under the SOURCE fabric/container (pre-reprotect)
$fSrc = Get-AzRecoveryServicesAsrFabric -Name $FabricSrc
$pcS  = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fSrc -Name $PcSrc
$rpi  = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $pcS -Name $VmName

# Reverse mapping lives on the TARGET fabric/container (created in 15a)
$fTgt = Get-AzRecoveryServicesAsrFabric -Name $FabricTgt
$pcT  = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fTgt -Name $PcTgt
$revMap = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $pcT -Name "$Prefix-map-wus-to-cus"

# New source = the failed-over VM now running in the TARGET region
$fbVm = Get-AzVM -ResourceGroupName $TgtRg -Name $VmName
$fbOsDiskId = $fbVm.StorageProfile.OsDisk.ManagedDisk.Id
$tgtCacheId = (Get-AzResource -ResourceGroupName $TgtRg -ResourceType Microsoft.Storage/storageAccounts | Where-Object { $_.Name -like "$Prefix`cache*" } | Select-Object -First 1).ResourceId
$srcRgId = (Get-AzResourceGroup -Name $SrcRg).ResourceId

# Per-disk managed-disk reverse-replication config. LogStorageAccountId is the
# cache in the CURRENT source region (target region after failover).
$osConfig = New-AzRecoveryServicesAsrAzureToAzureDiskReplicationConfig -ManagedDisk `
  -LogStorageAccountId $tgtCacheId -DiskId $fbOsDiskId `
  -RecoveryResourceGroupId $srcRgId `
  -RecoveryReplicaDiskAccountType Premium_LRS -RecoveryTargetDiskAccountType Premium_LRS `
  -FailoverDiskName "$VmName-osdisk-fb" -TfoDiskName "$VmName-osdisk-tfo"

# NOTE: with -AzureToAzureDiskReplicationConfiguration do NOT also pass
# -LogStorageAccountId at the top level (different parameter set -> conflict).
$reprotectJob = Update-AzRecoveryServicesAsrProtectionDirection -AzureToAzure `
  -ProtectionContainerMapping $revMap `
  -ReplicationProtectedItem $rpi `
  -AzureToAzureDiskReplicationConfiguration $osConfig `
  -RecoveryResourceGroupId $srcRgId
Write-Host "Reprotect job: $($reprotectJob.DisplayName) / $($reprotectJob.State)"

Write-Host ''
Write-Host 'Reprotect submitted. Reverse initial replication (WUS -> CUS) now runs.'
Write-Host 'After reprotect the protected item moves to the TARGET container:'
Write-Host "  az site-recovery protected-item show -g $TgtRg --vault-name $VaultName --fabric-name $FabricTgt --protection-container $PcTgt -n $VmName --query `"{state:properties.protectionState,health:properties.replicationHealth}`" -o json"
Write-Host 'Once it is Protected again you can FAIL BACK: repeat steps 13-15 with the'
Write-Host 'directions reversed (failover-direction RecoveryToPrimary, etc.).'