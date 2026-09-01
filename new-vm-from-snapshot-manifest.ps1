<#
.SYNOPSIS
    Creates a replacement Azure VM from a snapshot manifest produced by script.ps1 by restoring managed disks and attaching them to a new VM definition.

.DESCRIPTION
    This script is the restore and rebuild half of the snapshot workflow.

    Workflow:
    - Reads the manifest JSON produced by script.ps1.
    - Uses the source subscription, resource group, location, and zone by default unless override parameters are supplied.
    - Creates a managed OS disk and any managed data disks from the recorded snapshot resources, preserving stored disk SKU information and
      reapplying data disk LUN and caching metadata where available.
    - Reuses an existing NIC if ExistingNicId is supplied; otherwise creates a new NIC from the source VM's primary NIC settings or the provided
      subnet, NSG, private IP, and public IP overrides.
        - Can run in a preflight-only mode to show what will be carried over before any Azure resources are created.
    - Builds a new VM configuration using the requested target VM name and size.
    - Reapplies supported placement and security settings from the manifest where available, including zone, availability set when appropriate,
            capacity reservation group when compatible with the target subscription and location, proximity placement group, encryption at host, security type, UEFI flags, tags, Windows license type, VM backup policy, direct VM-level
            maintenance assignments, and SQL VM registration and SQL licensing where those details were captured from the source VM.
    - Attaches the restored OS disk as a specialized managed disk, adds restored data disks by LUN, and creates the new VM in Azure.

.PARAMETER ManifestPath
    Path to the JSON manifest created by script.ps1. The manifest supplies the snapshot IDs and the source VM metadata used to rebuild the VM.

.PARAMETER TargetVmName
    Name for the new Azure VM resource that will be created from the restored disks.

.PARAMETER TargetVmSize
    Azure VM size to assign to the replacement VM, such as Standard_D4ds_v5.

.PARAMETER TargetSubscriptionId
    Optional override for the subscription where the replacement VM should be created. If omitted, the source subscription from the manifest is used.

.PARAMETER TargetResourceGroupName
    Optional override for the destination resource group. If omitted, the source resource group from the manifest is used.

.PARAMETER TargetLocation
    Optional override for the Azure region. If omitted, the source VM location from the manifest is used.

.PARAMETER TargetZone
    Optional availability zone override for the restored disks and new VM. If omitted, the source zone information from the manifest is used when present.

.PARAMETER ExistingNicId
    Optional resource ID of an existing NIC to attach to the replacement VM instead of creating a new NIC from manifest data.

.PARAMETER NewNicName
    Optional name for a NIC created by this script. If omitted, the default name is <TargetVmName>-nic.

.PARAMETER SubnetId
    Optional subnet resource ID to use when creating a new NIC. If omitted, the script uses the source primary NIC subnet stored in the manifest.

.PARAMETER NetworkSecurityGroupId
    Optional NSG resource ID to associate with a new NIC created by this script. If omitted, the source primary NIC NSG from the manifest is used when available.

.PARAMETER PrivateIpAddress
    Optional static private IP address to assign when creating a new NIC. If omitted, Azure allocates the private IP dynamically unless UseSourcePrivateIp is specified.

.PARAMETER UseSourcePrivateIp
    Reuses the private IP address recorded in the manifest when creating a new NIC. This only works if the original NIC or IP assignment has already been released.

.PARAMETER PublicIpAddressId
    Optional public IP resource ID to attach to a new NIC created by this script.

.PARAMETER AttachSourcePublicIp
    Reuses the public IP resource ID recorded in the manifest when creating a new NIC. This only works if the original public IP is no longer attached elsewhere.

.PARAMETER PreflightOnly
    Validates the manifest and target options, then outputs a carryover and networking report without creating Azure resources.

.EXAMPLE
    pwsh ./new-vm-from-snapshot-manifest.ps1 -ManifestPath .\myvm-snapshot-manifest-14-08-2026_10_30.json -TargetVmName myvm-ds -TargetVmSize Standard_D4ds_v5

    Creates a replacement VM in the source subscription, resource group, and location stored in the manifest, using a new NIC derived from the source primary NIC.

.EXAMPLE
    pwsh ./new-vm-from-snapshot-manifest.ps1 -ManifestPath .\myvm-snapshot-manifest-14-08-2026_10_30.json -TargetVmName myvm-ds -TargetVmSize Standard_D4ds_v5 -TargetResourceGroupName rg-migration -TargetLocation uksouth -SubnetId /subscriptions/.../subnets/app-subnet

    Restores the VM into a different resource group or networking destination while still using the captured snapshots and VM metadata from the manifest.

