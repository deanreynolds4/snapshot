#Requires -Version 5.1
<#
.SYNOPSIS
    Compares a replacement VM against the manifest of the VM it replaced, and reports every
    setting that did not carry over.

.DESCRIPTION
    The final step of the cutover, and the one that turns "the script said it worked" into
    evidence. It reads the capture manifest and the live replacement VM and diffs them
    property by property, classifying each row as:

        Match     - the replacement matches the source.
        Expected  - a deliberate difference, such as the VM size, which is the whole point.
        DIFFERS   - the values differ and it was not intended.
        MISSING   - the source had it and the replacement does not.
        Unknown   - could not be read, so it must be checked by hand.

    It also performs the one safety check that matters most in a side-by-side cutover:
    whether the source and the replacement VM are both running.

    This script only reads. It changes nothing.

.PARAMETER ManifestPath
    Manifest written by save-vm-snapshot-manifest.ps1 for the source VM.

.PARAMETER TargetVmName
    The replacement VM to inspect.

.PARAMETER TargetResourceGroupName
    Resource group of the replacement VM. Defaults to the source resource group.

.PARAMETER TargetSubscriptionId
    Subscription of the replacement VM. Defaults to the source subscription.

.PARAMETER OutputPath
    Optional path for a JSON report. A CSV is written alongside it with the same base name.

.PARAMETER IncludeMatches
    Show matching rows too. By default only the rows that need attention are printed.

.EXAMPLE
    .\compare-vm-fidelity.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-20260901-101500.json -TargetVmName SQLPROD01-ds

    Prints every difference between the source VM as captured and the replacement as built.

.EXAMPLE
    .\compare-vm-fidelity.ps1 -ManifestPath .\m.json -TargetVmName SQLPROD01-ds -IncludeMatches -OutputPath .\fidelity.json

    Full report including matches, saved as JSON and CSV for a change record.

.NOTES
    Companion scripts: save-vm-snapshot-manifest.ps1, release-vm-network-address.ps1,
    new-vm-from-snapshot-manifest.ps1. See README.md.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVmName,

    [string]$TargetResourceGroupName,
    [string]$TargetSubscriptionId,
    [string]$OutputPath,
    [switch]$IncludeMatches
)

# Strict mode level 1, not 2. Level 1 catches references to uninitialised variables - the
# class of bug that made the original restore script call .Add() on a $null list. Level 2
# additionally throws on every missing or null property access, which is unusable against
# Az SDK objects, where navigating something like $vm.SecurityProfile.UefiSettings on a VM
# with no security profile is normal and must yield $null rather than end the migration.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'vm-rebuild-common.ps1')

$script:Rows = [System.Collections.Generic.List[object]]::new()

function Add-ComparisonRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Setting,

        [AllowNull()]
        [object]$Source,

        [AllowNull()]
        [object]$Target,

        [ValidateSet('Match', 'Expected', 'DIFFERS', 'MISSING', 'Unknown')]
        [string]$Status,

        [string]$Note
    )

    $sourceText = if ($null -eq $Source) { '' } else { [string]$Source }
    $targetText = if ($null -eq $Target) { '' } else { [string]$Target }

    if (-not $Status) {
        if ($sourceText -eq $targetText) {
            $Status = 'Match'
        }
        elseif ([string]::IsNullOrWhiteSpace($targetText)) {
            $Status = 'MISSING'
        }
        else {
            $Status = 'DIFFERS'
        }
    }

    $script:Rows.Add([pscustomobject]@{
        Category = $Category
        Setting  = $Setting
        Source   = $sourceText
        Target   = $targetText
        Status   = $Status
        Note     = $Note
    })
}

function Compare-Value {
    <#
    .SYNOPSIS
        Adds a row, deriving the status by comparing the two values as strings.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$Setting,

        [AllowNull()]
        [object]$Source,

        [AllowNull()]
        [object]$Target,

        [string]$Note
    )

    $sourceText = if ($null -eq $Source) { '' } else { ([string]$Source).Trim() }
    $targetText = if ($null -eq $Target) { '' } else { ([string]$Target).Trim() }

    $status = 'Match'
    if ($sourceText -ne $targetText) {
        if ([string]::IsNullOrWhiteSpace($targetText)) { $status = 'MISSING' } else { $status = 'DIFFERS' }
    }

    Add-ComparisonRow -Category $Category -Setting $Setting -Source $sourceText -Target $targetText -Status $status -Note $Note
}


