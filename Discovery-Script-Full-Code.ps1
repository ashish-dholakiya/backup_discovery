# ============================================
# Azure Backup Discovery - Full Script (READ-ONLY)
# Prepared for: Client Discovery Session
# Run this entire script in Azure Cloud Shell (PowerShell mode)
# ============================================
# IMPORTANT: This script targets ONE specific subscription only —
# the one confirmed with the client. It does NOT scan every
# subscription your account may have access to.
#
# Before running, replace the placeholder Subscription ID below
# with the confirmed Subscription ID.
# ============================================

<#
.SYNOPSIS
    Azure Backup Posture Assessment - Comprehensive Discovery Script (READ-ONLY)
.DESCRIPTION
    Works across all subscription/vault scenarios automatically:
      1. Enumerates all subscriptions accessible to the logged-in account
      2. Inventories all resources (VMs, SQL, Storage, etc.) per subscription
      3. Inventories all Recovery Services Vaults and their backup policies
      4. Lists all protected items with backup type, policy, and protection status
      5. Cross-references resources vs protected items to flag GAPS
      6. Checks vault-level immutability / soft-delete settings
      7. Exports everything to local CSV files
    NO write, create, update, or delete operations are performed anywhere.
#>

$OutputFolder = "./AzureBackupAssessment_$(Get-Date -Format 'yyyyMMdd_HHmm')"
New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null

$AllResources      = @()
$AllVaults         = @()
$AllProtectedItems = @()
$AllPolicies       = @()
$GapReport         = @()

Write-Host "Starting Azure Backup Assessment (read-only)..." -ForegroundColor Cyan

# ---------- PINNED TO A SINGLE, AGREED SUBSCRIPTION ----------
# This script intentionally targets ONLY the subscription confirmed with the client.
# It will NOT loop across every subscription the logged-in account can see.
$TargetSubscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"   # <-- Replace with the confirmed Subscription ID

$subscriptions = Get-AzSubscription -SubscriptionId $TargetSubscriptionId
if (-not $subscriptions) {
    Write-Host "ERROR: Could not find subscription $TargetSubscriptionId, or you don't have access to it. Stopping." -ForegroundColor Red
    return
}
Write-Host "Targeting subscription: $($subscriptions.Name) [$($subscriptions.Id)]" -ForegroundColor Yellow