.EXAMPLE
    pwsh ./new-vm-from-snapshot-manifest.ps1 -ManifestPath .\myvm-snapshot-manifest-14-08-2026_10_30.json -TargetVmName myvm-ds -TargetVmSize Standard_D4ds_v5 -ExistingNicId /subscriptions/.../networkInterfaces/myvm-cutover-nic

    Creates the replacement VM using a pre-created NIC, which is useful when cutover networking has already been prepared separately.

.EXAMPLE
    pwsh ./new-vm-from-snapshot-manifest.ps1 -ManifestPath .\myvm-snapshot-manifest-14-08-2026_10_30.json -TargetVmName myvm-ds -TargetVmSize Standard_D4ds_v5 -TargetResourceGroupName rg-migration -PreflightOnly

    Produces a preflight report showing the planned destination, IP strategy, Windows licensing, backup policy, maintenance assignment, and SQL VM carryover plan without creating a VM.

.NOTES
    Purpose: Intended for migration workflows where the guest disks remain the same but the VM size changes, such as moving to a SKU family that includes temporary storage.
    Required Inputs: ManifestPath, TargetVmName, and TargetVmSize.
    Networking: Only the primary NIC path is recreated automatically. Reusing the source private IP or public IP requires the original NIC or IP resource to be released first.
    Backup: This script attempts to reapply Azure VM backup protection when the source manifest contains Recovery Services vault and policy details. SQL workload backup policies are not inferred automatically.
    Update Manager: This script replays direct VM-level maintenance configuration assignments. Subscription-, resource group-, and tag-scoped schedules are not inferred from the source VM.
    Capacity Reservation: This script reapplies the source capacity reservation group only when the target subscription and location remain compatible with the captured reservation group resource ID.
    SQL: If the source VM is registered as an Azure SQL virtual machine, this script attempts to recreate that registration and reapply the captured SQL license type on the replacement VM.
    Safety: This script creates new managed disks, NICs, and a new VM. It does not delete the source VM, the snapshots, or any intermediate disks it creates.
    Boot Behavior: Because the OS disk is attached as a specialized disk, the guest OS keeps its original computer name and in-guest configuration unless you change them after boot.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [string]$TargetVmName,

    [Parameter(Mandatory = $true)]
    [string]$TargetVmSize,

    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroupName,
    [string]$TargetLocation,
    [string[]]$TargetZone,
    [string]$ExistingNicId,
    [string]$NewNicName,
    [string]$SubnetId,
    [string]$NetworkSecurityGroupId,
    [string]$PrivateIpAddress,
    [switch]$UseSourcePrivateIp,
    [string]$PublicIpAddressId,
    [switch]$AttachSourcePublicIp,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    if ($null -eq $InputObject) {
        return $null
    }

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties[$propertyName]
        if (-not $property) {
            continue
        }

        $value = $property.Value
        if ($null -eq $value) {
            continue
        }

        if ($value -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }

            continue
        }

        return $value
    }

    return $null
}