$originalContext = $null

try {
    Write-Step 'Loading'
    Assert-AzModule -Name @('Az.Accounts', 'Az.Compute', 'Az.Network')
    $originalContext = Save-AzContextState
    $null = Connect-AzIfNeeded

    $manifest = Read-JsonFile -Path $ManifestPath
    $sourceVm = $manifest.SourceVm

    if (-not $TargetSubscriptionId) { $TargetSubscriptionId = $sourceVm.SubscriptionId }
    if (-not $TargetResourceGroupName) { $TargetResourceGroupName = $sourceVm.ResourceGroupName }

    $null = Set-AzSubscriptionContext -SubscriptionId $TargetSubscriptionId
    $target = Get-AzVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName -ErrorAction Stop
    Write-Ok ("Comparing '{0}' (captured {1}) against '{2}'." -f $sourceVm.Name, $manifest.GeneratedAtUtc, $TargetVmName)

    # ------------------------------------------------------------------ Safety
    Write-Step 'Safety check: only one of the two VMs may be running'
    $targetPowerState = Get-VmPowerState -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName
    $sourcePowerState = 'NotFound'
    try {
        $null = Get-AzVM -ResourceGroupName $sourceVm.ResourceGroupName -Name $sourceVm.Name -ErrorAction Stop
        $sourcePowerState = Get-VmPowerState -ResourceGroupName $sourceVm.ResourceGroupName -Name $sourceVm.Name
    }
    catch {
        $sourcePowerState = 'NotFound'
    }

    Write-Detail ("Source '{0}': {1}" -f $sourceVm.Name, $sourcePowerState)
    Write-Detail ("Target '{0}': {1}" -f $TargetVmName, $targetPowerState)

    $bothRunning = ($sourcePowerState -eq 'PowerState/running') -and ($targetPowerState -eq 'PowerState/running')
    if ($bothRunning) {
        Add-ComparisonRow -Category 'Safety' -Setting 'Concurrent power state' -Source $sourcePowerState -Target $targetPowerState -Status 'DIFFERS' `
            -Note 'BOTH VMs ARE RUNNING. They share a hostname, an Active Directory computer account and a SQL Server instance identity. Shut one down now.'
        Write-Host ''
        Write-Host 'CRITICAL: both the source and the replacement VM are running at the same time.' -ForegroundColor Red
    }
    else {
        Add-ComparisonRow -Category 'Safety' -Setting 'Concurrent power state' -Source $sourcePowerState -Target $targetPowerState -Status 'Match' -Note 'Only one VM is running.'
    }

    # ------------------------------------------------------------------ Placement and identity
    Write-Step 'Comparing configuration'

    Add-ComparisonRow -Category 'Compute' -Setting 'VM size' -Source $sourceVm.VmSize -Target $target.HardwareProfile.VmSize -Status 'Expected' -Note 'The size change is the purpose of the migration.'

    $targetSku = @(Get-AzComputeResourceSku -Location $target.Location -ErrorAction SilentlyContinue |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $target.HardwareProfile.VmSize }) | Select-Object -First 1
    $tempDiskMb = 0
    if ($targetSku) {
        $capability = @($targetSku.Capabilities | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' }) | Select-Object -First 1
        if ($capability) { $tempDiskMb = [int]$capability.Value }
    }

    Add-ComparisonRow -Category 'Compute' -Setting 'Local temp disk' -Source 'none (reason for migration)' -Target ("{0} GB" -f [math]::Round($tempDiskMb / 1024, 0)) `
        -Status $(if ($tempDiskMb -gt 0) { 'Expected' } else { 'DIFFERS' }) `
        -Note $(if ($tempDiskMb -gt 0) { 'The replacement has a local temp disk.' } else { 'The replacement still has NO temp disk. The migration did not achieve its goal.' })

    Compare-Value -Category 'Compute' -Setting 'Location' -Source $sourceVm.Location -Target $target.Location
    Compare-Value -Category 'Compute' -Setting 'Zone' -Source ((ConvertTo-StringArray -InputObject $sourceVm.Zones) -join ',') -Target ((ConvertTo-StringArray -InputObject $target.Zones) -join ',')
    Compare-Value -Category 'Licensing' -Setting 'Windows license type (Azure Hybrid Benefit)' -Source $sourceVm.LicenseType -Target $target.LicenseType -Note 'A missing value here means you are paying full retail for Windows.'

    $sourcePlan = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('Plan')
    if ($sourcePlan) {
        Compare-Value -Category 'Licensing' -Setting 'Marketplace plan' -Source ("{0}/{1}/{2}" -f $sourcePlan.Publisher, $sourcePlan.Product, $sourcePlan.Name) `
            -Target $(if ($target.Plan) { "{0}/{1}/{2}" -f $target.Plan.Publisher, $target.Plan.Product, $target.Plan.Name } else { '' })
    }

    Compare-Value -Category 'Security' -Setting 'Security type' -Source $sourceVm.SecurityType -Target (Get-ObjectPropertyValue -InputObject $target.SecurityProfile -PropertyNames @('SecurityType')) `
        -Note 'A mismatch here can make re-protecting the VM in the same Recovery Services vault fail destructively.'
    Compare-Value -Category 'Security' -Setting 'Encryption at host' -Source ([bool]$sourceVm.EncryptionAtHost) -Target (Get-BooleanPropertyValue -InputObject $target.SecurityProfile -PropertyNames @('EncryptionAtHost'))

    $sourceUefi = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('UefiSettings')
    if ($sourceUefi) {
        Compare-Value -Category 'Security' -Setting 'Secure Boot' -Source ([bool]$sourceUefi.SecureBootEnabled) -Target (Get-BooleanPropertyValue -InputObject $target.SecurityProfile.UefiSettings -PropertyNames @('SecureBootEnabled'))
        Compare-Value -Category 'Security' -Setting 'vTPM' -Source ([bool]$sourceUefi.VTpmEnabled) -Target (Get-BooleanPropertyValue -InputObject $target.SecurityProfile.UefiSettings -PropertyNames @('VTpmEnabled'))
    }

    # ------------------------------------------------------------------ Tags
    $sourceTags = ConvertTo-PlainHashtable -InputObject $sourceVm.Tags
    if (-not $sourceTags) { $sourceTags = @{} }
    $targetTags = @{}
    if ($target.Tags) { foreach ($key in $target.Tags.Keys) { $targetTags[$key] = $target.Tags[$key] } }

    foreach ($key in ($sourceTags.Keys | Sort-Object)) {
        $targetValue = $null
        if ($targetTags.ContainsKey($key)) { $targetValue = $targetTags[$key] }
        Compare-Value -Category 'Tags' -Setting ("tag: {0}" -f $key) -Source $sourceTags[$key] -Target $targetValue
    }

    # ------------------------------------------------------------------ Identity
    $sourceIdentity = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('Identity')
    if ($sourceIdentity) {
        Compare-Value -Category 'Identity' -Setting 'Identity type' -Source $sourceIdentity.Type -Target (Get-ObjectPropertyValue -InputObject $target.Identity -PropertyNames @('Type'))

        $sourceUserAssigned = @(ConvertTo-StringArray -InputObject $sourceIdentity.UserAssignedIdentityIds)
        $targetUserAssigned = @()
        if ($target.Identity -and $target.Identity.UserAssignedIdentities) {
            foreach ($key in $target.Identity.UserAssignedIdentities.Keys) { $targetUserAssigned += [string]$key }
        }

        Compare-Value -Category 'Identity' -Setting 'User-assigned identities' -Source $sourceUserAssigned.Count -Target $targetUserAssigned.Count

        if (('' + $sourceIdentity.Type) -match 'SystemAssigned') {
            Add-ComparisonRow -Category 'Identity' -Setting 'System-assigned principal ID' -Source $sourceIdentity.SystemAssignedPrincipalId `
                -Target (Get-ObjectPropertyValue -InputObject $target.Identity -PropertyNames @('PrincipalId')) -Status 'Expected' `
                -Note 'A new principal ID is unavoidable. Every role assignment, Key Vault policy and database login granted to the old one must be re-granted.'
        }
    }

    # ------------------------------------------------------------------ Guest patching
    $sourceOsProfile = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('OsProfile')
    $sourcePatch = $null
    if ($sourceOsProfile -and $sourceOsProfile.WindowsConfiguration) { $sourcePatch = $sourceOsProfile.WindowsConfiguration.PatchSettings }

    if ($sourcePatch) {
        $targetHasOsProfile = ($null -ne $target.OSProfile)
        $targetPatch = $null
        if ($targetHasOsProfile -and $target.OSProfile.WindowsConfiguration) { $targetPatch = $target.OSProfile.WindowsConfiguration.PatchSettings }

        if (-not $targetHasOsProfile) {
            Add-ComparisonRow -Category 'Patching' -Setting 'osProfile present' -Source 'yes' -Target 'no' -Status 'MISSING' `
                -Note 'The replacement was built by attaching a specialized OS disk, so it has no osProfile. Every patch setting lives inside osProfile and cannot be added later. Azure Update Manager SCHEDULED patching is not available on this VM; on-demand assessment and patching still are. Rebuilding with -RestoreMode ImageFirstSwap is the only way to recover it.'
        }

        Compare-Value -Category 'Patching' -Setting 'Patch mode' -Source $sourcePatch.PatchMode -Target (Get-ObjectPropertyValue -InputObject $targetPatch -PropertyNames @('PatchMode'))
        Compare-Value -Category 'Patching' -Setting 'Assessment mode' -Source $sourcePatch.AssessmentMode -Target (Get-ObjectPropertyValue -InputObject $targetPatch -PropertyNames @('AssessmentMode')) `
            -Note 'Setting patch mode alone does not enable periodic assessment; assessment mode is separate.'
    }

    # ------------------------------------------------------------------ Disks
    $sourceDisks = @($manifest.Disks)
    $sourceOsDisk = @($sourceDisks | Where-Object { $_.DiskRole -eq 'OS' }) | Select-Object -First 1
    $targetOsDiskId = $target.StorageProfile.OsDisk.ManagedDisk.Id
    $targetOsDisk = $null
    try {
        $targetOsDisk = Get-AzDisk -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $targetOsDiskId) -DiskName (Get-ResourceNameFromResourceId -ResourceId $targetOsDiskId) -ErrorAction Stop
    }
    catch {
        Add-ComparisonRow -Category 'Disks' -Setting 'OS disk' -Source $sourceOsDisk.DiskName -Target '' -Status 'Unknown' -Note $_.Exception.Message
    }

    if ($targetOsDisk) {
        Compare-Value -Category 'Disks' -Setting 'OS disk SKU' -Source $sourceOsDisk.SkuName -Target $targetOsDisk.Sku.Name -Note 'A silent downgrade or upgrade here changes both performance and cost.'
        Compare-Value -Category 'Disks' -Setting 'OS disk size (GB)' -Source $sourceOsDisk.DiskSizeGB -Target $targetOsDisk.DiskSizeGB
        Compare-Value -Category 'Disks' -Setting 'OS disk caching' -Source $sourceOsDisk.Caching -Target ([string]$target.StorageProfile.OsDisk.Caching)
        Compare-Value -Category 'Disks' -Setting 'OS disk encryption set' -Source (Get-ObjectPropertyValue -InputObject $sourceOsDisk.Encryption -PropertyNames @('DiskEncryptionSetId')) `
            -Target (Get-ObjectPropertyValue -InputObject $targetOsDisk.Encryption -PropertyNames @('DiskEncryptionSetId')) `
            -Note 'A missing customer-managed key means the disk fell back to platform-managed encryption.'
    }

    $sourceDataDisks = @($sourceDisks | Where-Object { $_.DiskRole -eq 'Data' } | Sort-Object { [int]$_.Lun })
    $targetDataDisks = @($target.StorageProfile.DataDisks | Sort-Object { [int]$_.Lun })

    Compare-Value -Category 'Disks' -Setting 'Data disk count' -Source $sourceDataDisks.Count -Target $targetDataDisks.Count

    foreach ($sourceDataDisk in $sourceDataDisks) {
        $lun = [int]$sourceDataDisk.Lun
        $targetDataDisk = @($targetDataDisks | Where-Object { [int]$_.Lun -eq $lun }) | Select-Object -First 1
        if (-not $targetDataDisk) {
            Add-ComparisonRow -Category 'Disks' -Setting ("LUN {0}" -f $lun) -Source $sourceDataDisk.DiskName -Target '' -Status 'MISSING' `
                -Note 'The guest binds drive letters and SQL Server file paths to LUNs. A missing LUN means a missing volume.'
            continue
        }

        $targetDiskResource = $null
        try {
            $id = $targetDataDisk.ManagedDisk.Id
            $targetDiskResource = Get-AzDisk -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $id) -DiskName (Get-ResourceNameFromResourceId -ResourceId $id) -ErrorAction Stop
        }
        catch {
            Add-ComparisonRow -Category 'Disks' -Setting ("LUN {0} resource" -f $lun) -Source $sourceDataDisk.DiskName -Target '' -Status 'Unknown' -Note $_.Exception.Message
        }

        Compare-Value -Category 'Disks' -Setting ("LUN {0} caching" -f $lun) -Source $sourceDataDisk.Caching -Target ([string]$targetDataDisk.Caching)
        Compare-Value -Category 'Disks' -Setting ("LUN {0} write accelerator" -f $lun) -Source ([bool]$sourceDataDisk.WriteAcceleratorEnabled) -Target ([bool]$targetDataDisk.WriteAcceleratorEnabled)

        if ($targetDiskResource) {
            Compare-Value -Category 'Disks' -Setting ("LUN {0} SKU" -f $lun) -Source $sourceDataDisk.SkuName -Target $targetDiskResource.Sku.Name
            Compare-Value -Category 'Disks' -Setting ("LUN {0} size (GB)" -f $lun) -Source $sourceDataDisk.DiskSizeGB -Target $targetDiskResource.DiskSizeGB
            Compare-Value -Category 'Disks' -Setting ("LUN {0} performance tier" -f $lun) -Source $sourceDataDisk.PerformanceTier -Target (Get-ObjectPropertyValue -InputObject $targetDiskResource -PropertyNames @('Tier'))
            Compare-Value -Category 'Disks' -Setting ("LUN {0} encryption set" -f $lun) -Source (Get-ObjectPropertyValue -InputObject $sourceDataDisk.Encryption -PropertyNames @('DiskEncryptionSetId')) `
                -Target (Get-ObjectPropertyValue -InputObject $targetDiskResource.Encryption -PropertyNames @('DiskEncryptionSetId'))
        }
    }

    # ------------------------------------------------------------------ Network
    $sourceNics = @($manifest.Network.NetworkInterfaces)
    $sourcePrimaryNic = @($sourceNics | Where-Object { $_.IsPrimary }) | Select-Object -First 1
    if (-not $sourcePrimaryNic) { $sourcePrimaryNic = @($sourceNics) | Select-Object -First 1 }
    $sourcePrimaryIp = $null
    if ($sourcePrimaryNic) {
        $sourcePrimaryIp = @($sourcePrimaryNic.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
        if (-not $sourcePrimaryIp) { $sourcePrimaryIp = @($sourcePrimaryNic.IpConfigurations) | Select-Object -First 1 }
    }

    Compare-Value -Category 'Network' -Setting 'NIC count' -Source $sourceNics.Count -Target @($target.NetworkProfile.NetworkInterfaces).Count `
        -Note 'Only the primary NIC is handled by the toolkit; extras must be attached by hand.'

    $targetNicReference = @($target.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary }) | Select-Object -First 1
    if (-not $targetNicReference) { $targetNicReference = @($target.NetworkProfile.NetworkInterfaces) | Select-Object -First 1 }

    if ($targetNicReference) {
        $targetNic = Get-AzNetworkInterface -ResourceId $targetNicReference.Id -ErrorAction Stop
        $targetIp = @($targetNic.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
        if (-not $targetIp) { $targetIp = @($targetNic.IpConfigurations) | Select-Object -First 1 }

        Compare-Value -Category 'Network' -Setting 'Private IP address' -Source (Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('PrivateIpAddress')) -Target $targetIp.PrivateIpAddress `
            -Note 'A change here means DNS, firewall rules and application connection strings pointing at the old address are now wrong.'
        Compare-Value -Category 'Network' -Setting 'Subnet' -Source (Get-ResourceNameFromResourceId -ResourceId (Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('SubnetId'))) -Target (Get-ResourceNameFromResourceId -ResourceId $targetIp.Subnet.Id)
        Compare-Value -Category 'Network' -Setting 'Network security group' -Source (Get-ResourceNameFromResourceId -ResourceId (Get-ObjectPropertyValue -InputObject $sourcePrimaryNic -PropertyNames @('NetworkSecurityGroupId'))) `
            -Target (Get-ResourceNameFromResourceId -ResourceId (Get-ObjectPropertyValue -InputObject $targetNic.NetworkSecurityGroup -PropertyNames @('Id')))
        Compare-Value -Category 'Network' -Setting 'Accelerated networking' -Source ([bool]$sourcePrimaryNic.EnableAcceleratedNetworking) -Target ([bool]$targetNic.EnableAcceleratedNetworking)
        Compare-Value -Category 'Network' -Setting 'IP forwarding' -Source ([bool]$sourcePrimaryNic.EnableIPForwarding) -Target ([bool]$targetNic.EnableIPForwarding)
        Compare-Value -Category 'Network' -Setting 'Custom DNS servers' -Source ((ConvertTo-StringArray -InputObject $sourcePrimaryNic.DnsServers) -join ',') `
            -Target ((ConvertTo-StringArray -InputObject $targetNic.DnsSettings.DnsServers) -join ',')

        $sourceAsgCount = @(Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('ApplicationSecurityGroupIds') -Default @()).Count
        $targetAsgCount = @($targetIp.ApplicationSecurityGroups).Count
        Compare-Value -Category 'Network' -Setting 'Application security groups' -Source $sourceAsgCount -Target $targetAsgCount `
            -Note 'ASG membership drives NSG rules. Losing it silently opens or closes traffic.'

        $sourceLbCount = @(Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('LoadBalancerBackendAddressPoolIds') -Default @()).Count
        $targetLbCount = @($targetIp.LoadBalancerBackendAddressPools).Count
        Compare-Value -Category 'Network' -Setting 'Load balancer backend pools' -Source $sourceLbCount -Target $targetLbCount `
            -Note 'If this dropped to zero, the VM is silently out of the load balancer and receiving no traffic.'
    }

    # ------------------------------------------------------------------ Extensions
    $extensionSection = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('Extensions')
    if ($extensionSection -and $extensionSection.Status -eq 'Captured') {
        $targetExtensions = @()
        try {
            $targetExtensions = @(Get-AzVMExtension -ResourceGroupName $TargetResourceGroupName -VMName $TargetVmName -ErrorAction Stop)
        }
        catch {
            Add-ComparisonRow -Category 'Extensions' -Setting 'Extension list' -Source '' -Target '' -Status 'Unknown' -Note $_.Exception.Message
        }

        foreach ($sourceExtension in @($extensionSection.Data)) {
            $match = @($targetExtensions | Where-Object { $_.Name -eq $sourceExtension.Name }) | Select-Object -First 1
            if ($match) {
                Add-ComparisonRow -Category 'Extensions' -Setting $sourceExtension.Name -Source 'installed' -Target ("installed ({0})" -f $match.ProvisioningState) `
                    -Status $(if ('' + $match.ProvisioningState -eq 'Succeeded') { 'Match' } else { 'DIFFERS' }) `
                    -Note $(if ('' + $match.ProvisioningState -eq 'Succeeded') { '' } else { 'A failed extension blocks every subsequent extension install on this VM.' })
            }
            else {
                Add-ComparisonRow -Category 'Extensions' -Setting $sourceExtension.Name -Source 'installed' -Target 'absent' -Status 'MISSING' `
                    -Note 'The extension binaries may still be present on the restored OS disk while Azure shows nothing, which is the classic silently-broken-agent state.'
            }
        }
    }

    # ------------------------------------------------------------------ Boot diagnostics
    $sourceBootDiagnostics = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('BootDiagnostics')
    if ($sourceBootDiagnostics) {
        Compare-Value -Category 'Diagnostics' -Setting 'Boot diagnostics enabled' -Source ([bool]$sourceBootDiagnostics.Enabled) `
            -Target (Get-BooleanPropertyValue -InputObject $target.DiagnosticsProfile.BootDiagnostics -PropertyNames @('Enabled')) `
            -Note 'Boot diagnostics need a stop/start after an OS disk swap before they report again.'
    }

    # ------------------------------------------------------------------ Backup
    $backupSection = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('BackupProtection')
    if ($backupSection -and $backupSection.Status -eq 'Captured' -and $backupSection.Data.IsProtected) {
        $targetProtected = $false
        $targetPolicy = ''
        if (Get-Module -ListAvailable -Name Az.RecoveryServices) {
            try {
                Import-Module Az.RecoveryServices -ErrorAction Stop
                $status = Get-AzRecoveryServicesBackupStatus -Name $TargetVmName -ResourceGroupName $TargetResourceGroupName -Type AzureVM -ErrorAction Stop
                $targetProtected = Get-BooleanPropertyValue -InputObject $status -PropertyNames @('BackedUp')
                $targetVaultId = Get-ObjectPropertyValue -InputObject $status -PropertyNames @('VaultId')
                if ($targetVaultId) {
                    $container = @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $TargetVmName -VaultId $targetVaultId -ErrorAction Stop) | Select-Object -First 1
                    if ($container) {
                        $item = @(Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $targetVaultId -ErrorAction Stop) | Select-Object -First 1
                        $targetPolicy = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('PolicyName', 'ProtectionPolicyName')
                    }
                }
            }
            catch {
                Add-ComparisonRow -Category 'Backup' -Setting 'Protection status' -Source 'protected' -Target '' -Status 'Unknown' -Note $_.Exception.Message
            }
        }

        Compare-Value -Category 'Backup' -Setting 'Protected' -Source $true -Target $targetProtected
        Compare-Value -Category 'Backup' -Setting 'Policy' -Source $backupSection.Data.PolicyName -Target $targetPolicy

        if ($TargetVmName -ne $sourceVm.Name -or $TargetResourceGroupName -ne $sourceVm.ResourceGroupName) {
            Add-ComparisonRow -Category 'Backup' -Setting 'Recovery point history' -Source ("under item '{0}'" -f $backupSection.Data.BackupItemName) -Target 'new item, no history' -Status 'Expected' `
                -Note 'Azure Backup identifies a VM by subscription + resource group + name, so a renamed replacement starts a fresh backup chain. The old recovery points remain restorable under the source item and remain billable until they age out.'
        }
    }

    # ------------------------------------------------------------------ SQL VM
    $sqlSection = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('SqlVirtualMachine')
    if ($sqlSection -and $sqlSection.Status -eq 'Captured' -and $sqlSection.Data.IsRegistered) {
        $targetSql = $null
        if (Get-Module -ListAvailable -Name Az.SqlVirtualMachine) {
            try {
                Import-Module Az.SqlVirtualMachine -ErrorAction Stop
                $targetSql = Get-AzSqlVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName -ErrorAction Stop
            }
            catch {
                $targetSql = $null
            }
        }

        Compare-Value -Category 'SQL Server' -Setting 'Registered with SQL IaaS extension' -Source $true -Target ($null -ne $targetSql)
        Compare-Value -Category 'SQL Server' -Setting 'SQL license type' -Source $sqlSection.Data.LicenseType `
            -Target (Get-ObjectPropertyValue -InputObject $targetSql -PropertyNames @('SqlServerLicenseType', 'LicenseType')) `
            -Note 'If this reverted to PAYG you have lost Azure Hybrid Benefit for SQL Server and are being billed for licences you already own.'
        Compare-Value -Category 'SQL Server' -Setting 'Management mode' -Source $sqlSection.Data.SqlManagementType `
            -Target (Get-ObjectPropertyValue -InputObject $targetSql -PropertyNames @('SqlManagement', 'SqlManagementType'))

        foreach ($settingName in @('AutoPatchingSettings', 'AutoBackupSettings', 'ServerConfigurationsManagementSettings', 'StorageConfigurationSettings')) {
            if (Get-ObjectPropertyValue -InputObject $sqlSection.Data -PropertyNames @($settingName)) {
                Add-ComparisonRow -Category 'SQL Server' -Setting $settingName -Source 'configured' `
                    -Target $(if (Get-ObjectPropertyValue -InputObject $targetSql -PropertyNames @($settingName)) { 'configured' } else { 'not configured' }) `
                    -Status $(if (Get-ObjectPropertyValue -InputObject $targetSql -PropertyNames @($settingName)) { 'Match' } else { 'MISSING' }) `
                    -Note 'Not replayed automatically. Compare against the manifest and reapply.'
            }
        }
    }

    # ------------------------------------------------------------------ Maintenance
    $maintenanceSection = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('MaintenanceAssignments')
    if ($maintenanceSection -and $maintenanceSection.Status -eq 'Captured') {
        $targetAssignments = @()
        if (Get-Module -ListAvailable -Name Az.Maintenance) {
            try {
                Import-Module Az.Maintenance -ErrorAction Stop
                $targetAssignments = @(Get-AzConfigurationAssignment -ProviderName 'Microsoft.Compute' -ResourceGroupName $TargetResourceGroupName -ResourceType 'virtualMachines' -ResourceName $TargetVmName -ErrorAction Stop)
            }
            catch {
                $targetAssignments = @()
            }
        }

        Compare-Value -Category 'Update Manager' -Setting 'Maintenance assignments' -Source @($maintenanceSection.Data).Count -Target $targetAssignments.Count `
            -Note 'An assignment existing is not proof that patching works: it can be attached to a VM that lacks the patch prerequisite and then fail at run time.'
    }

    # ------------------------------------------------------------------ Report
    Write-Step 'Result'

    $rowsToShow = $script:Rows
    if (-not $IncludeMatches) {
        $rowsToShow = @($script:Rows | Where-Object { $_.Status -ne 'Match' })
    }

    if ($rowsToShow.Count -gt 0) {
        $rowsToShow | Format-Table -AutoSize -Wrap -Property Category, Setting, Source, Target, Status | Out-String -Width 250 | Write-Host
    }

    $differs = @($script:Rows | Where-Object { $_.Status -eq 'DIFFERS' })
    $missing = @($script:Rows | Where-Object { $_.Status -eq 'MISSING' })
    $unknown = @($script:Rows | Where-Object { $_.Status -eq 'Unknown' })
    $matched = @($script:Rows | Where-Object { $_.Status -eq 'Match' })
    $expected = @($script:Rows | Where-Object { $_.Status -eq 'Expected' })

    Write-Host ''
    Write-Host ("Match {0}   Expected {1}   DIFFERS {2}   MISSING {3}   Unknown {4}" -f $matched.Count, $expected.Count, $differs.Count, $missing.Count, $unknown.Count) -ForegroundColor Cyan

    foreach ($row in ($differs + $missing)) {
        if ($row.Note) {
            Write-Host ("  [{0}] {1} / {2}: {3}" -f $row.Status, $row.Category, $row.Setting, $row.Note) -ForegroundColor Yellow
        }
    }

    if ($OutputPath) {
        $null = Write-JsonFile -InputObject @($script:Rows) -Path $OutputPath -Depth 8
        $csvPath = [System.IO.Path]::ChangeExtension($OutputPath, '.csv')
        $script:Rows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
        Write-Ok ("Report: {0} and {1}" -f $OutputPath, $csvPath)
    }

    [pscustomobject]@{
        SourceVmName     = $sourceVm.Name
        TargetVmName     = $TargetVmName
        SourcePowerState = $sourcePowerState
        TargetPowerState = $targetPowerState
        BothRunning      = $bothRunning
        MatchCount       = $matched.Count
        ExpectedCount    = $expected.Count
        DiffersCount     = $differs.Count
        MissingCount     = $missing.Count
        UnknownCount     = $unknown.Count
        Rows             = @($script:Rows)
    }
}
finally {
    Restore-AzContextState -Context $originalContext
}