foreach ($sub in $subscriptions) {

    Write-Host "`nProcessing subscription: $($sub.Name) [$($sub.Id)]" -ForegroundColor Green
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $resources = Get-AzResource
    foreach ($r in $resources) {
        $AllResources += [PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceName     = $r.Name
            ResourceType     = $r.ResourceType
            ResourceGroup    = $r.ResourceGroupName
            Location         = $r.Location
            Tags             = ($r.Tags.Keys -join ';')
        }
    }
    Write-Host "  Resources found: $($resources.Count)"

    $vaults = Get-AzRecoveryServicesVault
    Write-Host "  Recovery Services Vaults found: $($vaults.Count)"

    foreach ($vault in $vaults) {

        # Redundancy comes from Get-AzRecoveryServicesBackupProperty (NOT VaultProperty) — different cmdlet
        $backupProps = Get-AzRecoveryServicesBackupProperty -Vault $vault -ErrorAction SilentlyContinue
        $redundancy = "Unknown - verify manually"
        if ($backupProps) {
            # Property name varies slightly across Az module versions — check common variants
            if ($backupProps.PSObject.Properties.Name -contains 'StorageType') { $redundancy = $backupProps.StorageType }
            elseif ($backupProps.PSObject.Properties.Name -contains 'StorageModelType') { $redundancy = $backupProps.StorageModelType }
            elseif ($backupProps.PSObject.Properties.Name -contains 'BackupStorageRedundancy') { $redundancy = $backupProps.BackupStorageRedundancy }
        }

        # Soft-delete comes from Get-AzRecoveryServicesVaultProperty
        $vaultProps = Get-AzRecoveryServicesVaultProperty -VaultId $vault.ID -ErrorAction SilentlyContinue
        $softDeleteState = $vaultProps.SoftDeleteFeatureState

        # Immutability comes from the vault object itself (Properties.ImmutabilitySettings.ImmutabilityState),
        # NOT from Get-AzRecoveryServicesVaultProperty
        $immutability = "Unknown - verify manually"
        try {
            $vaultFull = Get-AzRecoveryServicesVault -ResourceGroupName $vault.ResourceGroupName -Name $vault.Name -ErrorAction SilentlyContinue
            if ($vaultFull.Properties.ImmutabilitySettings.ImmutabilityState) {
                $immutability = $vaultFull.Properties.ImmutabilitySettings.ImmutabilityState
            }
        } catch { }

        $AllVaults += [PSCustomObject]@{
            SubscriptionName  = $sub.Name
            VaultName         = $vault.Name
            ResourceGroup     = $vault.ResourceGroupName
            Location          = $vault.Location
            StorageRedundancy = $redundancy
            SoftDeleteState   = $softDeleteState
            ImmutabilityState = $immutability
        }

        Set-AzRecoveryServicesVaultContext -Vault $vault

        $policies = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $vault.ID -ErrorAction SilentlyContinue
        foreach ($pol in $policies) {
            $AllPolicies += [PSCustomObject]@{
                SubscriptionName = $sub.Name
                VaultName        = $vault.Name
                PolicyName       = $pol.Name
                WorkloadType     = $pol.WorkloadType
                RetentionPolicy  = ($pol.RetentionPolicy | Out-String).Trim()
            }
        }

        # IMPORTANT: BackupManagementType and WorkloadType must be paired correctly —
        # they are NOT independent values. Using the wrong pair (e.g. BackupManagementType
        # "AzureIaasVM" for every workload type) causes this cmdlet to silently return
        # nothing for SQL, HANA, and File Share items, or throw a parameter-binding error.
        $workloadPairs = @(
            @{ WorkloadType = "AzureVM";        BackupManagementType = "AzureVM" }
            @{ WorkloadType = "MSSQL";           BackupManagementType = "AzureWorkload" }
            @{ WorkloadType = "SAPHanaDatabase"; BackupManagementType = "AzureWorkload" }
            @{ WorkloadType = "AzureFiles";      BackupManagementType = "AzureStorage" }
        )
        foreach ($pair in $workloadPairs) {
            $items = Get-AzRecoveryServicesBackupItem -BackupManagementType $pair.BackupManagementType -WorkloadType $pair.WorkloadType -VaultId $vault.ID -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                $AllProtectedItems += [PSCustomObject]@{
                    SubscriptionName = $sub.Name
                    VaultName        = $vault.Name
                    ItemName         = $item.FriendlyName
                    WorkloadType     = $pair.WorkloadType
                    ProtectionStatus = $item.ProtectionStatus
                    ProtectionState  = $item.ProtectionState
                    PolicyName       = $item.ProtectionPolicyName
                    LastBackupStatus = $item.LastBackupStatus
                    LastBackupTime   = $item.LastBackupTime
                }
            }
        }
    }
}

Write-Host "`nRunning gap analysis (unprotected VMs)..." -ForegroundColor Cyan
$allVMs = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }
$protectedNames = $AllProtectedItems | Select-Object -ExpandProperty ItemName -Unique

foreach ($vm in $allVMs) {
    $isProtected = $protectedNames -contains $vm.ResourceName
    if (-not $isProtected) {
        $GapReport += [PSCustomObject]@{
            SubscriptionName = $vm.SubscriptionName
            ResourceName     = $vm.ResourceName
            ResourceGroup    = $vm.ResourceGroup
            ResourceType     = $vm.ResourceType
            Location         = $vm.Location
            Issue            = "No backup protection found (verify Reader access on ALL subscriptions before treating as confirmed gap)"
        }
    }
}

$AllResources      | Export-Csv -Path "$OutputFolder/1_All_Resources.csv" -NoTypeInformation
$AllVaults         | Export-Csv -Path "$OutputFolder/2_Recovery_Vaults.csv" -NoTypeInformation
$AllPolicies       | Export-Csv -Path "$OutputFolder/3_Backup_Policies.csv" -NoTypeInformation
$AllProtectedItems | Export-Csv -Path "$OutputFolder/4_Protected_Items.csv" -NoTypeInformation
$GapReport         | Export-Csv -Path "$OutputFolder/5_Unprotected_VMs_GAP.csv" -NoTypeInformation

Write-Host "`n=======================================" -ForegroundColor Green
Write-Host "Discovery complete! (read-only — nothing in Azure was changed)" -ForegroundColor Green
Write-Host "Output folder: $OutputFolder" -ForegroundColor Green
Write-Host "  1_All_Resources.csv       -> $($AllResources.Count) resources"
Write-Host "  2_Recovery_Vaults.csv     -> $($AllVaults.Count) vaults"
Write-Host "  3_Backup_Policies.csv     -> $($AllPolicies.Count) policies"
Write-Host "  4_Protected_Items.csv     -> $($AllProtectedItems.Count) protected items"
Write-Host "  5_Unprotected_VMs_GAP.csv -> $($GapReport.Count) VMs with NO backup"
Write-Host "=======================================" -ForegroundColor Green