function New-RestorePreflightReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmName,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmSize,

        [Parameter(Mandatory = $true)]
        [string]$EffectiveSubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$EffectiveResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$EffectiveLocation,

        [string[]]$EffectiveZone,
        [string]$ExistingNicId,
        [string]$NewNicName,
        [string]$SubnetId,
        [string]$PrivateIpAddress,
        [bool]$UseSourcePrivateIp,
        [string]$PublicIpAddressId,
        [bool]$AttachSourcePublicIp
    )

    $maintenanceAssignments = @()
    if ($Manifest.PSObject.Properties['MaintenanceAssignments']) {
        $maintenanceAssignments = @($Manifest.MaintenanceAssignments)
    }

    $sourceCapacityReservationGroupId = Get-ObjectPropertyValue -InputObject $Manifest.SourceVm -PropertyNames @('CapacityReservationGroupId')
    $willApplyCapacityReservationGroup = $false
    if (-not [string]::IsNullOrWhiteSpace($sourceCapacityReservationGroupId)) {
        if ($Manifest.SourceVm.SubscriptionId -ne $EffectiveSubscriptionId) {
            $warnings.Add('The source capacity reservation group will not be applied because the target subscription differs from the source subscription.')
        }
        elseif ($Manifest.SourceVm.Location -ne $EffectiveLocation) {
            $warnings.Add('The source capacity reservation group will not be applied because the target location differs from the source VM location.')
        }
        else {
            $willApplyCapacityReservationGroup = $true
            if ($Manifest.SourceVm.VmSize -ne $TargetVmSize) {
                $warnings.Add('The source capacity reservation group will be applied, but it must contain a reservation that matches the target VM size or the VM create operation can fail.')
            }

            if ($EffectiveZone.Count -gt 0 -and @($Manifest.SourceVm.Zones).Count -gt 0 -and ((@($Manifest.SourceVm.Zones) -join ',') -ne ($EffectiveZone -join ','))) {
                $warnings.Add('The source capacity reservation group will be applied, but it must also contain capacity for the target zone selection or the VM create operation can fail.')
            }
        }
    }

    $backupProtection = $null
    if ($Manifest.PSObject.Properties['BackupProtection']) {
        $backupProtection = $Manifest.BackupProtection
    }

    $sqlVirtualMachine = $null
    if ($Manifest.PSObject.Properties['SqlVirtualMachine']) {
        $sqlVirtualMachine = $Manifest.SqlVirtualMachine
    }

    $warnings = [System.Collections.Generic.List[string]]::new()
    $sourcePrimaryNic = $Manifest.Network.PrimaryNic
    $privateIpMode = 'None'
    $publicIpMode = 'None'
    $networkAction = 'AttachExistingNic'

    if ($ExistingNicId) {
        $privateIpMode = 'ExistingNic'
        $publicIpMode = 'ExistingNic'
    }
    else {
        $networkAction = 'CreateNewNic'

        if ($UseSourcePrivateIp) {
            $privateIpMode = 'ReuseSourcePrivateIp'
            $warnings.Add('The original NIC or IP assignment must be released before the replacement VM can claim the source private IP.')
        }
        elseif ($PrivateIpAddress) {
            $privateIpMode = 'StaticPrivateIp'
        }
        else {
            $privateIpMode = 'DynamicPrivateIp'
            $warnings.Add('The replacement VM will be created with a newly allocated dynamic private IP unless you supply -PrivateIpAddress or -UseSourcePrivateIp.')
        }

        if ($AttachSourcePublicIp) {
            $publicIpMode = 'ReuseSourcePublicIp'
            $warnings.Add('The original public IP must be detached before the replacement VM can claim it.')
        }
        elseif ($PublicIpAddressId) {
            $publicIpMode = 'ExplicitPublicIp'
        }
    }

    $windowsLicenseType = Get-ObjectPropertyValue -InputObject $Manifest.SourceVm -PropertyNames @('LicenseType')
    $sqlLicenseType = Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('LicenseType')

    $backupIsProtected = [bool](Get-ObjectPropertyValue -InputObject $backupProtection -PropertyNames @('IsProtected'))
    if ($backupIsProtected) {
        $vaultId = Get-ObjectPropertyValue -InputObject $backupProtection -PropertyNames @('VaultId')
        $policyName = Get-ObjectPropertyValue -InputObject $backupProtection -PropertyNames @('PolicyName')
        if ([string]::IsNullOrWhiteSpace($vaultId) -or [string]::IsNullOrWhiteSpace($policyName)) {
            $warnings.Add('VM backup protection was detected, but vault or policy details were incomplete. Manual backup reconfiguration may be required.')
        }

        if ($Manifest.SourceVm.Location -ne $EffectiveLocation) {
            $warnings.Add('The target location differs from the source location. Reapplying the same Recovery Services vault policy may fail.')
        }
    }

    if ($maintenanceAssignments.Count -eq 0) {
        $warnings.Add('No direct VM-level maintenance configuration assignments were captured. Subscription-, resource group-, and tag-scoped Update Manager schedules are not inferred by this script.')
    }
    else {
        $warnings.Add('Only direct VM-level maintenance configuration assignments are replayed automatically.')
    }

    if ($sqlVirtualMachine -and [bool](Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('IsRegistered'))) {
        $warnings.Add('SQL VM registration and SQL license type will be reapplied if the target VM can be registered successfully with the SQL IaaS extension.')
    }

    return [pscustomobject]@{
        SourceVm = [pscustomobject]@{
            Name                   = $Manifest.SourceVm.Name
            ResourceGroupName      = $Manifest.SourceVm.ResourceGroupName
            Location               = $Manifest.SourceVm.Location
            WindowsLicenseType     = $windowsLicenseType
            CapacityReservationGroupId = $sourceCapacityReservationGroupId
            SqlVirtualMachineType  = Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('SqlManagementType')
            SqlLicenseType         = $sqlLicenseType
        }
        Target = [pscustomobject]@{
            Name              = $TargetVmName
            VmSize            = $TargetVmSize
            SubscriptionId    = $EffectiveSubscriptionId
            ResourceGroupName = $EffectiveResourceGroupName
            Location          = $EffectiveLocation
            Zone              = @($EffectiveZone)
        }
        NetworkPlan = [pscustomobject]@{
            Action          = $networkAction
            ExistingNicId   = $ExistingNicId
            NewNicName      = if ($NewNicName) { $NewNicName } else { "$TargetVmName-nic" }
            SubnetId        = if ($ExistingNicId) { $null } elseif ($SubnetId) { $SubnetId } else { Get-ObjectPropertyValue -InputObject $sourcePrimaryNic -PropertyNames @('SubnetId') }
            PrivateIpMode   = $privateIpMode
            PrivateIpAddress = if ($UseSourcePrivateIp) { Get-ObjectPropertyValue -InputObject $sourcePrimaryNic -PropertyNames @('PrivateIpAddress') } elseif ($PrivateIpAddress) { $PrivateIpAddress } else { $null }
            PublicIpMode    = $publicIpMode
            PublicIpAddressId = if ($AttachSourcePublicIp) { Get-ObjectPropertyValue -InputObject $sourcePrimaryNic -PropertyNames @('PublicIpAddressId') } elseif ($PublicIpAddressId) { $PublicIpAddressId } else { $null }
        }
        Carryover = [pscustomobject]@{
            WindowsLicenseType = [pscustomobject]@{
                Value     = $windowsLicenseType
                WillApply = -not [string]::IsNullOrWhiteSpace($windowsLicenseType)
            }
            CapacityReservationGroup = [pscustomobject]@{
                Id        = $sourceCapacityReservationGroupId
                WillApply = $willApplyCapacityReservationGroup
            }
            VmBackupProtection = if ($backupProtection) {
                [pscustomobject]@{
                    IsProtected        = $backupIsProtected
                    VaultName          = Get-ObjectPropertyValue -InputObject $backupProtection -PropertyNames @('VaultName')
                    PolicyName         = Get-ObjectPropertyValue -InputObject $backupProtection -PropertyNames @('PolicyName')
                    WillAttemptReapply = $backupIsProtected
                }
            }
            else {
                $null
            }
            MaintenanceAssignments = @($maintenanceAssignments | ForEach-Object {
                [pscustomobject]@{
                    Name                     = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('ConfigurationAssignmentName', 'Name')
                    MaintenanceConfigurationId = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('MaintenanceConfigurationId')
                }
            })
            SqlVirtualMachine = if ($sqlVirtualMachine) {
                [pscustomobject]@{
                    IsRegistered       = [bool](Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('IsRegistered'))
                    LicenseType        = $sqlLicenseType
                    Sku                = Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('Sku')
                    SqlManagementType  = Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('SqlManagementType')
                    WillAttemptReapply = [bool](Get-ObjectPropertyValue -InputObject $sqlVirtualMachine -PropertyNames @('IsRegistered'))
                }
            }
            else {
                $null
            }
        }
        Warnings = @($warnings)
    }
}

function Restore-VmBackupProtection {
    param(
        [AllowNull()]
        [object]$BackupProtection,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName
    )

    if (-not $BackupProtection) {
        return $false
    }

    if (-not [bool](Get-ObjectPropertyValue -InputObject $BackupProtection -PropertyNames @('IsProtected'))) {
        return $false
    }

    $vaultId = Get-ObjectPropertyValue -InputObject $BackupProtection -PropertyNames @('VaultId')
    $policyName = Get-ObjectPropertyValue -InputObject $BackupProtection -PropertyNames @('PolicyName')
    if ([string]::IsNullOrWhiteSpace($vaultId) -or [string]::IsNullOrWhiteSpace($policyName)) {
        Write-Warning 'Skipping Azure VM backup reconfiguration because the manifest did not contain both a vault ID and policy name.'
        return $false
    }

    $policy = $null
    try {
        $policyLookupParameters = @{
            Name    = $policyName
            VaultId = $vaultId
        }

        $backupManagementType = Get-ObjectPropertyValue -InputObject $BackupProtection -PropertyNames @('BackupManagementType')
        $workloadType = Get-ObjectPropertyValue -InputObject $BackupProtection -PropertyNames @('WorkloadType')
        if ($backupManagementType) {
            $policyLookupParameters.BackupManagementType = $backupManagementType
        }

        if ($workloadType) {
            $policyLookupParameters.WorkloadType = $workloadType
        }

        $policy = Get-AzRecoveryServicesBackupProtectionPolicy @policyLookupParameters -ErrorAction Stop
    }
    catch {
        try {
            $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $policyName -VaultId $vaultId -ErrorAction Stop
        }
        catch {
            Write-Warning "Unable to find backup policy '$policyName' in vault '$vaultId'. $($_.Exception.Message)"
            return $false
        }
    }

    try {
        $null = Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name $TargetVmName -ResourceGroupName $TargetResourceGroupName -ErrorAction Stop
        Write-Host "Azure VM backup protection enabled using policy '$policyName'."
        return $true
    }
    catch {
        Write-Warning "Unable to enable Azure VM backup protection for VM '$TargetVmName'. $($_.Exception.Message)"
        return $false
    }
}