<#
.SYNOPSIS
    Comprehensive Resource-to-Backup Map (READ-ONLY)
.DESCRIPTION
    Joins everything from Step 2 into one row per resource, and adds
    Storage Account + Azure SQL Database (PaaS) backup settings that
    Recovery Services cmdlets don't cover. Flags cross-subscription
    backup relationships (landing-zone pattern) automatically.
    Must run in the SAME session as Step 2 (reuses its variables).
    NO write, create, update, or delete operations are performed.
#>

Write-Host "Building comprehensive resource-to-backup map (read-only)..." -ForegroundColor Cyan

$ResourceBackupMap = @()

foreach ($res in $AllResources) {

    $match = $AllProtectedItems | Where-Object { $_.ItemName -eq $res.ResourceName } | Select-Object -First 1

    if ($match) {
        $vaultInfo = $AllVaults | Where-Object { $_.VaultName -eq $match.VaultName } | Select-Object -First 1
        $vaultSubName = $vaultInfo.SubscriptionName
        $crossSub = if ($vaultSubName -and $vaultSubName -ne $res.SubscriptionName) { "YES - vault in different subscription (landing zone pattern)" } else { "No" }

        $ResourceBackupMap += [PSCustomObject]@{
            SubscriptionName   = $res.SubscriptionName
            ResourceName       = $res.ResourceName
            ResourceType       = $res.ResourceType
            ResourceGroup      = $res.ResourceGroup
            Location           = $res.Location
            BackupMechanism    = "Recovery Services Vault"
            VaultName          = $match.VaultName
            VaultSubscription  = $vaultSubName
            CrossSubscription  = $crossSub
            PolicyName         = $match.PolicyName
            StorageRedundancy  = $vaultInfo.StorageRedundancy
            SoftDeleteState    = $vaultInfo.SoftDeleteState
            ImmutabilityState  = $vaultInfo.ImmutabilityState
            ProtectionStatus   = $match.ProtectionStatus
            LastBackupStatus   = $match.LastBackupStatus
            LastBackupTime     = $match.LastBackupTime
        }
    }
    elseif ($res.ResourceType -eq "Microsoft.Compute/virtualMachines") {
        $ResourceBackupMap += [PSCustomObject]@{
            SubscriptionName   = $res.SubscriptionName
            ResourceName       = $res.ResourceName
            ResourceType       = $res.ResourceType
            ResourceGroup      = $res.ResourceGroup
            Location           = $res.Location
            BackupMechanism    = "NONE DETECTED"
            VaultName          = ""
            VaultSubscription  = ""
            CrossSubscription  = ""
            PolicyName         = ""
            StorageRedundancy  = ""
            SoftDeleteState    = ""
            ImmutabilityState  = ""
            ProtectionStatus   = "Unprotected (verify Reader access on all subscriptions incl. backup landing zone before confirming)"
            LastBackupStatus   = ""
            LastBackupTime     = ""
        }
    }
}

# Storage Account backup-relevant settings
Write-Host "Checking Storage Account backup settings..." -ForegroundColor Cyan
$storageAccounts = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Storage/storageAccounts" }

foreach ($sa in $storageAccounts) {
    try {
        $blobProps = Get-AzStorageBlobServiceProperty -ResourceGroupName $sa.ResourceGroup -StorageAccountName $sa.ResourceName -ErrorAction SilentlyContinue
        $ResourceBackupMap += [PSCustomObject]@{
            SubscriptionName   = $sa.SubscriptionName
            ResourceName       = $sa.ResourceName
            ResourceType       = $sa.ResourceType
            ResourceGroup      = $sa.ResourceGroup
            Location           = $sa.Location
            BackupMechanism    = "Storage Soft-Delete / Versioning"
            VaultName          = "N/A (PaaS-native)"
            VaultSubscription  = ""
            CrossSubscription  = ""
            PolicyName         = "N/A"
            StorageRedundancy  = ""
            SoftDeleteState    = if ($blobProps.DeleteRetentionPolicy.Enabled) { "Enabled ($($blobProps.DeleteRetentionPolicy.Days) days)" } else { "Disabled" }
            ImmutabilityState  = if ($blobProps.IsVersioningEnabled) { "Versioning Enabled" } else { "Versioning Disabled" }
            ProtectionStatus   = if ($blobProps.DeleteRetentionPolicy.Enabled) { "Protected" } else { "Gap" }
            LastBackupStatus   = ""
            LastBackupTime     = ""
        }
    } catch {
        Write-Host "  Could not read blob service properties for $($sa.ResourceName) — check Reader access" -ForegroundColor Yellow
    }
}