function Restore-MaintenanceAssignments {
    param(
        [object[]]$MaintenanceAssignments,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmResourceId
    )

    $appliedAssignments = @()
    foreach ($assignment in @($MaintenanceAssignments)) {
        $assignmentName = Get-ObjectPropertyValue -InputObject $assignment -PropertyNames @('ConfigurationAssignmentName', 'Name')
        $maintenanceConfigurationId = Get-ObjectPropertyValue -InputObject $assignment -PropertyNames @('MaintenanceConfigurationId')
        if ([string]::IsNullOrWhiteSpace($assignmentName) -or [string]::IsNullOrWhiteSpace($maintenanceConfigurationId)) {
            Write-Warning 'Skipping a maintenance configuration assignment because the manifest did not contain both a name and a maintenance configuration ID.'
            continue
        }

        $location = Get-ObjectPropertyValue -InputObject $assignment -PropertyNames @('Location')
        if ([string]::IsNullOrWhiteSpace($location)) {
            $location = 'global'
        }

        try {
            $null = New-AzConfigurationAssignment -ResourceId $TargetVmResourceId -ConfigurationAssignmentName $assignmentName -MaintenanceConfigurationId $maintenanceConfigurationId -Location $location -ErrorAction Stop
            $appliedAssignments += $assignmentName
            Write-Host "Maintenance configuration assignment '$assignmentName' applied."
        }
        catch {
            Write-Warning "Unable to apply maintenance configuration assignment '$assignmentName'. $($_.Exception.Message)"
        }
    }

    return @($appliedAssignments)
}

function Restore-SqlVirtualMachineRegistration {
    param(
        [AllowNull()]
        [object]$SqlVirtualMachine,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation,

        [Parameter(Mandatory = $true)]
        [string]$VirtualMachineResourceId
    )

    if (-not $SqlVirtualMachine) {
        return $false
    }

    if (-not [bool](Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('IsRegistered'))) {
        return $false
    }

    $baseParameters = @{
        ResourceGroupName     = $TargetResourceGroupName
        Name                  = $TargetVmName
        Location              = $TargetLocation
        VirtualMachineResourceId = $VirtualMachineResourceId
    }

    $sqlLicenseType = Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('LicenseType')
    $sqlSku = Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('Sku')
    $sqlOffer = Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('Offer')
    $sqlManagementType = Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('SqlManagementType')

    if ($sqlLicenseType) {
        $baseParameters.LicenseType = $sqlLicenseType
    }

    if ($sqlSku) {
        $baseParameters.Sku = $sqlSku
    }

    if ($sqlOffer) {
        $baseParameters.Offer = $sqlOffer
    }

    if ($sqlManagementType) {
        $baseParameters.SqlManagementType = $sqlManagementType
    }

    if ([bool](Get-ObjectPropertyValue -InputObject $SqlVirtualMachine -PropertyNames @('EnableAutoUpgrade'))) {
        $baseParameters.EnableAutomaticUpgrade = $true
    }

    try {
        $existingSqlVm = Get-AzSqlVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue
        if ($existingSqlVm) {
            $updateParameters = @{
                ResourceGroupName = $TargetResourceGroupName
                Name              = $TargetVmName
            }

            foreach ($key in @('LicenseType', 'Sku', 'Offer', 'SqlManagementType', 'EnableAutomaticUpgrade')) {
                if ($baseParameters.ContainsKey($key)) {
                    $updateParameters[$key] = $baseParameters[$key]
                }
            }

            $null = Update-AzSqlVM @updateParameters -ErrorAction Stop
        }
        else {
            $null = New-AzSqlVM @baseParameters -ErrorAction Stop
        }

        Write-Host "SQL virtual machine registration applied for VM '$TargetVmName'."
        return $true
    }
    catch {
        Write-Warning "Unable to configure the SQL virtual machine resource for VM '$TargetVmName'. $($_.Exception.Message)"
        return $false
    }
}

function New-RestoredManagedDisk {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SnapshotDefinition,

        [Parameter(Mandatory = $true)]
        [string]$TargetDiskName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [string[]]$Zone
    )

    if (Get-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -ErrorAction SilentlyContinue) {
        throw "A managed disk named '$TargetDiskName' already exists in resource group '$TargetResourceGroupName'."
    }

    $snapshot = Get-AzSnapshot -ResourceGroupName $SnapshotDefinition.SnapshotResourceGroup -SnapshotName $SnapshotDefinition.SnapshotName
    $diskConfigParameters = @{
        Location         = $Location
        CreateOption     = 'Copy'
        SourceResourceId = $snapshot.Id
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotDefinition.StorageAccountType)) {
        $diskConfigParameters.SkuName = $SnapshotDefinition.StorageAccountType
    }

    if ($Zone -and $Zone.Count -gt 0) {
        $diskConfigParameters.Zone = $Zone
    }

    $diskConfig = New-AzDiskConfig @diskConfigParameters
    return New-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $TargetDiskName -Disk $diskConfig
}

function New-RestoredNetworkInterface {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [object]$SourcePrimaryNic,
        [string]$NicName,
        [string]$OverrideSubnetId,
        [string]$OverrideNetworkSecurityGroupId,
        [string]$OverridePrivateIpAddress,
        [bool]$ReuseSourcePrivateIp,
        [string]$OverridePublicIpAddressId,
        [bool]$ReuseSourcePublicIp
    )

    $effectiveSubnetId = if ($OverrideSubnetId) { $OverrideSubnetId } else { $SourcePrimaryNic.SubnetId }
    if ([string]::IsNullOrWhiteSpace($effectiveSubnetId)) {
        throw 'A subnet ID is required. Provide -SubnetId or use a manifest that contains source primary NIC details.'
    }

    $effectiveNicName = if ($NicName) { $NicName } else { "$VmName-nic" }
    if (Get-AzNetworkInterface -Name $effectiveNicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) {
        throw "A network interface named '$effectiveNicName' already exists in resource group '$ResourceGroupName'."
    }

    $effectiveNsgId = if ($OverrideNetworkSecurityGroupId) { $OverrideNetworkSecurityGroupId } else { $SourcePrimaryNic.NetworkSecurityGroupId }
    $effectivePrivateIpAddress = $null
    if ($ReuseSourcePrivateIp) {
        $effectivePrivateIpAddress = $SourcePrimaryNic.PrivateIpAddress
        if ([string]::IsNullOrWhiteSpace($effectivePrivateIpAddress)) {
            throw 'The manifest does not contain a source private IP address to reuse.'
        }

        Write-Warning 'Reusing the source private IP address requires the original NIC to be detached first.'
    }
    elseif ($OverridePrivateIpAddress) {
        $effectivePrivateIpAddress = $OverridePrivateIpAddress
    }

    $effectivePublicIpAddressId = $null
    if ($ReuseSourcePublicIp) {
        $effectivePublicIpAddressId = $SourcePrimaryNic.PublicIpAddressId
        if ([string]::IsNullOrWhiteSpace($effectivePublicIpAddressId)) {
            throw 'The manifest does not contain a source public IP address to reuse.'
        }

        Write-Warning 'Reusing the source public IP address requires the original NIC to be detached first.'
    }
    elseif ($OverridePublicIpAddressId) {
        $effectivePublicIpAddressId = $OverridePublicIpAddressId
    }

    $nicParameters = @{
        Name                = $effectiveNicName
        ResourceGroupName   = $ResourceGroupName
        Location            = $Location
        SubnetId            = $effectiveSubnetId
        IpConfigurationName = 'ipconfig1'
    }

    if ($effectiveNsgId) {
        $nicParameters.NetworkSecurityGroupId = $effectiveNsgId
    }

    if ($SourcePrimaryNic.EnableAcceleratedNetworking) {
        $nicParameters.EnableAcceleratedNetworking = $true
    }

    if ($effectivePrivateIpAddress) {
        $nicParameters.PrivateIpAddress = $effectivePrivateIpAddress
    }

    if ($effectivePublicIpAddressId) {
        $nicParameters.PublicIpAddressId = $effectivePublicIpAddressId
    }

    return New-AzNetworkInterface @nicParameters
}