# Azure SQL Database (PaaS) backup settings
Write-Host "Checking Azure SQL Database backup settings..." -ForegroundColor Cyan
$sqlServers = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Sql/servers" }

foreach ($srv in $sqlServers) {
    $dbs = Get-AzSqlDatabase -ResourceGroupName $srv.ResourceGroup -ServerName $srv.ResourceName -ErrorAction SilentlyContinue | Where-Object { $_.DatabaseName -ne "master" }
    foreach ($db in $dbs) {
        $strPolicy = Get-AzSqlDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $srv.ResourceGroup -ServerName $srv.ResourceName -DatabaseName $db.DatabaseName -ErrorAction SilentlyContinue
        $ltrPolicy = Get-AzSqlDatabaseBackupLongTermRetentionPolicy -ResourceGroupName $srv.ResourceGroup -ServerName $srv.ResourceName -DatabaseName $db.DatabaseName -ErrorAction SilentlyContinue

        $ResourceBackupMap += [PSCustomObject]@{
            SubscriptionName   = $srv.SubscriptionName
            ResourceName       = "$($srv.ResourceName)/$($db.DatabaseName)"
            ResourceType       = "Microsoft.Sql/servers/databases"
            ResourceGroup      = $srv.ResourceGroup
            Location           = $srv.Location
            BackupMechanism    = "Azure SQL Automated Backup"
            VaultName          = "N/A (PaaS-native)"
            VaultSubscription  = ""
            CrossSubscription  = ""
            PolicyName         = "PITR + LTR"
            StorageRedundancy  = ""
            SoftDeleteState    = "PITR retention: $($strPolicy.RetentionDays) days"
            ImmutabilityState  = "LTR weekly: $($ltrPolicy.WeeklyRetention); monthly: $($ltrPolicy.MonthlyRetention); yearly: $($ltrPolicy.YearlyRetention)"
            ProtectionStatus   = if ($strPolicy) { "Protected (automated)" } else { "Check manually" }
            LastBackupStatus   = ""
            LastBackupTime     = ""
        }
    }
}

# AKS Clusters — flagged separately (Recovery Services Vault does NOT natively back these up;
# requires Azure Backup for AKS extension or Velero. Listed here for visibility, NOT treated
# as a VM-style gap, since the backup mechanism itself is different.)
Write-Host "Checking AKS clusters (separate backup mechanism)..." -ForegroundColor Cyan
$aksClusters = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.ContainerService/managedClusters" }