try {
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        throw "Manifest file '$ManifestPath' does not exist."
    }

    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -Depth 20
    if (-not $manifest.SourceVm) {
        throw 'The manifest is missing the SourceVm section.'
    }

    if (-not $manifest.Snapshots -or -not $manifest.Snapshots.OsDisk) {
        throw 'The manifest is missing the OS disk snapshot definition.'
    }

    Connect-AzAccount | Out-Null

    $effectiveSubscriptionId = if ($TargetSubscriptionId) { $TargetSubscriptionId } else { $manifest.SourceVm.SubscriptionId }
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) {
        throw 'A target subscription ID is required. Supply -TargetSubscriptionId or use a manifest with SourceVm.SubscriptionId.'
    }

    $null = Set-AzContext -SubscriptionId $effectiveSubscriptionId

    $effectiveResourceGroupName = if ($TargetResourceGroupName) { $TargetResourceGroupName } else { $manifest.SourceVm.ResourceGroupName }
    if ([string]::IsNullOrWhiteSpace($effectiveResourceGroupName)) {
        throw 'A target resource group is required. Supply -TargetResourceGroupName or use a manifest with SourceVm.ResourceGroupName.'
    }

    $effectiveLocation = if ($TargetLocation) { $TargetLocation } else { $manifest.SourceVm.Location }
    if ([string]::IsNullOrWhiteSpace($effectiveLocation)) {
        throw 'A target location is required. Supply -TargetLocation or use a manifest with SourceVm.Location.'
    }

    $null = Get-AzResourceGroup -Name $effectiveResourceGroupName

    if (Get-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue) {
        throw "A VM named '$TargetVmName' already exists in resource group '$effectiveResourceGroupName'."
    }

    $effectiveZone = @()
    if ($PSBoundParameters.ContainsKey('TargetZone')) {
        $effectiveZone = @($TargetZone)
    }
    elseif ($manifest.SourceVm.Zones) {
        $effectiveZone = @($manifest.SourceVm.Zones)
    }

    $availabilitySetId = $null
    if ($effectiveZone.Count -eq 0 -and $manifest.SourceVm.AvailabilitySetId) {
        $availabilitySetId = $manifest.SourceVm.AvailabilitySetId
    }
    elseif ($effectiveZone.Count -gt 0 -and $manifest.SourceVm.AvailabilitySetId) {
        Write-Warning 'TargetZone was supplied or inferred, so the source availability set will not be reused.'
    }

    $effectiveCapacityReservationGroupId = $null
    $sourceCapacityReservationGroupId = Get-ObjectPropertyValue -InputObject $manifest.SourceVm -PropertyNames @('CapacityReservationGroupId')
    if (-not [string]::IsNullOrWhiteSpace($sourceCapacityReservationGroupId)) {
        if ($manifest.SourceVm.SubscriptionId -ne $effectiveSubscriptionId) {
            Write-Warning 'Skipping the source capacity reservation group because the target subscription differs from the source subscription.'
        }
        elseif ($manifest.SourceVm.Location -ne $effectiveLocation) {
            Write-Warning 'Skipping the source capacity reservation group because the target location differs from the source VM location.'
        }
        else {
            $effectiveCapacityReservationGroupId = $sourceCapacityReservationGroupId
            if ($manifest.SourceVm.VmSize -ne $TargetVmSize) {
                Write-Warning 'Applying the source capacity reservation group to a different target VM size. Ensure the group contains a matching reservation for the target size or VM creation can fail.'
            }

            if ($effectiveZone.Count -gt 0 -and @($manifest.SourceVm.Zones).Count -gt 0 -and ((@($manifest.SourceVm.Zones) -join ',') -ne ($effectiveZone -join ','))) {
                Write-Warning 'Applying the source capacity reservation group to a different zone selection. Ensure the group contains matching zonal capacity or VM creation can fail.'
            }
        }
    }

    $preflightReport = New-RestorePreflightReport -Manifest $manifest -TargetVmName $TargetVmName -TargetVmSize $TargetVmSize -EffectiveSubscriptionId $effectiveSubscriptionId -EffectiveResourceGroupName $effectiveResourceGroupName -EffectiveLocation $effectiveLocation -EffectiveZone $effectiveZone -ExistingNicId $ExistingNicId -NewNicName $NewNicName -SubnetId $SubnetId -PrivateIpAddress $PrivateIpAddress -UseSourcePrivateIp $UseSourcePrivateIp.IsPresent -PublicIpAddressId $PublicIpAddressId -AttachSourcePublicIp $AttachSourcePublicIp.IsPresent
    if ($PreflightOnly) {
        $preflightReport
        return
    }

    $sourcePrimaryNic = $manifest.Network.PrimaryNic
    if ($ExistingNicId) {
        $nic = Get-AzNetworkInterface -ResourceId $ExistingNicId
    }
    else {
        $nic = New-RestoredNetworkInterface -VmName $TargetVmName -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -SourcePrimaryNic $sourcePrimaryNic -NicName $NewNicName -OverrideSubnetId $SubnetId -OverrideNetworkSecurityGroupId $NetworkSecurityGroupId -OverridePrivateIpAddress $PrivateIpAddress -ReuseSourcePrivateIp $UseSourcePrivateIp.IsPresent -OverridePublicIpAddressId $PublicIpAddressId -ReuseSourcePublicIp $AttachSourcePublicIp.IsPresent
    }

    $restoredOsDisk = New-RestoredManagedDisk -SnapshotDefinition $manifest.Snapshots.OsDisk -TargetDiskName "$TargetVmName-osdisk" -TargetResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -Zone $effectiveZone

    $restoredDataDisks = @()
    $dataDiskSnapshotDefinitions = @()
    if ($manifest.Snapshots.DataDisks) {
        $dataDiskSnapshotDefinitions = @($manifest.Snapshots.DataDisks)
    }

    foreach ($dataDiskSnapshot in $dataDiskSnapshotDefinitions) {
        $restoredDisk = New-RestoredManagedDisk -SnapshotDefinition $dataDiskSnapshot -TargetDiskName ("{0}-data-lun{1}" -f $TargetVmName, $dataDiskSnapshot.Lun) -TargetResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -Zone $effectiveZone
        $restoredDataDisks += [pscustomobject]@{
            Disk    = $restoredDisk
            Lun     = [int]$dataDiskSnapshot.Lun
            Caching = $dataDiskSnapshot.Caching
        }
    }

    $vmConfigParameters = @{
        VMName = $TargetVmName
        VMSize = $TargetVmSize
    }

    if ($effectiveZone.Count -gt 0) {
        $vmConfigParameters.Zone = $effectiveZone
    }

    if ($availabilitySetId) {
        $vmConfigParameters.AvailabilitySetId = $availabilitySetId
    }

    if ($manifest.SourceVm.ProximityPlacementGroupId) {
        $vmConfigParameters.ProximityPlacementGroupId = $manifest.SourceVm.ProximityPlacementGroupId
    }

    if ($manifest.SourceVm.EncryptionAtHost) {
        $vmConfigParameters.EncryptionAtHost = $true
    }

    if ($effectiveCapacityReservationGroupId) {
        $vmConfigParameters.CapacityReservationGroupId = $effectiveCapacityReservationGroupId
    }

    $vmConfig = New-AzVMConfig @vmConfigParameters
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary

    if ($manifest.SourceVm.SecurityType) {
        $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType $manifest.SourceVm.SecurityType
    }

    if ($manifest.SourceVm.UefiSettings) {
        $vmConfig = Set-AzVMUefi -VM $vmConfig -EnableSecureBoot:$manifest.SourceVm.UefiSettings.SecureBootEnabled -EnableVtpm:$manifest.SourceVm.UefiSettings.VTpmEnabled
    }

    $osDiskParameters = @{
        VM            = $vmConfig
        ManagedDiskId = $restoredOsDisk.Id
        Name          = $restoredOsDisk.Name
        CreateOption  = 'Attach'
    }

    if ($manifest.Snapshots.OsDisk.Caching) {
        $osDiskParameters.Caching = $manifest.Snapshots.OsDisk.Caching
    }

    switch ([string]$manifest.SourceVm.OsType) {
        'Windows' {
            $osDiskParameters.Windows = $true
        }
        'Linux' {
            $osDiskParameters.Linux = $true
        }
        default {
            throw "Unsupported OS type '$($manifest.SourceVm.OsType)' in the manifest."
        }
    }

    $vmConfig = Set-AzVMOSDisk @osDiskParameters

    foreach ($restoredDataDisk in $restoredDataDisks | Sort-Object -Property Lun) {
        $dataDiskParameters = @{
            VM            = $vmConfig
            Name          = $restoredDataDisk.Disk.Name
            ManagedDiskId = $restoredDataDisk.Disk.Id
            Lun           = $restoredDataDisk.Lun
            CreateOption  = 'Attach'
        }

        if ($restoredDataDisk.Caching) {
            $dataDiskParameters.Caching = $restoredDataDisk.Caching
        }

        $vmConfig = Add-AzVMDataDisk @dataDiskParameters
    }

    if ($manifest.SourceVm.Tags -and $vmConfig.PSObject.Properties.Match('Tags').Count -gt 0) {
        $vmConfig.Tags = $manifest.SourceVm.Tags
    }

    if ($manifest.SourceVm.LicenseType -and $vmConfig.PSObject.Properties.Match('LicenseType').Count -gt 0) {
        $vmConfig.LicenseType = $manifest.SourceVm.LicenseType
    }

    $null = New-AzVM -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -VM $vmConfig
    $createdVm = Get-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName

    $backupApplied = Restore-VmBackupProtection -BackupProtection $manifest.BackupProtection -TargetVmName $TargetVmName -TargetResourceGroupName $effectiveResourceGroupName
    $appliedMaintenanceAssignments = Restore-MaintenanceAssignments -MaintenanceAssignments @($manifest.MaintenanceAssignments) -TargetVmResourceId $createdVm.Id
    $sqlRegistrationApplied = Restore-SqlVirtualMachineRegistration -SqlVirtualMachine $manifest.SqlVirtualMachine -TargetVmName $TargetVmName -TargetResourceGroupName $effectiveResourceGroupName -TargetLocation $effectiveLocation -VirtualMachineResourceId $createdVm.Id

    Write-Host "VM '$TargetVmName' created successfully in resource group '$effectiveResourceGroupName'."

    [pscustomobject]@{
        VmName            = $TargetVmName
        SubscriptionId    = $effectiveSubscriptionId
        ResourceGroupName = $effectiveResourceGroupName
        Location          = $effectiveLocation
        VmSize            = $TargetVmSize
        NicId             = $nic.Id
        OsDiskName        = $restoredOsDisk.Name
        DataDiskNames     = @($restoredDataDisks | ForEach-Object { $_.Disk.Name })
        CapacityReservationGroupId = $effectiveCapacityReservationGroupId
        WindowsLicenseType = $manifest.SourceVm.LicenseType
        BackupProtectionApplied = $backupApplied
        MaintenanceAssignmentsApplied = @($appliedMaintenanceAssignments)
        SqlVirtualMachineRegistrationApplied = $sqlRegistrationApplied
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