foreach ($aks in $aksClusters) {
    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $aks.SubscriptionName
        ResourceName       = $aks.ResourceName
        ResourceType       = $aks.ResourceType
        ResourceGroup      = $aks.ResourceGroup
        Location           = $aks.Location
        BackupMechanism    = "AKS - requires separate verification (Azure Backup for AKS extension or Velero, not Recovery Services Vault)"
        VaultName          = "N/A"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = ""
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "MANUAL CHECK REQUIRED - not covered by this script's automated detection"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

# VM Scale Sets — different backup mechanism than standalone VMs, flagged for manual verification
Write-Host "Checking VM Scale Sets (separate backup mechanism)..." -ForegroundColor Cyan
$vmssList = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachineScaleSets" }

foreach ($vmss in $vmssList) {
    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $vmss.SubscriptionName
        ResourceName       = $vmss.ResourceName
        ResourceType       = $vmss.ResourceType
        ResourceGroup      = $vmss.ResourceGroup
        Location           = $vmss.Location
        BackupMechanism    = "VMSS - requires separate verification (per-instance backup or app-level state strategy, not standard VM backup)"
        VaultName          = "N/A"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = ""
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "MANUAL CHECK REQUIRED - not covered by this script's automated detection"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

# Cosmos DB — has its own native backup mechanism (periodic or continuous), inventory only here
Write-Host "Checking Cosmos DB accounts (native backup mechanism)..." -ForegroundColor Cyan
$cosmosAccounts = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.DocumentDB/databaseAccounts" }

foreach ($cosmos in $cosmosAccounts) {
    $backupType = "Unknown - verify manually in Portal (Data Explorer/Backup & Restore blade)"
    try {
        $cosmosDetail = Get-AzCosmosDBAccount -ResourceGroupName $cosmos.ResourceGroup -Name $cosmos.ResourceName -ErrorAction SilentlyContinue
        if ($cosmosDetail.BackupPolicy) {
            # Property name has varied across Az.CosmosDB module versions (Type vs BackupType) — check both
            if ($cosmosDetail.BackupPolicy.PSObject.Properties.Name -contains 'Type') { $backupType = $cosmosDetail.BackupPolicy.Type }
            elseif ($cosmosDetail.BackupPolicy.PSObject.Properties.Name -contains 'BackupType') { $backupType = $cosmosDetail.BackupPolicy.BackupType }
        }
    } catch {
        Write-Host "  Could not read Cosmos DB backup policy for $($cosmos.ResourceName) — Az.CosmosDB module may not be loaded, or check access" -ForegroundColor Yellow
    }

    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $cosmos.SubscriptionName
        ResourceName       = $cosmos.ResourceName
        ResourceType       = $cosmos.ResourceType
        ResourceGroup      = $cosmos.ResourceGroup
        Location           = $cosmos.Location
        BackupMechanism    = "Cosmos DB Native Backup (Periodic or Continuous)"
        VaultName          = "N/A (PaaS-native)"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = $backupType
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "MANUAL CHECK REQUIRED - confirm backup type and retention in Portal"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

# Synapse Workspaces / Dedicated SQL Pools — separate backup model from standard Azure SQL DB
Write-Host "Checking Synapse workspaces and Dedicated SQL Pools..." -ForegroundColor Cyan
$synapseWorkspaces = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Synapse/workspaces" }

foreach ($syn in $synapseWorkspaces) {
    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $syn.SubscriptionName
        ResourceName       = $syn.ResourceName
        ResourceType       = $syn.ResourceType
        ResourceGroup      = $syn.ResourceGroup
        Location           = $syn.Location
        BackupMechanism    = "Synapse Native (automated snapshots for Dedicated SQL Pools, 7-day default retention)"
        VaultName          = "N/A (PaaS-native)"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = ""
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "MANUAL CHECK REQUIRED - verify restore point retention in Synapse Studio"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

# Azure Arc-enabled machines — investigate identity before assuming in/out of scope
# (May correspond to the Veritas/Data Domain appliance discussed with the client)
Write-Host "Checking Azure Arc-enabled machines..." -ForegroundColor Cyan
$arcMachines = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.HybridCompute/machines" }

foreach ($arc in $arcMachines) {
    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $arc.SubscriptionName
        ResourceName       = $arc.ResourceName
        ResourceType       = $arc.ResourceType
        ResourceGroup      = $arc.ResourceGroup
        Location           = $arc.Location
        BackupMechanism    = "Azure Arc-enabled machine - identity and backup approach must be confirmed manually with client"
        VaultName          = "N/A"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = ""
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "MANUAL CHECK REQUIRED - confirm what this machine is (may be a third-party appliance)"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

# Restore Point Collections — evidence of ad hoc / manual VM backups outside formal vault policy
Write-Host "Checking Restore Point Collections (ad hoc backup evidence)..." -ForegroundColor Cyan
$restorePointCollections = $AllResources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/restorePointCollections" }

foreach ($rpc in $restorePointCollections) {
    $ResourceBackupMap += [PSCustomObject]@{
        SubscriptionName   = $rpc.SubscriptionName
        ResourceName       = $rpc.ResourceName
        ResourceType       = $rpc.ResourceType
        ResourceGroup      = $rpc.ResourceGroup
        Location           = $rpc.Location
        BackupMechanism    = "Restore Point Collection - likely ad hoc/manual backup, outside formal Recovery Services policy"
        VaultName          = "N/A"
        VaultSubscription  = ""
        CrossSubscription  = ""
        PolicyName         = ""
        StorageRedundancy  = ""
        SoftDeleteState    = ""
        ImmutabilityState  = ""
        ProtectionStatus   = "INFORMATIONAL - flagged for governance review (ad hoc backup outside standard policy)"
        LastBackupStatus   = ""
        LastBackupTime     = ""
    }
}

$ResourceBackupMap | Export-Csv -Path "$OutputFolder/6_Resource_Backup_Map.csv" -NoTypeInformation

Write-Host "`nComprehensive map complete: $($ResourceBackupMap.Count) rows" -ForegroundColor Green
Write-Host "Saved to $OutputFolder/6_Resource_Backup_Map.csv" -ForegroundColor Green

# ---------- Package results for download ----------
zip -r assessment.zip AzureBackupAssessment_*
