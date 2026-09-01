#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a replacement Azure VM from a snapshot manifest, on a different VM size, keeping
    as much of the original configuration as Azure allows.

.DESCRIPTION
    This is the restore half of the snapshot-and-rebuild toolkit. It consumes a manifest
    written by save-vm-snapshot-manifest.ps1.

    Why this exists: Azure will not resize a VM between a size WITHOUT a local temporary
    disk and a size WITH one. The disks have to be snapshotted and attached to a new VM,
    and a new VM is a new Azure resource - so backup protection, patch schedules,
    monitoring associations, identity and role assignments do not come with it. This script
    replays everything it can and reports, precisely, everything it cannot.

    Order of operations:
      1. Validate the manifest, its schema version and its recorded consistency mode.
      2. Preflight: check the target size exists in the region and zone, that it actually
         HAS a local temp disk, that it supports the features the source VM used, that the
         names are free, and - critically - that the SOURCE VM IS DEALLOCATED, so the two
         machines are never running at once with the same identity.
      3. Create managed disks from the snapshots or disk restore points, re-applying SKU,
         zone, encryption set, performance tier and provisioned IOPS.
      4. Resolve the NIC: reuse the source NIC, attach an existing one, or create a new one.
      5. Build and create the VM.
      6. Post-create: boot diagnostics, extensions, data collection rule associations,
         backup protection, maintenance assignments and SQL VM registration.
      7. Print a carryover report and a manual checklist.

    The new VM is deliberately left STOPPED unless -StartVm is given, so you choose the
    moment the workload comes back up.

.PARAMETER ManifestPath
    Path to the manifest JSON written by save-vm-snapshot-manifest.ps1.

.PARAMETER TargetVmName
    Name for the replacement VM. Must not already exist.

.PARAMETER TargetVmSize
    The new VM size, for example Standard_E8ds_v5. Preflight verifies it has a temp disk.

.PARAMETER TargetSubscriptionId
    Destination subscription. Defaults to the source subscription from the manifest.

.PARAMETER TargetResourceGroupName
    Destination resource group. Defaults to the source resource group.

.PARAMETER TargetLocation
    Destination region. Defaults to the source location.

.PARAMETER TargetZone
    Availability zone for the new VM and its disks. Defaults to the source VM's zone.

.PARAMETER DiskNamePrefix
    Prefix for the created managed disk names. Defaults to the target VM name.

.PARAMETER RestoreMode
    AttachOsDisk   - default. Creates the VM by attaching the restored OS disk directly.
                     Simple, one step, and the guest comes up exactly as it was. Its one
                     permanent cost: a VM created this way has NO osProfile, and every
                     guest patch setting (patchMode, assessmentMode, hotpatching,
                     bypassPlatformSafetyChecksOnUserSchedule) lives inside osProfile.
                     Azure rejects osProfile on this create path and refuses to add it
                     later, so Azure Update Manager SCHEDULED patching cannot be
                     re-established. On-demand assessment and patching still work.

    ImageFirstSwap - creates a throwaway VM from the source VM's ORIGINAL platform image,
                     which gives it a real osProfile carrying the source's patch settings,
                     then deallocates it and swaps the restored OS disk in. This is the
                     only way to keep scheduled patching. It costs an extra 15-20 minutes
                     and requires the manifest to record an image reference, the restored
                     OS disk to match the placeholder disk in size, generation and
                     security type, and a throwaway local administrator account that is
                     discarded with the placeholder disk.

.PARAMETER KeepPlaceholderOsDisk
    In ImageFirstSwap mode, keeps the placeholder OS disk that the swap leaves behind
    instead of deleting it. It is a from-image disk with no data on it; the default is to
    delete it so it does not accrue cost.

.PARAMETER ReuseSourceNic
    Attaches the SOURCE VM's primary NIC to the replacement VM. This is the highest
    fidelity network option: it preserves the private IP, the NSG association, application
    security group membership and load balancer or application gateway backend pool
    membership, none of which survive creating a fresh NIC. Requires the source VM to have
    been deleted first, because a NIC can only be attached to one VM.

.PARAMETER ExistingNicId
    Attaches a NIC you have already prepared.

.PARAMETER NewNicName
    Name for a NIC created by this script. Defaults to <TargetVmName>-nic.

.PARAMETER SubnetId
    Subnet for a new NIC. Defaults to the source primary NIC's subnet.

.PARAMETER NetworkSecurityGroupId
    NSG for a new NIC. Defaults to the source primary NIC's NSG.

.PARAMETER PrivateIpAddress
    Static private IP for a new NIC.

.PARAMETER UseSourcePrivateIp
    Claims the source VM's original private IP. Run release-vm-network-address.ps1 first,
    or this fails because the source NIC still holds the address.

.PARAMETER PublicIpAddressId
    Public IP resource to attach to a new NIC.

.PARAMETER AttachSourcePublicIp
    Reattaches the source VM's public IP. Requires it to have been detached first.

.PARAMETER StartVm
    Starts the replacement VM at the end. Off by default: the source VM and the replacement
    must never be running at the same time, and you should choose that moment.

.PARAMETER SkipBackup
    Do not attempt to re-enable Azure Backup protection.

.PARAMETER SkipMaintenance
    Do not replay Azure Update Manager maintenance configuration assignments.

.PARAMETER SkipSqlRegistration
    Do not attempt to register the new VM with the SQL IaaS extension.

.PARAMETER SkipExtensions
    Do not re-add VM extensions.

.PARAMETER SkipDataCollectionRules
    Do not recreate Azure Monitor data collection rule associations.

.PARAMETER PreflightOnly
    Runs every validation and prints the full carryover plan without creating anything.

.PARAMETER Force
    Proceeds despite non-fatal preflight objections, such as the source VM still running or
    a manifest captured in the LiveUnsafe consistency mode. Use deliberately.

.EXAMPLE
    .\new-vm-from-snapshot-manifest.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-20260901-101500.json -TargetVmName SQLPROD01-ds -TargetVmSize Standard_E8ds_v5 -PreflightOnly

    Full validation and carryover report. Creates nothing. Run this first, every time.

.EXAMPLE
    .\new-vm-from-snapshot-manifest.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-20260901-101500.json -TargetVmName SQLPROD01-ds -TargetVmSize Standard_E8ds_v5 -UseSourcePrivateIp

    Builds the replacement on a temp-disk size and claims the original private IP, which
    release-vm-network-address.ps1 must already have freed. Leaves the VM stopped.

.NOTES
    Companion scripts: save-vm-snapshot-manifest.ps1, release-vm-network-address.ps1,
    compare-vm-fidelity.ps1. See README.md for the cutover runbook and the manual checklist.

    This script creates disks, a NIC and a VM. It never deletes the source VM, the source
    disks or the snapshots.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVmName,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetVmSize,

    [string]$TargetSubscriptionId,
    [string]$TargetResourceGroupName,
    [string]$TargetLocation,
    [string[]]$TargetZone,
    [string]$DiskNamePrefix,

    [ValidateSet('AttachOsDisk', 'ImageFirstSwap')]
    [string]$RestoreMode = 'AttachOsDisk',

    [switch]$KeepPlaceholderOsDisk,

    [switch]$ReuseSourceNic,
    [string]$ExistingNicId,
    [string]$NewNicName,
    [string]$SubnetId,
    [string]$NetworkSecurityGroupId,
    [string]$PrivateIpAddress,
    [switch]$UseSourcePrivateIp,
    [string]$PublicIpAddressId,
    [switch]$AttachSourcePublicIp,

    [switch]$StartVm,
    [switch]$SkipBackup,
    [switch]$SkipMaintenance,
    [switch]$SkipSqlRegistration,
    [switch]$SkipExtensions,
    [switch]$SkipDataCollectionRules,

    [switch]$PreflightOnly,
    [switch]$Force
)

# Strict mode level 1, not 2. Level 1 catches references to uninitialised variables - the
# class of bug that made the original restore script call .Add() on a $null list. Level 2
# additionally throws on every missing or null property access, which is unusable against
# Az SDK objects, where navigating something like $vm.SecurityProfile.UefiSettings on a VM
# with no security profile is normal and must yield $null rather than end the migration.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'vm-rebuild-common.ps1')

$script:ManualChecklist = [System.Collections.Generic.List[string]]::new()
$script:CreatedResources = [System.Collections.Generic.List[object]]::new()

function Add-ManualChecklistItem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $script:ManualChecklist.Contains($Message)) {
        $script:ManualChecklist.Add($Message)
    }
}

function Register-CreatedResource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Id
    )

    $script:CreatedResources.Add([pscustomobject]@{ Type = $Type; Name = $Name; Id = $Id })
}


#region Target size validation

function Get-TargetSkuCapability {
    <#
    .SYNOPSIS
        Reads the target VM size's advertised capabilities in the target region.

    .DESCRIPTION
        This is the check the whole migration turns on. MaxResourceVolumeMB is the size of
        the local temporary disk: a size with no temp disk reports 0 or omits it entirely.
        If the target size does not actually have a temp disk, the migration achieves
        nothing and should stop before any resource is created.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$VmSize,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $sku = @(Get-AzComputeResourceSku -Location $Location -ErrorAction Stop |
        Where-Object { $_.ResourceType -eq 'virtualMachines' -and $_.Name -eq $VmSize }) | Select-Object -First 1

    if (-not $sku) {
        throw ("VM size '{0}' is not available in region '{1}' for this subscription." -f $VmSize, $Location)
    }

    $capabilities = @{}
    foreach ($capability in @($sku.Capabilities)) {
        $capabilities[$capability.Name] = $capability.Value
    }

    $restrictedZones = @()
    $regionRestricted = $false
    foreach ($restriction in @($sku.Restrictions)) {
        if ($restriction.Type -eq 'Location') {
            $regionRestricted = $true
        }

        if ($restriction.RestrictionInfo -and $restriction.RestrictionInfo.Zones) {
            $restrictedZones += @($restriction.RestrictionInfo.Zones)
        }
    }

    $readCapability = {
        param($name)
        if ($capabilities.ContainsKey($name)) {
            return $capabilities[$name]
        }

        return $null
    }

    $tempDiskMb = 0
    $rawTempDisk = & $readCapability 'MaxResourceVolumeMB'
    if ($rawTempDisk) {
        $tempDiskMb = [int]$rawTempDisk
    }

    return [pscustomobject]@{
        Name                     = $sku.Name
        Zones                    = (ConvertTo-StringArray -InputObject (@($sku.LocationInfo) | Select-Object -First 1).Zones)
        RestrictedZones          = (ConvertTo-StringArray -InputObject $restrictedZones)
        RegionRestricted         = $regionRestricted
        TempDiskSizeMB           = $tempDiskMb
        HasTempDisk              = ($tempDiskMb -gt 0)
        VCpus                    = (& $readCapability 'vCPUs')
        MemoryGB                 = (& $readCapability 'MemoryGB')
        MaxDataDiskCount         = (& $readCapability 'MaxDataDiskCount')
        PremiumIO                = (('' + (& $readCapability 'PremiumIO')) -eq 'True')
        AcceleratedNetworking    = (('' + (& $readCapability 'AcceleratedNetworkingEnabled')) -eq 'True')
        EncryptionAtHostSupported = (('' + (& $readCapability 'EncryptionAtHostSupported')) -eq 'True')
        UltraSSDAvailable        = (('' + (& $readCapability 'UltraSSDAvailable')) -eq 'True')
        HibernationSupported     = (('' + (& $readCapability 'HibernationSupported')) -eq 'True')
        HyperVGenerations        = (& $readCapability 'HyperVGenerations')
        CpuArchitectureType      = (& $readCapability 'CpuArchitectureType')
        DiskControllerTypes      = (& $readCapability 'DiskControllerTypes')
        TrustedLaunchDisabled    = (('' + (& $readCapability 'TrustedLaunchDisabled')) -eq 'True')
        Capabilities             = $capabilities
    }
}

#endregion


#region Disk restore

function New-RestoredDisk {
    <#
    .SYNOPSIS
        Creates one managed disk from a snapshot or a disk restore point.

    .DESCRIPTION
        Nothing except the bytes is inherited from the source. SKU, zone, encryption set,
        performance tier, provisioned IOPS and throughput, bursting, shared-disk max shares
        and the Hyper-V generation all have to be restated explicitly, or the new disk
        quietly comes back on platform defaults.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$SnapshotEntry,

        [Parameter(Mandatory = $true)]
        [string]$DiskName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [string[]]$Zone
    )

    if (Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -ErrorAction SilentlyContinue) {
        throw ("A managed disk named '{0}' already exists in resource group '{1}'. Choose a different -DiskNamePrefix or remove the existing disk." -f $DiskName, $ResourceGroupName)
    }

    $disk = $SnapshotEntry.Disk
    $sourceKind = Get-ObjectPropertyValue -InputObject $SnapshotEntry -PropertyNames @('SourceKind') -Default 'Snapshot'
    $sourceResourceId = Get-ObjectPropertyValue -InputObject $SnapshotEntry -PropertyNames @('SourceResourceId', 'SnapshotId')

    if ([string]::IsNullOrWhiteSpace($sourceResourceId)) {
        # Fall back to a name lookup only when the manifest predates recorded IDs. Resolving
        # by resource ID is preferred because it still works when the restore target is a
        # different subscription from the one the snapshot lives in.
        $snapshotResourceGroup = Get-ObjectPropertyValue -InputObject $SnapshotEntry -PropertyNames @('SnapshotResourceGroup')
        $snapshotName = Get-ObjectPropertyValue -InputObject $SnapshotEntry -PropertyNames @('SnapshotName')
        if ([string]::IsNullOrWhiteSpace($snapshotResourceGroup) -or [string]::IsNullOrWhiteSpace($snapshotName)) {
            throw 'The manifest snapshot entry has neither a source resource ID nor a resource group and name.'
        }

        $snapshot = Get-AzSnapshot -ResourceGroupName $snapshotResourceGroup -SnapshotName $snapshotName -ErrorAction Stop
        $sourceResourceId = $snapshot.Id
    }

    $configParameters = @{
        Location         = $Location
        SourceResourceId = $sourceResourceId
    }

    # A disk restore point is restored, not copied. Using the wrong create option produces
    # an unhelpful "source resource id is invalid" error.
    if ($sourceKind -eq 'DiskRestorePoint') {
        $configParameters.CreateOption = 'Restore'
    }
    else {
        $configParameters.CreateOption = 'Copy'
    }

    if ($disk.SkuName) {
        $configParameters.SkuName = $disk.SkuName
    }

    if ($Zone -and $Zone.Count -gt 0) {
        $configParameters.Zone = $Zone
    }

    if ($disk.DiskSizeGB) {
        $configParameters.DiskSizeGB = [int]$disk.DiskSizeGB
    }

    if ($disk.Encryption -and $disk.Encryption.DiskEncryptionSetId) {
        $configParameters.DiskEncryptionSetId = $disk.Encryption.DiskEncryptionSetId
        if ($disk.Encryption.Type) {
            $configParameters.EncryptionType = $disk.Encryption.Type
        }
    }

    if ($disk.DiskRole -eq 'OS') {
        if ($disk.HyperVGeneration) {
            $configParameters.HyperVGeneration = $disk.HyperVGeneration
        }

        if ($disk.OsType) {
            $configParameters.OsType = $disk.OsType
        }
    }

    # Optional properties, probed because they arrived in different Az.Compute releases.
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'Tier' -Value $disk.PerformanceTier
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'BurstingEnabled' -Value $disk.BurstingEnabled
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'MaxSharesCount' -Value $disk.MaxShares
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'NetworkAccessPolicy' -Value $disk.NetworkAccessPolicy
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'DiskAccessId' -Value $disk.DiskAccessId
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'PublicNetworkAccess' -Value $disk.PublicNetworkAccess
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'DataAccessAuthMode' -Value $disk.DataAccessAuthMode
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'Architecture' -Value $disk.Architecture

    # Premium SSD v2 and Ultra carry provisioned performance that is not inherited.
    if ($disk.SkuName -eq 'PremiumV2_LRS' -or $disk.SkuName -eq 'UltraSSD_LRS') {
        $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'DiskIOPSReadWrite' -Value $disk.DiskIOPSReadWrite
        $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'DiskMBpsReadWrite' -Value $disk.DiskMBpsReadWrite
        $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzDiskConfig' -ParameterName 'LogicalSectorSize' -Value $disk.LogicalSectorSize
    }

    $tagHashtable = ConvertTo-PlainHashtable -InputObject $disk.Tags
    if ($tagHashtable -and $tagHashtable.Count -gt 0) {
        $configParameters.Tag = $tagHashtable
    }

    $diskConfig = New-AzDiskConfig @configParameters
    $created = New-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $DiskName -Disk $diskConfig -ErrorAction Stop
    Register-CreatedResource -Type 'Disk' -Name $created.Name -Id $created.Id

    return $created
}

#endregion


#region Network

function New-RestoredNetworkInterface {
    param(
        [Parameter(Mandatory = $true)]
        [string]$NicName,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [AllowNull()]
        [object]$SourceNic,

        [string]$OverrideSubnetId,
        [string]$OverrideNetworkSecurityGroupId,
        [string]$OverridePrivateIpAddress,
        [bool]$ReuseSourcePrivateIp,
        [string]$OverridePublicIpAddressId,
        [bool]$ReuseSourcePublicIp
    )

    if (Get-AzNetworkInterface -Name $NicName -ResourceGroupName $ResourceGroupName -ErrorAction SilentlyContinue) {
        throw ("A network interface named '{0}' already exists in resource group '{1}'." -f $NicName, $ResourceGroupName)
    }

    $sourcePrimaryIp = $null
    if ($SourceNic) {
        $sourcePrimaryIp = @($SourceNic.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
        if (-not $sourcePrimaryIp) {
            $sourcePrimaryIp = @($SourceNic.IpConfigurations) | Select-Object -First 1
        }
    }

    $effectiveSubnetId = $OverrideSubnetId
    if ([string]::IsNullOrWhiteSpace($effectiveSubnetId)) {
        $effectiveSubnetId = Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('SubnetId')
    }

    if ([string]::IsNullOrWhiteSpace($effectiveSubnetId)) {
        throw 'A subnet is required. Supply -SubnetId, or use a manifest that recorded the source primary NIC.'
    }

    $nicParameters = @{
        Name                = $NicName
        ResourceGroupName   = $ResourceGroupName
        Location            = $Location
        SubnetId            = $effectiveSubnetId
        IpConfigurationName = (Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('Name') -Default 'ipconfig1')
    }

    $effectiveNsgId = $OverrideNetworkSecurityGroupId
    if ([string]::IsNullOrWhiteSpace($effectiveNsgId)) {
        $effectiveNsgId = Get-ObjectPropertyValue -InputObject $SourceNic -PropertyNames @('NetworkSecurityGroupId')
    }

    if ($effectiveNsgId) {
        $nicParameters.NetworkSecurityGroupId = $effectiveNsgId
    }

    if ($SourceNic -and $SourceNic.EnableAcceleratedNetworking) {
        $nicParameters.EnableAcceleratedNetworking = $true
    }

    if ($SourceNic -and $SourceNic.EnableIPForwarding) {
        $null = Add-SupportedParameter -Splat $nicParameters -CmdletName 'New-AzNetworkInterface' -ParameterName 'EnableIPForwarding' -Value $true
    }

    $effectivePrivateIp = $null
    if ($ReuseSourcePrivateIp) {
        $effectivePrivateIp = Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('PrivateIpAddress')
        if ([string]::IsNullOrWhiteSpace($effectivePrivateIp)) {
            throw 'The manifest does not record a source private IP address to reuse.'
        }
    }
    elseif ($OverridePrivateIpAddress) {
        $effectivePrivateIp = $OverridePrivateIpAddress
    }

    if ($effectivePrivateIp) {
        $nicParameters.PrivateIpAddress = $effectivePrivateIp
    }

    $effectivePublicIpId = $null
    if ($ReuseSourcePublicIp) {
        $effectivePublicIpId = Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('PublicIpAddressId')
        if ([string]::IsNullOrWhiteSpace($effectivePublicIpId)) {
            throw 'The manifest does not record a source public IP address to reuse.'
        }
    }
    elseif ($OverridePublicIpAddressId) {
        $effectivePublicIpId = $OverridePublicIpAddressId
    }

    if ($effectivePublicIpId) {
        $nicParameters.PublicIpAddressId = $effectivePublicIpId
    }

    if ($SourceNic -and $SourceNic.DnsServers -and @($SourceNic.DnsServers).Count -gt 0) {
        $null = Add-SupportedParameter -Splat $nicParameters -CmdletName 'New-AzNetworkInterface' -ParameterName 'DnsServer' -Value @($SourceNic.DnsServers)
    }

    $nic = New-AzNetworkInterface @nicParameters -ErrorAction Stop
    Register-CreatedResource -Type 'NetworkInterface' -Name $nic.Name -Id $nic.Id

    # Memberships live on the IP configuration and are not settable through
    # New-AzNetworkInterface's simple parameter set, so they are applied as a second update.
    $needsUpdate = $false
    $ipConfiguration = @($nic.IpConfigurations) | Select-Object -First 1

    $asgIds = @(Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('ApplicationSecurityGroupIds') -Default @())
    if ($asgIds.Count -gt 0) {
        $asgObjects = @()
        foreach ($asgId in $asgIds) {
            try {
                $asgObjects += Get-AzApplicationSecurityGroup -ResourceId $asgId -ErrorAction Stop
            }
            catch {
                Write-Warning ("Unable to resolve application security group '{0}'. {1}" -f $asgId, $_.Exception.Message)
            }
        }

        if ($asgObjects.Count -gt 0) {
            $ipConfiguration.ApplicationSecurityGroups = $asgObjects
            $needsUpdate = $true
        }
    }

    $lbPoolIds = @(Get-ObjectPropertyValue -InputObject $sourcePrimaryIp -PropertyNames @('LoadBalancerBackendAddressPoolIds') -Default @())
    if ($lbPoolIds.Count -gt 0) {
        $pools = @()
        foreach ($poolId in $lbPoolIds) {
            $pools += (New-Object Microsoft.Azure.Commands.Network.Models.PSBackendAddressPool -Property @{ Id = $poolId })
        }

        $ipConfiguration.LoadBalancerBackendAddressPools = $pools
        $needsUpdate = $true
    }

    if ($needsUpdate) {
        try {
            $nic = Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop
            Write-Ok 'Reapplied application security group and load balancer pool membership to the new NIC.'
        }
        catch {
            Write-Warning ("Could not reapply NIC memberships. {0}" -f $_.Exception.Message)
            Add-ManualChecklistItem 'Reattach the new NIC to its application security groups and load balancer/application gateway backend pools by hand.'
        }
    }

    return $nic
}

function Get-DetachedSourceNic {
    <#
    .SYNOPSIS
        Returns the source VM's primary NIC, verifying it is not still attached to a VM.

    .DESCRIPTION
        Reusing the original NIC is the only way to keep load balancer membership,
        application security group membership and the private IP without any re-plumbing,
        but a NIC can belong to exactly one VM. The source VM has to be deleted first -
        deallocating it is not enough.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$NicId
    )

    $nic = Get-AzNetworkInterface -ResourceId $NicId -ErrorAction Stop
    if ($nic.VirtualMachine -and $nic.VirtualMachine.Id) {
        throw ("NIC '{0}' is still attached to VM '{1}'. Delete that VM (its disks are retained) before reusing its NIC, or drop -ReuseSourceNic and create a new NIC instead." -f $nic.Name, (Get-ResourceNameFromResourceId -ResourceId $nic.VirtualMachine.Id))
    }

    return $nic
}

#endregion


#region Post-create appliers

function Restore-BootDiagnostics {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName
    )

    $bootDiagnostics = Get-ObjectPropertyValue -InputObject $Manifest.SourceVm -PropertyNames @('BootDiagnostics')
    if (-not $bootDiagnostics -or -not $bootDiagnostics.Enabled) {
        return $false
    }

    try {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
        $parameters = @{ VM = $vm; Enable = $true }

        $storageUri = Get-ObjectPropertyValue -InputObject $bootDiagnostics -PropertyNames @('StorageUri')
        if ($storageUri -and $storageUri -match '(?i)https://([^.]+)\.blob\.') {
            $storageAccountName = $Matches[1]
            $storageAccount = Get-AzStorageAccount -ErrorAction SilentlyContinue | Where-Object { $_.StorageAccountName -eq $storageAccountName } | Select-Object -First 1
            if ($storageAccount) {
                $parameters.ResourceGroupName = $storageAccount.ResourceGroupName
                $parameters.StorageAccountName = $storageAccountName
            }
            else {
                Write-Warning ("Boot diagnostics storage account '{0}' was not found; enabling managed boot diagnostics instead." -f $storageAccountName)
            }
        }

        $vm = Set-AzVMBootDiagnostic @parameters -ErrorAction Stop
        $null = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop
        Write-Ok 'Boot diagnostics enabled.'
        return $true
    }
    catch {
        Write-Warning ("Unable to configure boot diagnostics. {0}" -f $_.Exception.Message)
        Add-ManualChecklistItem 'Enable boot diagnostics on the replacement VM.'
        return $false
    }
}

function Restore-VmExtensions {
    <#
    .SYNOPSIS
        Re-adds the source VM's extensions to the replacement.

    .DESCRIPTION
        Extension binaries already exist on the restored OS disk, but the Azure child
        resources do not, so Azure believes no extension is installed while the agent on
        disk keeps running. Re-adding each extension reconciles the two.

        Protected settings cannot be read from Azure, so any extension that needs a secret
        is reported for manual reinstallation rather than being re-added without it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $section = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('Extensions')
    if (-not $section -or $section.Status -ne 'Captured') {
        return @()
    }

    # Extensions that must NOT be re-added by hand, each for a specific reason.
    $ownedByAnotherService = @{
        'Microsoft.SqlServer.Management'      = 'installed and owned by the SQL VM resource provider during registration'
        'Microsoft.Azure.RecoveryServices'    = 'installed and owned by the Recovery Services vault when backup is enabled'
    }

    # Re-running these against a guest that is already joined breaks the existing trust
    # relationship rather than being a harmless no-op.
    $unsafeToReapply = @{
        'JsonADDomainExtension' = 'the restored OS disk is already domain-joined; re-running the domain-join extension is not idempotent and can break the secure channel'
        'AADLoginForWindows'    = 'a stale Entra device object with the same hostname causes sign-in failure 0x801c0083'
        'AzureDiskEncryption'   = 'disk encryption state travels on the disk and must be reconciled deliberately, not re-pushed'
    }

    $applied = @()
    foreach ($extension in @($section.Data)) {
        $name = $extension.Name

        if ($ownedByAnotherService.ContainsKey('' + $extension.Publisher)) {
            Write-Detail ("Skipping extension '{0}': {1}." -f $name, $ownedByAnotherService['' + $extension.Publisher])
            continue
        }

        $typeName = '' + $extension.ExtensionType
        if ($unsafeToReapply.ContainsKey($typeName)) {
            Write-Gap ("Not re-adding extension '{0}': {1}." -f $name, $unsafeToReapply[$typeName])
            Add-ManualChecklistItem ("Decide deliberately whether to reinstate extension '{0}' ({1}); it was skipped because {2}." -f $name, $typeName, $unsafeToReapply[$typeName])
            continue
        }

        if ($extension.HasProtectedSettings) {
            Add-ManualChecklistItem ("Reinstall extension '{0}' ({1}) manually: it has protected settings (a password, key or workspace key) that Azure will not disclose." -f $name, $extension.Publisher)
            Write-Gap ("Extension '{0}' needs manual reinstallation (protected settings)." -f $name)
            continue
        }

        try {
            $parameters = @{
                ResourceGroupName  = $ResourceGroupName
                VMName             = $VmName
                Name               = $name
                Publisher          = $extension.Publisher
                ExtensionType      = $extension.ExtensionType
                TypeHandlerVersion = $extension.TypeHandlerVersion
                Location           = $Location
                ErrorAction        = 'Stop'
            }

            $settings = ConvertTo-PlainHashtable -InputObject $extension.PublicSettings
            if ($settings -and $settings.Count -gt 0) {
                $parameters.Settings = $settings
            }

            if ($extension.EnableAutomaticUpgrade) {
                $null = Add-SupportedParameter -Splat $parameters -CmdletName 'Set-AzVMExtension' -ParameterName 'EnableAutomaticUpgrade' -Value $true
            }

            $null = Set-AzVMExtension @parameters
            $applied += $name
            Write-Ok ("Extension '{0}' re-added." -f $name)
        }
        catch {
            Write-Warning ("Unable to re-add extension '{0}'. {1}" -f $name, $_.Exception.Message)
            Add-ManualChecklistItem ("Re-add extension '{0}' manually." -f $name)

            # Azure refuses to install any further extension on a VM that already has one
            # in a failed provisioning state, so continuing would just manufacture a run of
            # identical failures that hide this first, real one.
            Add-ManualChecklistItem 'Extension installation stopped after the first failure, because Azure blocks new extensions on a VM that has one in a failed state. Clear the failed extension, then re-add the rest.'
            break
        }
    }

    if ($applied.Count -gt 0) {
        Add-ManualChecklistItem 'Azure Monitor Agent carries cached state on the restored OS disk and Microsoft does not support cloning a machine that has it installed. If AMA was re-added, verify data is actually flowing (Heartbeat | where Category == "Azure Monitor Agent") and force a clean reinstall if not - a healthy-looking agent that collects nothing is the most likely silent failure of this migration.'
    }

    return @($applied)
}

function Restore-DataCollectionRuleAssociations {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmResourceId
    )

    $section = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('DataCollectionRuleAssociations')
    if (-not $section -or $section.Status -ne 'Captured') {
        return @()
    }

    $applied = @()
    foreach ($association in @($section.Data)) {
        # Associations created on behalf of Defender for Cloud, VM Insights, Change
        # Tracking or Sentinel are managed by that service. Re-creating them by hand
        # conflicts with the owner; re-enabling the feature is the correct fix.
        if (Get-ObjectPropertyValue -InputObject $association -PropertyNames @('ProvisionedBy')) {
            Write-Gap ("Data collection rule association '{0}' is managed by another service; re-enable that feature rather than recreating the association." -f $association.Name)
            Add-ManualChecklistItem ("Re-enable the Azure Monitor feature that owns data collection rule association '{0}' (Defender for Cloud, VM Insights, Change Tracking or Sentinel) so it recreates the association itself." -f $association.Name)
            continue
        }

        try {
            $parameters = @{
                TargetResourceId = $TargetVmResourceId
                AssociationName  = $association.Name
                ErrorAction      = 'Stop'
            }

            if ($association.DataCollectionRuleId) {
                $parameters.RuleId = $association.DataCollectionRuleId
            }
            elseif ($association.DataCollectionEndpointId) {
                $parameters.DataCollectionEndpointId = $association.DataCollectionEndpointId
            }
            else {
                continue
            }

            $null = New-AzDataCollectionRuleAssociation @parameters
            $applied += $association.Name
            Write-Ok ("Data collection rule association '{0}' recreated." -f $association.Name)
        }
        catch {
            Write-Warning ("Unable to recreate data collection rule association '{0}'. {1}" -f $association.Name, $_.Exception.Message)
            Add-ManualChecklistItem ("Recreate the data collection rule association '{0}' against the new VM." -f $association.Name)
        }
    }

    return @($applied)
}

function Restore-VmBackupProtection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName
    )

    $section = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('BackupProtection')
    if (-not $section) {
        return $false
    }

    if ($section.Status -eq 'Failed') {
        Add-ManualChecklistItem 'Backup protection could not be READ during capture, so it has not been re-enabled. Check the source VM''s vault and protect the new VM manually.'
        return $false
    }

    if ($section.Status -ne 'Captured' -or -not $section.Data -or -not $section.Data.IsProtected) {
        return $false
    }

    $vaultId = $section.Data.VaultId
    $policyName = $section.Data.PolicyName

    if ([string]::IsNullOrWhiteSpace($vaultId) -or [string]::IsNullOrWhiteSpace($policyName)) {
        Write-Warning 'The manifest records backup protection but not both a vault ID and a policy name; skipping.'
        Add-ManualChecklistItem 'Re-enable Azure Backup on the replacement VM by hand.'
        return $false
    }

    try {
        # -VaultId scopes every Recovery Services call, and works when the vault lives in a
        # different resource group or subscription from the VM, which is common.
        $policy = Get-AzRecoveryServicesBackupProtectionPolicy -Name $policyName -VaultId $vaultId -ErrorAction Stop
        $null = Enable-AzRecoveryServicesBackupProtection -Policy $policy -Name $TargetVmName -ResourceGroupName $TargetResourceGroupName -VaultId $vaultId -ErrorAction Stop
        Write-Ok ("Azure Backup enabled with policy '{0}'." -f $policyName)
        Add-ManualChecklistItem ("Backup history does NOT transfer. The old recovery points stay under the source VM's backup item in vault '{0}'; keep that item (stop protection with data retained) for as long as you need those restore points." -f $section.Data.VaultName)
        return $true
    }
    catch {
        Write-Warning ("Unable to enable Azure Backup for '{0}'. {1}" -f $TargetVmName, $_.Exception.Message)
        Add-ManualChecklistItem ("Enable Azure Backup on '{0}' using policy '{1}' in vault '{2}'." -f $TargetVmName, $policyName, $section.Data.VaultName)
        return $false
    }
}

function Restore-MaintenanceAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmResourceId,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation
    )

    $section = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('MaintenanceAssignments')
    if (-not $section -or $section.Status -ne 'Captured') {
        Add-ManualChecklistItem 'No direct VM-scoped maintenance assignment was replayed. Subscription-, resource-group- and tag-scoped Azure Update Manager schedules are not visible from the VM and must be checked separately - a tag-scoped schedule will only pick the new VM up if its tags match.'
        return @()
    }

    $applied = @()
    foreach ($assignment in @($section.Data)) {
        $name = Get-ObjectPropertyValue -InputObject $assignment -PropertyNames @('ConfigurationAssignmentName', 'Name')
        $configurationId = Get-ObjectPropertyValue -InputObject $assignment -PropertyNames @('MaintenanceConfigurationId')

        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($configurationId)) {
            Write-Warning 'Skipping a maintenance assignment with an incomplete record.'
            continue
        }

        try {
            # The assignment is created at the TARGET VM's location, not the location
            # recorded against the source assignment.
            $null = New-AzConfigurationAssignment -ResourceId $TargetVmResourceId -ConfigurationAssignmentName $name -MaintenanceConfigurationId $configurationId -Location $TargetLocation -ErrorAction Stop
            $applied += $name
            Write-Ok ("Maintenance assignment '{0}' applied." -f $name)
        }
        catch {
            Write-Warning ("Unable to apply maintenance assignment '{0}'. {1}" -f $name, $_.Exception.Message)
            Add-ManualChecklistItem ("Reapply the Azure Update Manager maintenance assignment '{0}' ({1}) to the new VM." -f $name, $configurationId)
        }
    }

    $expected = @($section.Data).Count
    if ($applied.Count -lt $expected) {
        Add-ManualChecklistItem ("Only {0} of {1} maintenance assignments were reapplied." -f $applied.Count, $expected)
    }

    return @($applied)
}

function Restore-SqlVirtualMachineRegistration {
    <#
    .SYNOPSIS
        Re-registers the replacement VM with the SQL IaaS extension and reapplies SQL
        licensing and management settings.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmName,

        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$TargetLocation
    )

    $section = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('SqlVirtualMachine')
    if (-not $section -or $section.Status -ne 'Captured' -or -not $section.Data) {
        return $false
    }

    $sql = $section.Data
    if (-not $sql.IsRegistered) {
        return $false
    }

    $parameters = @{
        ResourceGroupName = $TargetResourceGroupName
        Name              = $TargetVmName
        Location          = $TargetLocation
        ErrorAction       = 'Stop'
    }

    # New-AzSqlVM takes the SHORT parameter names even though the returned model exposes
    # the Sql-prefixed property names the capture script reads.
    $null = Add-SupportedParameter -Splat $parameters -CmdletName 'New-AzSqlVM' -ParameterName 'LicenseType' -Value $sql.LicenseType
    $null = Add-SupportedParameter -Splat $parameters -CmdletName 'New-AzSqlVM' -ParameterName 'Sku' -Value $sql.Sku
    $null = Add-SupportedParameter -Splat $parameters -CmdletName 'New-AzSqlVM' -ParameterName 'Offer' -Value $sql.Offer
    $null = Add-SupportedParameter -Splat $parameters -CmdletName 'New-AzSqlVM' -ParameterName 'SqlManagementType' -Value $sql.SqlManagementType
    $null = Add-SupportedParameter -Splat $parameters -CmdletName 'New-AzSqlVM' -ParameterName 'EnableAutomaticUpgrade' -Value $sql.EnableAutomaticUpgrade

    try {
        $existing = Get-AzSqlVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue
        if ($existing) {
            # The SQL IaaS agent already on the restored OS disk can self-register on first
            # boot, so an existing registration is expected rather than an error.
            $updateParameters = @{
                ResourceGroupName = $TargetResourceGroupName
                Name              = $TargetVmName
                ErrorAction       = 'Stop'
            }

            foreach ($key in @('LicenseType', 'Sku', 'Offer', 'SqlManagementType', 'EnableAutomaticUpgrade')) {
                if ($parameters.ContainsKey($key)) {
                    $updateParameters[$key] = $parameters[$key]
                }
            }

            $null = Update-AzSqlVM @updateParameters
            Write-Ok 'Existing SQL VM registration updated with the source licensing and management settings.'
        }
        else {
            $null = New-AzSqlVM @parameters
            Write-Ok 'SQL VM registration created.'
        }
    }
    catch {
        Write-Warning ("Unable to configure the SQL VM registration. {0}" -f $_.Exception.Message)
        Add-ManualChecklistItem ("Register the replacement VM with the SQL IaaS extension and set the SQL license type to '{0}'." -f $sql.LicenseType)
        return $false
    }

    # Verify rather than trust: a SQL VM that silently lost its Azure Hybrid Benefit
    # registration is an expensive failure to discover later.
    $verify = Get-AzSqlVM -ResourceGroupName $TargetResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue
    if (-not $verify) {
        Add-ManualChecklistItem 'SQL VM registration reported success but the resource cannot be read back. Verify it in the portal.'
        return $false
    }

    $appliedLicense = Get-ObjectPropertyValue -InputObject $verify -PropertyNames @('SqlServerLicenseType', 'LicenseType')
    if ($sql.LicenseType -and $appliedLicense -ne $sql.LicenseType) {
        Add-ManualChecklistItem ("SQL license type on the new VM is '{0}' but the source was '{1}'. Correct it or you may be billed at pay-as-you-go rates." -f $appliedLicense, $sql.LicenseType)
    }

    foreach ($settingName in @('AutoPatchingSettings', 'AutoBackupSettings', 'ServerConfigurationsManagementSettings', 'StorageConfigurationSettings', 'KeyVaultCredentialSettings', 'AssessmentSettings')) {
        if (Get-ObjectPropertyValue -InputObject $sql -PropertyNames @($settingName)) {
            Add-ManualChecklistItem ("SQL VM {0} were captured but are NOT reapplied automatically. Compare them against the manifest and set them in the portal or with Update-AzSqlVM." -f $settingName)
        }
    }

    return $true
}

#endregion


#region Image-first placeholder and OS disk swap

function New-PlaceholderVmFromImage {
    <#
    .SYNOPSIS
        Creates a throwaway VM from the source VM's original platform image, purely so the
        replacement has a real osProfile.

    .DESCRIPTION
        This is the whole trick behind ImageFirstSwap. Azure will not accept an osProfile on
        a VM created by attaching a specialized OS disk, and it will not let one be added
        afterwards, so a VM built that way can never carry guest patch settings. A VM built
        from an image does get an osProfile - and that osProfile survives when the OS disk is
        later swapped underneath it, because osProfile belongs to the VM model rather than to
        the disk.

        The local administrator account created here is discarded along with the placeholder
        OS disk. It never exists in the guest that ends up running, because that guest comes
        from the restored disk.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [hashtable]$ConfigParameters,

        [Parameter(Mandatory = $true)]
        [string]$NicId,

        [Parameter(Mandatory = $true)]
        [int]$OsDiskSizeGB,

        [Parameter(Mandatory = $true)]
        [string]$OsDiskStorageAccountType,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location
    )

    $sourceVm = $Manifest.SourceVm
    $image = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('ImageReference')
    if (-not $image -or [string]::IsNullOrWhiteSpace('' + $image.Publisher)) {
        throw 'ImageFirstSwap needs the original image reference of the source VM, and the manifest does not have one. That normally means the source VM was itself built from a specialized disk, so it has no image provenance to reproduce. Use -RestoreMode AttachOsDisk and accept that scheduled patching cannot be re-established.'
    }

    $osProfileManifest = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('OsProfile')
    $windowsConfiguration = Get-ObjectPropertyValue -InputObject $osProfileManifest -PropertyNames @('WindowsConfiguration')

    $vmConfig = New-AzVMConfig @ConfigParameters
    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $NicId -Primary

    # A throwaway credential for a disk that is about to be thrown away. Generated rather
    # than prompted so the run stays unattended, and never persisted anywhere.
    $randomBytes = New-Object 'System.Byte[]' 24
    ([System.Security.Cryptography.RandomNumberGenerator]::Create()).GetBytes($randomBytes)
    $placeholderPassword = ConvertTo-SecureString -String ('Pl@ce' + [Convert]::ToBase64String($randomBytes) + '9zQ!') -AsPlainText -Force
    $placeholderCredential = New-Object System.Management.Automation.PSCredential('phadmin', $placeholderPassword)
    $placeholderComputerName = 'ph' + (((New-BatchTimestamp) -replace '[^0-9]', '').Substring(0, 12))

    $osParameters = @{
        VM           = $vmConfig
        ComputerName = $placeholderComputerName
        Credential   = $placeholderCredential
    }

    if (('' + $sourceVm.OsType) -eq 'Linux') {
        $osParameters.Linux = $true
    }
    else {
        $osParameters.Windows = $true

        # EnableAutomaticUpdates can only be set at create time, and it gates which patchMode
        # transitions are legal afterwards. Getting it wrong here would permanently lock the
        # VM out of the source's patch mode, so it is matched exactly.
        if ($windowsConfiguration) {
            $null = Add-SupportedParameter -Splat $osParameters -CmdletName 'Set-AzVMOperatingSystem' -ParameterName 'EnableAutoUpdate' -Value ([bool]$windowsConfiguration.EnableAutomaticUpdates) -AllowFalse
            $null = Add-SupportedParameter -Splat $osParameters -CmdletName 'Set-AzVMOperatingSystem' -ParameterName 'TimeZone' -Value $windowsConfiguration.TimeZone
            $null = Add-SupportedParameter -Splat $osParameters -CmdletName 'Set-AzVMOperatingSystem' -ParameterName 'ProvisionVMAgent' -Value ([bool]$windowsConfiguration.ProvisionVMAgent) -AllowFalse

            if ($windowsConfiguration.PatchSettings -and $windowsConfiguration.PatchSettings.PatchMode) {
                $null = Add-SupportedParameter -Splat $osParameters -CmdletName 'Set-AzVMOperatingSystem' -ParameterName 'PatchMode' -Value $windowsConfiguration.PatchSettings.PatchMode
                $null = Add-SupportedParameter -Splat $osParameters -CmdletName 'Set-AzVMOperatingSystem' -ParameterName 'AssessmentMode' -Value $windowsConfiguration.PatchSettings.AssessmentMode
            }
        }
    }

    $vmConfig = Set-AzVMOperatingSystem @osParameters

    $sourceImageParameters = @{ VM = $vmConfig }
    if ($image.Id) {
        $sourceImageParameters.Id = $image.Id
    }
    else {
        $sourceImageParameters.PublisherName = $image.Publisher
        $sourceImageParameters.Offer         = $image.Offer
        $sourceImageParameters.Skus          = $image.Sku
        if ($image.Version) { $sourceImageParameters.Version = $image.Version } else { $sourceImageParameters.Version = 'latest' }
    }

    $vmConfig = Set-AzVMSourceImage @sourceImageParameters

    # The swap requires both OS disks to be the same size, so the placeholder disk is created
    # at the restored disk's size rather than at the image default.
    $vmConfig = Set-AzVMOSDisk -VM $vmConfig -Name ("{0}-placeholder-osdisk" -f $ConfigParameters.VMName) -CreateOption FromImage -DiskSizeInGB $OsDiskSizeGB -StorageAccountType $OsDiskStorageAccountType

    $planInfo = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('Plan')
    if ($planInfo -and $planInfo.Name) {
        $vmConfig = Set-AzVMPlan -VM $vmConfig -Name $planInfo.Name -Publisher $planInfo.Publisher -Product $planInfo.Product -ErrorAction Stop
    }

    Write-Detail ("Creating the placeholder VM from image {0}/{1}/{2}." -f $image.Publisher, $image.Offer, $image.Sku)
    $null = New-AzVM -ResourceGroupName $ResourceGroupName -Location $Location -VM $vmConfig -ErrorAction Stop

    $placeholder = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $ConfigParameters.VMName -ErrorAction Stop
    Register-CreatedResource -Type 'VirtualMachine' -Name $placeholder.Name -Id $placeholder.Id
    Register-CreatedResource -Type 'Disk (placeholder OS)' -Name $placeholder.StorageProfile.OsDisk.Name -Id $placeholder.StorageProfile.OsDisk.ManagedDisk.Id

    $appliedPatchMode = 'n/a'
    if ($placeholder.OSProfile -and $placeholder.OSProfile.WindowsConfiguration) {
        $appliedPatchMode = Get-ObjectPropertyValue -InputObject $placeholder.OSProfile.WindowsConfiguration.PatchSettings -PropertyNames @('PatchMode') -Default 'n/a'
    }

    Write-Ok ("Placeholder VM created with a real osProfile (patch mode '{0}')." -f $appliedPatchMode)
    return $placeholder
}

function Invoke-OsDiskSwap {
    <#
    .SYNOPSIS
        Deallocates the VM and swaps its OS disk for the restored one.

    .DESCRIPTION
        Swapping the OS disk on an existing VM is a supported operation that does not require
        deleting and recreating the VM, which is exactly why it can be used to graft the
        restored guest onto a VM model that already has a valid osProfile.

        Both disks must be the same size, and the VM must be deallocated for the swap.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [object]$RestoredOsDisk
    )

    Write-Detail 'Deallocating the placeholder VM so its OS disk can be swapped.'
    $null = Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force -ErrorAction Stop

    $powerState = Get-VmPowerState -ResourceGroupName $ResourceGroupName -Name $VmName
    if ($powerState -ne 'PowerState/deallocated') {
        throw ("The placeholder VM must be deallocated before its OS disk can be swapped, but it reports '{0}'." -f $powerState)
    }

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
    $placeholderDiskId = $vm.StorageProfile.OsDisk.ManagedDisk.Id
    $placeholderDiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB

    if ($placeholderDiskSize -and $RestoredOsDisk.DiskSizeGB -and ([int]$placeholderDiskSize -ne [int]$RestoredOsDisk.DiskSizeGB)) {
        throw ("An OS disk swap requires both disks to be the same size. The placeholder disk is {0} GB and the restored disk is {1} GB." -f $placeholderDiskSize, $RestoredOsDisk.DiskSizeGB)
    }

    Write-Detail ("Swapping in the restored OS disk '{0}'." -f $RestoredOsDisk.Name)
    $vm = Set-AzVMOSDisk -VM $vm -ManagedDiskId $RestoredOsDisk.Id -Name $RestoredOsDisk.Name -ErrorAction Stop
    $null = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop

    Write-Ok 'OS disk swapped. The VM keeps the osProfile it was created with, including its patch settings.'
    return $placeholderDiskId
}

function Add-DataDisksToExistingVm {
    <#
    .SYNOPSIS
        Attaches the restored data disks to an already-created VM.

    .DESCRIPTION
        Used by ImageFirstSwap, where the VM already exists by the time the data disks are
        ready to attach. LUNs are preserved exactly, because the guest's drive letters and
        SQL Server's file paths are bound to them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$DataDisk,

        [Parameter(Mandatory = $true)]
        [string]$TargetVmSize
    )

    if ($DataDisk.Count -eq 0) {
        return
    }

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop

    foreach ($item in ($DataDisk | Sort-Object -Property Lun)) {
        $parameters = @{
            VM            = $vm
            Name          = $item.Disk.Name
            ManagedDiskId = $item.Disk.Id
            Lun           = $item.Lun
            CreateOption  = 'Attach'
        }

        if ($item.Caching) { $parameters.Caching = $item.Caching }
        if ($item.WriteAcceleratorEnabled -and $TargetVmSize -like 'Standard_M*') {
            $null = Add-SupportedParameter -Splat $parameters -CmdletName 'Add-AzVMDataDisk' -ParameterName 'WriteAccelerator' -Value $true
        }

        $vm = Add-AzVMDataDisk @parameters
    }

    $null = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -ErrorAction Stop
    Write-Ok ("Attached {0} data disk(s) at their original LUNs." -f $DataDisk.Count)
}

#endregion


#region Preflight

function New-PreflightReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [Parameter(Mandatory = $true)]
        [object]$Plan,

        [Parameter(Mandatory = $true)]
        [object]$SkuCapability
    )

    $blockers = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    $sourceVm = $Manifest.SourceVm
    $capture = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('Capture')

    # --- Consistency of the captured set
    if ($capture) {
        if (-not $capture.SnapshotsCreated) {
            $blockers.Add('This manifest was written with -SkipSnapshots and has no disk sources. Recapture with snapshots before restoring.')
        }

        if (-not $capture.IsConsistent) {
            $warnings.Add(("The snapshot set was captured in '{0}' mode with the VM in state '{1}'. The disks may not share a point in time; SQL Server may fail to recover or come up logically inconsistent." -f $capture.ConsistencyMode, $capture.PowerStateAtCapture))
        }
    }

    # --- The whole point of the migration
    if (-not $SkuCapability.HasTempDisk) {
        $blockers.Add(("Target size '{0}' has no local temporary disk (MaxResourceVolumeMB = {1}). This migration exists to obtain a temp disk; choose a size with a 'd' in the family, such as Standard_E8ds_v5." -f $Plan.VmSize, $SkuCapability.TempDiskSizeMB))
    }
    else {
        $warnings.Add(("Target size '{0}' provides a {1} GB local temp disk. Windows persists its drive-letter-to-volume bindings in HKLM\SYSTEM\MountedDevices on the OS disk, which is carried over intact, so the new temp disk is normally given the first FREE letter rather than displacing an existing volume. Verify the letters on first boot anyway, and make sure no page file is configured on a letter that could move." -f $Plan.VmSize, [math]::Round($SkuCapability.TempDiskSizeMB / 1024, 0)))
        $warnings.Add('SQL Server TempDB on the ephemeral disk: the temp disk is wiped on every deallocate, so the TempDB folder disappears and SQL Server will not start (error 5123/17204). A startup task must recreate the folder with the right ACLs before the SQL Server service starts. See the README.')
        if ($Plan.VmSize -match '_[A-Z]*\d+[a-z]*d[a-z]*_v([6-9]|\d\d)') {
            $warnings.Add(("Target size '{0}' is a v6-or-later family. Their local disks are RAW, unformatted NVMe with no drive letter on every boot, unlike v5 sizes whose temp disk arrives pre-formatted NTFS labelled 'Temporary Storage'. A v6 target needs a guest startup script to initialize, format and letter the temp disk before SQL Server starts." -f $Plan.VmSize))
        }
    }

    # --- Region and zone availability
    if ($SkuCapability.RegionRestricted) {
        $blockers.Add(("Target size '{0}' is restricted in region '{1}' for this subscription." -f $Plan.VmSize, $Plan.Location))
    }

    if ($Plan.Zone.Count -gt 0) {
        $zone = $Plan.Zone[0]
        if ($SkuCapability.Zones.Count -gt 0 -and $SkuCapability.Zones -notcontains $zone) {
            $blockers.Add(("Target size '{0}' is not offered in zone {1} of region '{2}'." -f $Plan.VmSize, $zone, $Plan.Location))
        }

        if ($SkuCapability.RestrictedZones -contains $zone) {
            $blockers.Add(("Target size '{0}' is restricted in zone {1}." -f $Plan.VmSize, $zone))
        }
    }

    # --- Disk count and capability
    $dataDiskCount = @($Manifest.Snapshots.DataDisks).Count
    if ($SkuCapability.MaxDataDiskCount -and $dataDiskCount -gt [int]$SkuCapability.MaxDataDiskCount) {
        $blockers.Add(("The source VM has {0} data disks but target size '{1}' supports only {2}." -f $dataDiskCount, $Plan.VmSize, $SkuCapability.MaxDataDiskCount))
    }

    $premiumDisks = @($Manifest.Disks | Where-Object { ('' + $_.SkuName) -like 'Premium*' })
    if ($premiumDisks.Count -gt 0 -and -not $SkuCapability.PremiumIO) {
        $blockers.Add(("The source VM uses premium disks but target size '{0}' does not support premium storage." -f $Plan.VmSize))
    }

    if ((Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('EncryptionAtHost')) -and -not $SkuCapability.EncryptionAtHostSupported) {
        $blockers.Add(("The source VM uses encryption at host but target size '{0}' does not support it." -f $Plan.VmSize))
    }

    if ((Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('UltraSSDEnabled')) -and -not $SkuCapability.UltraSSDAvailable) {
        $warnings.Add(("The source VM had UltraSSD enabled but target size '{0}' does not offer it in this zone; the capability will not be set." -f $Plan.VmSize))
    }

    $sourceSecurityType = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('SecurityType')
    if ($sourceSecurityType -eq 'TrustedLaunch' -and $SkuCapability.TrustedLaunchDisabled) {
        $blockers.Add(("The source VM uses Trusted Launch but target size '{0}' does not support it." -f $Plan.VmSize))
    }

    if ($sourceSecurityType -eq 'TrustedLaunch' -or $sourceSecurityType -eq 'ConfidentialVM') {
        # The VM Guest State blob holds the Secure Boot databases and vTPM state, and its
        # lifecycle is tied to the OS disk. A disk restored from a snapshot gets a NEW VMGS
        # unless the security data is carried across explicitly, which can invalidate
        # anything sealed to the vTPM - BitLocker being the one that locks people out.
        $warnings.Add(("The source VM uses {0}. The VM Guest State blob (Secure Boot databases and vTPM state) is tied to the OS disk, and a disk rebuilt from a snapshot receives a new one. Anything sealed to the vTPM - BitLocker recovery state above all - can be invalidated. Confirm you hold the BitLocker recovery keys before cutover." -f $sourceSecurityType))
        $warnings.Add('The replacement must keep the same securityType, Secure Boot and vTPM settings as the source, or re-protecting it in the same Recovery Services vault later can fail with UserErrorMigrationFromTrustedLaunchVMToNonTrustedVMNotAllowed.')
    }

    # --- Disk controller: a real trap moving onto v5/v6 families
    $sourceController = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('DiskControllerType')
    $supportedControllers = '' + $SkuCapability.DiskControllerTypes
    if ($sourceController -and $supportedControllers -and ($supportedControllers -notlike ("*" + $sourceController + "*"))) {
        $warnings.Add(("The source VM used disk controller '{0}' but target size '{1}' advertises '{2}'. The guest OS must have the matching drivers or the VM will not boot." -f $sourceController, $Plan.VmSize, $supportedControllers))
    }

    if ($SkuCapability.MaxDataDiskCount -and -not $sourceController -and $supportedControllers -eq 'NVMe') {
        $blockers.Add(("Target size '{0}' supports only the NVMe disk controller, but the source VM was provisioned with SCSI. The guest OS needs NVMe driver support before it will boot on this size." -f $Plan.VmSize))
    }

    # --- Write accelerator
    $writeAcceleratorDisks = @($Manifest.Disks | Where-Object { $_.WriteAcceleratorEnabled })
    if ($writeAcceleratorDisks.Count -gt 0 -and $Plan.VmSize -notlike 'Standard_M*') {
        $warnings.Add(("{0} disk(s) use Write Accelerator, which is only supported on M-series sizes. It will not be applied to '{1}'." -f $writeAcceleratorDisks.Count, $Plan.VmSize))
    }

    # --- Backup identity. Azure Backup keys an IaaS VM item on subscription + resource
    # group + VM NAME, not on the VM's unique ID or its disk IDs.
    $backupSection = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('BackupProtection')
    if ($backupSection -and $backupSection.Status -eq 'Captured' -and $backupSection.Data -and $backupSection.Data.IsProtected) {
        $sameIdentity = ($Plan.VmName -eq $sourceVm.Name) -and ($Plan.ResourceGroupName -eq $sourceVm.ResourceGroupName) -and ($Plan.SubscriptionId -eq $sourceVm.SubscriptionId)
        if (-not $sameIdentity) {
            $warnings.Add(("BACKUP HISTORY WILL NOT TRANSFER. Azure Backup identifies a VM by subscription + resource group + NAME. The replacement is '{0}' but the source is '{1}', so the new VM becomes a separate backup item with no history and takes a fresh full initial backup, while the source VM's existing recovery points remain under the old item - still restorable, still billed. Recovery points only reattach automatically when the replacement has the SAME name in the SAME resource group and subscription." -f $Plan.VmName, $sourceVm.Name))
        }
        else {
            $warnings.Add('The replacement VM has the same name, resource group and subscription as the source, so the existing Recovery Services vault item and its recovery points should reattach automatically. Do NOT stop protection with data deletion at any point.')
        }
    }

    # --- Private DNS auto-registration follows the VM NAME, not the IP.
    if ($Plan.VmName -ne $sourceVm.Name) {
        $warnings.Add(("Private DNS auto-registration keys off the VM name, not the address. Renaming '{0}' to '{1}' changes the auto-registered A record even though the IP is preserved. Anything resolving the old name needs a manual record or a CNAME." -f $sourceVm.Name, $Plan.VmName))
    }

    # --- Marketplace plan
    if (Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('Plan')) {
        $warnings.Add('The source VM has a marketplace purchase plan. It is replayed onto the new VM; if creation fails with a plan or terms error, accept the marketplace terms for that offer in the target subscription first.')
    }

    # --- osProfile-derived settings that a specialized disk cannot carry
    $osProfile = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('OsProfile')
    $patchSettings = $null
    if ($osProfile -and $osProfile.WindowsConfiguration) {
        $patchSettings = $osProfile.WindowsConfiguration.PatchSettings
    }
    elseif ($osProfile -and $osProfile.LinuxConfiguration) {
        $patchSettings = $osProfile.LinuxConfiguration.PatchSettings
    }

    if ($patchSettings -and $patchSettings.PatchMode) {
        if ($Plan.RestoreMode -eq 'ImageFirstSwap') {
            $warnings.Add(("Guest patching: the source uses patch mode '{0}' / assessment mode '{1}'. ImageFirstSwap builds the VM from the original image first, so it will have a real osProfile carrying these settings, and scheduled patching can be re-established." -f $patchSettings.PatchMode, $patchSettings.AssessmentMode))
        }
        else {
            $warnings.Add(("GUEST PATCHING WILL BE LOST. The source uses patch mode '{0}' and assessment mode '{1}'. A VM created by attaching a specialized OS disk has no osProfile, and every patch setting lives inside osProfile. Azure rejects osProfile on this create path and refuses to add it afterwards, so Azure Update Manager SCHEDULED patching cannot be re-established on the result. On-demand assessment and patching still work. To keep scheduled patching, rerun with -RestoreMode ImageFirstSwap." -f $patchSettings.PatchMode, $patchSettings.AssessmentMode))

            if ($patchSettings.PatchMode -eq 'AutomaticByPlatform') {
                $warnings.Add('A maintenance configuration assignment can be attached to a VM that lacks the patch prerequisite: the assignment succeeds at the ARM layer and then fails at run time with "The prerequisites to patch your machine were not met." Seeing the assignment in the portal is therefore NOT evidence that patching works.')
            }
        }
    }

    # --- Identity
    $identity = Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('Identity')
    if ($identity -and ('' + $identity.Type) -match 'SystemAssigned') {
        $warnings.Add('The source VM has a system-assigned identity. The replacement gets a NEW principal ID; every role assignment, Key Vault policy and SQL login granted to the old one must be re-granted.')
    }

    # --- Network plan
    if ($Plan.NetworkAction -eq 'CreateNewNic') {
        if ($Plan.PrivateIpMode -eq 'DynamicPrivateIp') {
            $warnings.Add('The replacement VM will get a NEW dynamically allocated private IP. Supply -UseSourcePrivateIp (after running release-vm-network-address.ps1) or -PrivateIpAddress to keep the original address.')
        }

        $lbBound = @($Manifest.Network.NetworkInterfaces | ForEach-Object { $_.IpConfigurations } | Where-Object { @($_.LoadBalancerBackendAddressPoolIds).Count -gt 0 })
        if ($lbBound.Count -gt 0) {
            $warnings.Add('The source VM is in a load balancer backend pool. A newly created NIC is added back to the pool on a best-effort basis; -ReuseSourceNic preserves it exactly.')
        }
    }

    $nicCount = @($Manifest.Network.NetworkInterfaces).Count
    if ($nicCount -gt 1) {
        $warnings.Add(("The source VM has {0} NICs. Only the primary is handled; attach the others by hand after creation." -f $nicCount))
    }

    return [pscustomobject]@{
        Source = [pscustomobject]@{
            Name              = $sourceVm.Name
            ResourceGroupName = $sourceVm.ResourceGroupName
            Location          = $sourceVm.Location
            VmSize            = $sourceVm.VmSize
            OsType            = $sourceVm.OsType
            Zones             = @(ConvertTo-StringArray -InputObject $sourceVm.Zones)
        }
        Target = [pscustomobject]@{
            Name              = $Plan.VmName
            VmSize            = $Plan.VmSize
            SubscriptionId    = $Plan.SubscriptionId
            ResourceGroupName = $Plan.ResourceGroupName
            Location          = $Plan.Location
            Zone              = @($Plan.Zone)
            TempDiskGB        = [math]::Round($SkuCapability.TempDiskSizeMB / 1024, 0)
            VCpus             = $SkuCapability.VCpus
            MemoryGB          = $SkuCapability.MemoryGB
        }
        NetworkPlan = [pscustomobject]@{
            Action           = $Plan.NetworkAction
            NicName          = $Plan.NicName
            PrivateIpMode    = $Plan.PrivateIpMode
            PrivateIpAddress = $Plan.PrivateIpAddress
            PublicIpMode     = $Plan.PublicIpMode
        }
        Carryover = [pscustomobject]@{
            WindowsLicenseType     = (Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('LicenseType'))
            Tags                   = (Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('Tags'))
            SecurityType           = $sourceSecurityType
            EncryptionAtHost       = (Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('EncryptionAtHost'))
            Identity               = (Get-ObjectPropertyValue -InputObject $identity -PropertyNames @('Type'))
            ExtensionCount         = @((Get-ObjectPropertyValue -InputObject $Manifest.Extensions -PropertyNames @('Data'))).Count
            BackupStatus           = (Get-ObjectPropertyValue -InputObject $Manifest.BackupProtection -PropertyNames @('Status'))
            MaintenanceStatus      = (Get-ObjectPropertyValue -InputObject $Manifest.MaintenanceAssignments -PropertyNames @('Status'))
            SqlRegistrationStatus  = (Get-ObjectPropertyValue -InputObject $Manifest.SqlVirtualMachine -PropertyNames @('Status'))
            DataCollectionStatus   = (Get-ObjectPropertyValue -InputObject $Manifest.DataCollectionRuleAssociations -PropertyNames @('Status'))
        }
        Blockers = @($blockers)
        Warnings = @($warnings)
        CaptureFidelityGaps = @(Get-ObjectPropertyValue -InputObject $Manifest -PropertyNames @('FidelityGaps') -Default @())
    }
}

#endregion


#region Main

$originalContext = $null

try {
    Write-Step 'Checking prerequisites'
    Assert-AzModule -Name @('Az.Accounts', 'Az.Compute', 'Az.Network')
    $originalContext = Save-AzContextState

    Write-Step 'Reading manifest'
    $manifest = Read-JsonFile -Path $ManifestPath

    $schemaVersion = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('SchemaVersion') -Default 0
    if ([int]$schemaVersion -lt $script:VmRebuildManifestSchemaVersion) {
        throw ("This manifest is schema version {0}; this script requires version {1}. Recapture it with the current save-vm-snapshot-manifest.ps1 - an older manifest is missing the disk, identity, extension and network detail needed to rebuild faithfully." -f $schemaVersion, $script:VmRebuildManifestSchemaVersion)
    }

    if (-not $manifest.SourceVm) { throw 'The manifest is missing the SourceVm section.' }
    if (-not $manifest.Snapshots -or -not $manifest.Snapshots.OsDisk) { throw 'The manifest is missing the OS disk snapshot entry.' }

    Write-Detail ("Source VM: {0} ({1})" -f $manifest.SourceVm.Name, $manifest.SourceVm.VmSize)
    Write-Detail ("Captured : {0} in {1} mode" -f $manifest.GeneratedAtUtc, $manifest.Capture.ConsistencyMode)

    $null = Connect-AzIfNeeded

    $effectiveSubscriptionId = $TargetSubscriptionId
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) { $effectiveSubscriptionId = $manifest.SourceVm.SubscriptionId }
    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) { throw 'A target subscription is required. Supply -TargetSubscriptionId.' }

    $null = Set-AzSubscriptionContext -SubscriptionId $effectiveSubscriptionId

    $effectiveResourceGroupName = $TargetResourceGroupName
    if ([string]::IsNullOrWhiteSpace($effectiveResourceGroupName)) { $effectiveResourceGroupName = $manifest.SourceVm.ResourceGroupName }

    $effectiveLocation = $TargetLocation
    if ([string]::IsNullOrWhiteSpace($effectiveLocation)) { $effectiveLocation = $manifest.SourceVm.Location }

    $effectiveZone = @()
    if ($PSBoundParameters.ContainsKey('TargetZone')) {
        $effectiveZone = @(ConvertTo-StringArray -InputObject $TargetZone)
    }
    else {
        $effectiveZone = @(ConvertTo-StringArray -InputObject $manifest.SourceVm.Zones)
    }

    if (-not $DiskNamePrefix) { $DiskNamePrefix = $TargetVmName }

    $null = Get-AzResourceGroup -Name $effectiveResourceGroupName -ErrorAction Stop

    if (Get-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName -ErrorAction SilentlyContinue) {
        throw ("A VM named '{0}' already exists in resource group '{1}'." -f $TargetVmName, $effectiveResourceGroupName)
    }

    # ---------------------------------------------------------------- Network plan
    $sourceNics = @($manifest.Network.NetworkInterfaces)
    $sourcePrimaryNic = @($sourceNics | Where-Object { $_.IsPrimary }) | Select-Object -First 1
    if (-not $sourcePrimaryNic) { $sourcePrimaryNic = @($sourceNics) | Select-Object -First 1 }

    $sourcePrimaryIpConfig = $null
    if ($sourcePrimaryNic) {
        $sourcePrimaryIpConfig = @($sourcePrimaryNic.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
        if (-not $sourcePrimaryIpConfig) { $sourcePrimaryIpConfig = @($sourcePrimaryNic.IpConfigurations) | Select-Object -First 1 }
    }

    $networkAction = 'CreateNewNic'
    $privateIpMode = 'DynamicPrivateIp'
    $publicIpMode = 'None'
    $plannedNicName = $NewNicName
    if (-not $plannedNicName) { $plannedNicName = ("{0}-nic" -f $TargetVmName) }
    $plannedPrivateIp = $null

    if ($ReuseSourceNic) {
        $networkAction = 'ReuseSourceNic'
        $privateIpMode = 'SourceNicRetainsAddress'
        $publicIpMode = 'SourceNicRetainsPublicIp'
        $plannedNicName = $sourcePrimaryNic.Name
        $plannedPrivateIp = Get-ObjectPropertyValue -InputObject $sourcePrimaryIpConfig -PropertyNames @('PrivateIpAddress')
    }
    elseif ($ExistingNicId) {
        $networkAction = 'AttachExistingNic'
        $privateIpMode = 'ExistingNic'
        $publicIpMode = 'ExistingNic'
        $plannedNicName = Get-ResourceNameFromResourceId -ResourceId $ExistingNicId
    }
    else {
        if ($UseSourcePrivateIp) {
            $privateIpMode = 'ReuseSourcePrivateIp'
            $plannedPrivateIp = Get-ObjectPropertyValue -InputObject $sourcePrimaryIpConfig -PropertyNames @('PrivateIpAddress')
        }
        elseif ($PrivateIpAddress) {
            $privateIpMode = 'StaticPrivateIp'
            $plannedPrivateIp = $PrivateIpAddress
        }

        if ($AttachSourcePublicIp) { $publicIpMode = 'ReuseSourcePublicIp' }
        elseif ($PublicIpAddressId) { $publicIpMode = 'ExplicitPublicIp' }
    }

    $plan = [pscustomobject]@{
        VmName            = $TargetVmName
        VmSize            = $TargetVmSize
        SubscriptionId    = $effectiveSubscriptionId
        ResourceGroupName = $effectiveResourceGroupName
        Location          = $effectiveLocation
        Zone              = @($effectiveZone)
        NetworkAction     = $networkAction
        NicName           = $plannedNicName
        PrivateIpMode     = $privateIpMode
        PrivateIpAddress  = $plannedPrivateIp
        PublicIpMode      = $publicIpMode
        RestoreMode       = $RestoreMode
    }

    Write-Step 'Preflight'
    $skuCapability = Get-TargetSkuCapability -VmSize $TargetVmSize -Location $effectiveLocation
    $report = New-PreflightReport -Manifest $manifest -Plan $plan -SkuCapability $skuCapability

    # The single most important safety rule of a side-by-side cutover: the original and the
    # replacement must never be running at the same time. They share a hostname, an Active
    # Directory computer account, a SQL Server instance identity and often a license.
    $sourceStillExists = $false
    $sourcePowerState = 'NotFound'
    try {
        $sourceVmObject = Get-AzVM -ResourceGroupName $manifest.SourceVm.ResourceGroupName -Name $manifest.SourceVm.Name -ErrorAction Stop
        $sourceStillExists = $true
        $sourcePowerState = Get-VmPowerState -ResourceGroupName $sourceVmObject.ResourceGroupName -Name $sourceVmObject.Name
    }
    catch {
        Write-Detail 'The source VM no longer exists, so there is no risk of both running.'
    }

    if ($sourceStillExists -and $sourcePowerState -ne 'PowerState/deallocated' -and $sourcePowerState -ne 'PowerState/stopped') {
        $message = ("The SOURCE VM '{0}' is currently '{1}'. Creating the replacement now risks both machines running with the same hostname, AD computer account and SQL Server instance. Deallocate the source first." -f $manifest.SourceVm.Name, $sourcePowerState)
        if ($Force) { $report.Warnings += $message }
        else { $report.Blockers += $message }
    }

    Write-Host ''
    Write-Host '--- Preflight report ---' -ForegroundColor Cyan
    $report | Format-List | Out-String | Write-Host

    if ($report.Blockers.Count -gt 0) {
        Write-Host 'BLOCKERS:' -ForegroundColor Red
        foreach ($blocker in $report.Blockers) { Write-Host ("  - {0}" -f $blocker) -ForegroundColor Red }
    }

    if ($report.Warnings.Count -gt 0) {
        Write-Host 'WARNINGS:' -ForegroundColor Yellow
        foreach ($warning in $report.Warnings) { Write-Host ("  - {0}" -f $warning) -ForegroundColor Yellow }
    }

    if ($report.CaptureFidelityGaps.Count -gt 0) {
        Write-Host 'GAPS RECORDED AT CAPTURE TIME:' -ForegroundColor Yellow
        foreach ($gap in $report.CaptureFidelityGaps) { Write-Host ("  - {0}" -f $gap) -ForegroundColor Yellow }
    }

    if ($PreflightOnly) {
        Write-Host ''
        Write-Host 'Preflight only. Nothing was created.' -ForegroundColor Cyan
        return $report
    }

    if ($report.Blockers.Count -gt 0) {
        throw ("Preflight found {0} blocker(s). Resolve them, or rerun with -Force if you accept the risk." -f $report.Blockers.Count)
    }

    if (-not $PSCmdlet.ShouldProcess($TargetVmName, ("Create a replacement VM of size {0} in {1}/{2}" -f $TargetVmSize, $effectiveResourceGroupName, $effectiveLocation))) {
        return $report
    }

    # ---------------------------------------------------------------- Disks
    Write-Step 'Creating managed disks'
    $osDiskName = New-AzureResourceName -Prefix $DiskNamePrefix -Discriminator 'osdisk' -Suffix $manifest.Capture.BatchTimestamp -MaxLength $script:AzureDiskNameMaxLength
    $plannedDiskNames = @($osDiskName)

    $dataSnapshotEntries = @($manifest.Snapshots.DataDisks | Sort-Object { [int]$_.Disk.Lun })
    foreach ($entry in $dataSnapshotEntries) {
        $plannedDiskNames += New-AzureResourceName -Prefix $DiskNamePrefix -Discriminator ("lun{0}" -f $entry.Disk.Lun) -Suffix $manifest.Capture.BatchTimestamp -MaxLength $script:AzureDiskNameMaxLength
    }

    Assert-UniqueName -Name $plannedDiskNames -What 'managed disk'

    $restoredOsDisk = New-RestoredDisk -SnapshotEntry $manifest.Snapshots.OsDisk -DiskName $osDiskName -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -Zone $effectiveZone
    Write-Ok ("OS disk: {0}" -f $restoredOsDisk.Name)

    $restoredDataDisks = @()
    $index = 1
    foreach ($entry in $dataSnapshotEntries) {
        $dataDiskName = $plannedDiskNames[$index]
        $created = New-RestoredDisk -SnapshotEntry $entry -DiskName $dataDiskName -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -Zone $effectiveZone
        $restoredDataDisks += [pscustomobject]@{
            Disk    = $created
            Lun     = [int]$entry.Disk.Lun
            Caching = $entry.Disk.Caching
            WriteAcceleratorEnabled = [bool]$entry.Disk.WriteAcceleratorEnabled
        }

        Write-Ok ("LUN {0}: {1}" -f $entry.Disk.Lun, $created.Name)
        $index++
    }

    # ---------------------------------------------------------------- NIC
    Write-Step 'Resolving the network interface'
    if ($ReuseSourceNic) {
        $nic = Get-DetachedSourceNic -NicId $sourcePrimaryNic.Id
        Write-Ok ("Reusing source NIC '{0}' with address {1}." -f $nic.Name, $plannedPrivateIp)
    }
    elseif ($ExistingNicId) {
        $nic = Get-AzNetworkInterface -ResourceId $ExistingNicId -ErrorAction Stop
        Write-Ok ("Using existing NIC '{0}'." -f $nic.Name)
    }
    else {
        $nic = New-RestoredNetworkInterface -NicName $plannedNicName -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation `
            -SourceNic $sourcePrimaryNic -OverrideSubnetId $SubnetId -OverrideNetworkSecurityGroupId $NetworkSecurityGroupId `
            -OverridePrivateIpAddress $PrivateIpAddress -ReuseSourcePrivateIp $UseSourcePrivateIp.IsPresent `
            -OverridePublicIpAddressId $PublicIpAddressId -ReuseSourcePublicIp $AttachSourcePublicIp.IsPresent
        Write-Ok ("Created NIC '{0}'." -f $nic.Name)
    }

    # ---------------------------------------------------------------- VM config
    Write-Step 'Building the VM configuration'
    $sourceVm = $manifest.SourceVm
    $configParameters = @{
        VMName = $TargetVmName
        VMSize = $TargetVmSize
    }

    if ($effectiveZone.Count -gt 0) {
        $configParameters.Zone = $effectiveZone
    }
    elseif ($sourceVm.AvailabilitySetId) {
        # An availability set and a zone are mutually exclusive.
        $configParameters.AvailabilitySetId = $sourceVm.AvailabilitySetId
    }

    $identity = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('Identity')
    $userAssignedIds = @()
    if ($identity) {
        $userAssignedIds = @(ConvertTo-StringArray -InputObject $identity.UserAssignedIdentityIds)
    }

    if ($userAssignedIds.Count -gt 0) {
        # User-assigned identities keep their principal IDs, so every grant made to them
        # still works on the new VM. Attach them at creation time.
        $configParameters.IdentityType = 'UserAssigned'
        $configParameters.IdentityId = $userAssignedIds
    }

    $tagHashtable = ConvertTo-PlainHashtable -InputObject $sourceVm.Tags
    if ($tagHashtable -and $tagHashtable.Count -gt 0) {
        # Passed as a parameter rather than assigned to $vmConfig.Tags: the property is
        # typed IDictionary[string,string] and will not accept a hashtable or a
        # JSON-derived PSCustomObject.
        $configParameters.Tags = $tagHashtable
    }

    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'LicenseType' -Value $sourceVm.LicenseType
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'ProximityPlacementGroupId' -Value $sourceVm.ProximityPlacementGroupId
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'UserData' -Value $sourceVm.UserData
    $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'DiskControllerType' -Value $sourceVm.DiskControllerType

    if (Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('EncryptionAtHost')) {
        $configParameters.EncryptionAtHost = $true
    }

    if ((Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('UltraSSDEnabled')) -and $skuCapability.UltraSSDAvailable) {
        $configParameters.EnableUltraSSD = $true
    }

    if ((Get-BooleanPropertyValue -InputObject $sourceVm -PropertyNames @('HibernationEnabled')) -and $skuCapability.HibernationSupported) {
        $configParameters.HibernationEnabled = $true
    }

    # Capacity reservation groups are region- and subscription-bound, and must contain a
    # reservation matching the NEW size, which is exactly what this migration changes.
    $capacityReservationGroupId = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('CapacityReservationGroupId')
    if ($capacityReservationGroupId) {
        if ($sourceVm.SubscriptionId -ne $effectiveSubscriptionId) {
            Write-Gap 'Skipping the capacity reservation group: the target subscription differs from the source.'
            Add-ManualChecklistItem 'Reapply a capacity reservation group in the target subscription if you need reserved capacity.'
        }
        elseif ($sourceVm.Location -ne $effectiveLocation) {
            Write-Gap 'Skipping the capacity reservation group: the target region differs from the source.'
        }
        else {
            $configParameters.CapacityReservationGroupId = $capacityReservationGroupId
            Write-Detail 'Applying the source capacity reservation group. It must hold a reservation for the NEW size or creation will fail.'
        }
    }

    $securityType = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('SecurityType')
    if ($securityType) {
        $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'SecurityType' -Value $securityType

        $uefi = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('UefiSettings')
        if ($uefi) {
            $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'EnableSecureBoot' -Value ([bool]$uefi.SecureBootEnabled) -AllowFalse
            $null = Add-SupportedParameter -Splat $configParameters -CmdletName 'New-AzVMConfig' -ParameterName 'EnableVtpm' -Value ([bool]$uefi.VTpmEnabled) -AllowFalse
        }
    }

    $osDiskManifest = $manifest.Snapshots.OsDisk.Disk
    $placeholderOsDiskId = $null

    if ($RestoreMode -eq 'ImageFirstSwap') {
        # Build the VM from the original image first so it gets a real osProfile, then swap
        # the restored disk in underneath it. This is the only route that keeps guest patch
        # settings, because osProfile cannot be added to a VM after creation.
        Write-Step 'Creating the placeholder VM from the original image'
        $osDiskSku = $osDiskManifest.SkuName
        if ([string]::IsNullOrWhiteSpace($osDiskSku)) { $osDiskSku = 'Premium_LRS' }

        $placeholder = New-PlaceholderVmFromImage -Manifest $manifest -ConfigParameters $configParameters -NicId $nic.Id `
            -OsDiskSizeGB ([int]$restoredOsDisk.DiskSizeGB) -OsDiskStorageAccountType $osDiskSku `
            -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation

        Write-Step 'Swapping in the restored OS disk'
        $placeholderOsDiskId = Invoke-OsDiskSwap -ResourceGroupName $effectiveResourceGroupName -VmName $TargetVmName -RestoredOsDisk $restoredOsDisk

        Write-Step 'Attaching the restored data disks'
        Add-DataDisksToExistingVm -ResourceGroupName $effectiveResourceGroupName -VmName $TargetVmName -DataDisk $restoredDataDisks -TargetVmSize $TargetVmSize

        if ($placeholderOsDiskId -and -not $KeepPlaceholderOsDisk) {
            try {
                $placeholderDiskName = Get-ResourceNameFromResourceId -ResourceId $placeholderOsDiskId
                $null = Remove-AzDisk -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $placeholderOsDiskId) -DiskName $placeholderDiskName -Force -ErrorAction Stop
                Write-Ok ("Deleted the now-detached placeholder OS disk '{0}'." -f $placeholderDiskName)
            }
            catch {
                Write-Warning ("Could not delete the placeholder OS disk. It holds no data but does cost money. {0}" -f $_.Exception.Message)
                Add-ManualChecklistItem ("Delete the leftover placeholder OS disk: {0}" -f $placeholderOsDiskId)
            }
        }

        # Boot diagnostics stop working after an OS disk swap until the VM is stopped and
        # started again, which happens naturally here because the swap leaves it deallocated.
        Add-ManualChecklistItem 'The VM model now describes the placeholder for computerName and adminUsername, because both are create-time-only properties. The running guest keeps its real name from the restored disk. This mismatch is cosmetic and cannot be corrected.'
    }
    else {
        $vmConfig = New-AzVMConfig @configParameters
        $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id -Primary

        # Marketplace purchase plan. Set on the model directly: New-AzVMConfig has no
        # parameter for it, and omitting it makes creation fail for a marketplace image.
        $planInfo = Get-ObjectPropertyValue -InputObject $sourceVm -PropertyNames @('Plan')
        if ($planInfo -and $planInfo.Name) {
            $vmConfig = Set-AzVMPlan -VM $vmConfig -Name $planInfo.Name -Publisher $planInfo.Publisher -Product $planInfo.Product -ErrorAction Stop
            Write-Detail ("Applied marketplace plan {0}/{1}/{2}." -f $planInfo.Publisher, $planInfo.Product, $planInfo.Name)
        }

        # OS disk attached as a specialized disk. The guest keeps its computer name, its
        # SIDs, its domain membership and all in-guest configuration.
        $osDiskParameters = @{
            VM            = $vmConfig
            ManagedDiskId = $restoredOsDisk.Id
            Name          = $restoredOsDisk.Name
            CreateOption  = 'Attach'
        }

        if ($osDiskManifest.Caching) { $osDiskParameters.Caching = $osDiskManifest.Caching }
        if ($osDiskManifest.WriteAcceleratorEnabled -and $TargetVmSize -like 'Standard_M*') {
            $null = Add-SupportedParameter -Splat $osDiskParameters -CmdletName 'Set-AzVMOSDisk' -ParameterName 'WriteAccelerator' -Value $true
        }

        if ($osDiskManifest.Encryption -and $osDiskManifest.Encryption.DiskEncryptionSetId) {
            $null = Add-SupportedParameter -Splat $osDiskParameters -CmdletName 'Set-AzVMOSDisk' -ParameterName 'DiskEncryptionSetId' -Value $osDiskManifest.Encryption.DiskEncryptionSetId
        }

        switch ('' + $sourceVm.OsType) {
            'Windows' { $osDiskParameters.Windows = $true }
            'Linux'   { $osDiskParameters.Linux = $true }
            default   { throw ("The manifest records OS type '{0}', which is neither Windows nor Linux. The OS disk cannot be attached without it." -f $sourceVm.OsType) }
        }

        $vmConfig = Set-AzVMOSDisk @osDiskParameters

        foreach ($dataDisk in ($restoredDataDisks | Sort-Object -Property Lun)) {
            $dataDiskParameters = @{
                VM            = $vmConfig
                Name          = $dataDisk.Disk.Name
                ManagedDiskId = $dataDisk.Disk.Id
                Lun           = $dataDisk.Lun
                CreateOption  = 'Attach'
            }

            if ($dataDisk.Caching) { $dataDiskParameters.Caching = $dataDisk.Caching }
            if ($dataDisk.WriteAcceleratorEnabled -and $TargetVmSize -like 'Standard_M*') {
                $null = Add-SupportedParameter -Splat $dataDiskParameters -CmdletName 'Add-AzVMDataDisk' -ParameterName 'WriteAccelerator' -Value $true
            }

            $vmConfig = Add-AzVMDataDisk @dataDiskParameters
        }

        Write-Step 'Creating the VM'
        $null = New-AzVM -ResourceGroupName $effectiveResourceGroupName -Location $effectiveLocation -VM $vmConfig -ErrorAction Stop
    }

    $createdVm = Get-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName -ErrorAction Stop
    Register-CreatedResource -Type 'VirtualMachine' -Name $createdVm.Name -Id $createdVm.Id
    Write-Ok ("VM '{0}' created." -f $TargetVmName)

    # ---------------------------------------------------------------- Post-create
    Write-Step 'Applying post-create configuration'

    $systemAssignedRequested = $identity -and (('' + $identity.Type) -match 'SystemAssigned')
    if ($systemAssignedRequested) {
        try {
            $identityType = 'SystemAssigned'
            if ($userAssignedIds.Count -gt 0) { $identityType = 'SystemAssignedUserAssigned' }
            $null = Update-AzVM -ResourceGroupName $effectiveResourceGroupName -VM $createdVm -IdentityType $identityType -ErrorAction Stop
            Write-Ok 'System-assigned managed identity enabled.'
            Add-ManualChecklistItem 'The system-assigned identity has a NEW principal ID. Re-grant every role assignment, Key Vault access policy and database login that was given to the old VM identity.'
        }
        catch {
            Write-Warning ("Unable to enable the system-assigned identity. {0}" -f $_.Exception.Message)
            Add-ManualChecklistItem 'Enable the system-assigned managed identity on the replacement VM and re-grant its permissions.'
        }
    }

    # Guest patch settings. A VM created from a specialized OS disk has no osProfile, and
    # patchSettings live inside osProfile, so this is attempted and honestly reported.
    $osProfileManifest = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('OsProfile')
    $sourcePatchMode = $null
    if ($osProfileManifest -and $osProfileManifest.WindowsConfiguration -and $osProfileManifest.WindowsConfiguration.PatchSettings) {
        $sourcePatchMode = $osProfileManifest.WindowsConfiguration.PatchSettings.PatchMode
    }

    $patchSettingsApplied = $false
    if ($sourcePatchMode) {
        $refreshed = Get-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName -ErrorAction Stop
        if ($refreshed.OSProfile -and $refreshed.OSProfile.WindowsConfiguration) {
            try {
                $refreshed.OSProfile.WindowsConfiguration.PatchSettings.PatchMode = $sourcePatchMode
                $null = Update-AzVM -ResourceGroupName $effectiveResourceGroupName -VM $refreshed -ErrorAction Stop
                $patchSettingsApplied = $true
                Write-Ok ("Guest patch mode set to '{0}'." -f $sourcePatchMode)
            }
            catch {
                Write-Warning ("Unable to set the guest patch mode. {0}" -f $_.Exception.Message)
            }
        }

        if (-not $patchSettingsApplied) {
            Write-Gap ("Guest patch mode '{0}' could NOT be applied: a VM built from a specialized OS disk has no osProfile to hold patchSettings." -f $sourcePatchMode)
            Add-ManualChecklistItem ("Guest patching: the source VM used patch mode '{0}'. The replacement has no osProfile, so this could not be set. Azure Update Manager on-demand assessment and patching still work; scheduled patching that requires AutomaticByPlatform needs the patch orchestration to be re-established through Update Manager's update settings, or the VM rebuilt from a generalized image." -f $sourcePatchMode)
        }
    }

    $null = Restore-BootDiagnostics -Manifest $manifest -ResourceGroupName $effectiveResourceGroupName -VmName $TargetVmName

    $appliedExtensions = @()
    if (-not $SkipExtensions) {
        $appliedExtensions = Restore-VmExtensions -Manifest $manifest -ResourceGroupName $effectiveResourceGroupName -VmName $TargetVmName -Location $effectiveLocation
    }

    $appliedDcr = @()
    if (-not $SkipDataCollectionRules) {
        $appliedDcr = Restore-DataCollectionRuleAssociations -Manifest $manifest -TargetVmResourceId $createdVm.Id
    }

    $backupApplied = $false
    if (-not $SkipBackup) {
        $backupApplied = Restore-VmBackupProtection -Manifest $manifest -TargetVmName $TargetVmName -TargetResourceGroupName $effectiveResourceGroupName
    }

    $appliedMaintenance = @()
    if (-not $SkipMaintenance) {
        $appliedMaintenance = Restore-MaintenanceAssignments -Manifest $manifest -TargetVmResourceId $createdVm.Id -TargetLocation $effectiveLocation
    }

    $sqlApplied = $false
    if (-not $SkipSqlRegistration) {
        $sqlApplied = Restore-SqlVirtualMachineRegistration -Manifest $manifest -TargetVmName $TargetVmName -TargetResourceGroupName $effectiveResourceGroupName -TargetLocation $effectiveLocation
    }

    # Carry forward everything the capture step already knew could not be replayed.
    foreach ($gap in @(Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('FidelityGaps') -Default @())) {
        Add-ManualChecklistItem $gap
    }

    if (@($manifest.Network.NetworkInterfaces).Count -gt 1) {
        Add-ManualChecklistItem 'Attach the source VM''s secondary NICs to the replacement VM.'
    }

    $roleAssignments = Get-ObjectPropertyValue -InputObject $manifest -PropertyNames @('RoleAssignments')
    if ($roleAssignments -and $roleAssignments.Status -eq 'Captured') {
        Add-ManualChecklistItem ("Re-create {0} role assignment(s) that were scoped to the OLD VM resource ID; they are listed in the manifest under RoleAssignments." -f @($roleAssignments.Data).Count)
    }

    # ---------------------------------------------------------------- Power state
    if ($StartVm) {
        if ($sourceStillExists -and $sourcePowerState -ne 'PowerState/deallocated' -and $sourcePowerState -ne 'PowerState/stopped' -and -not $Force) {
            Write-Warning 'Refusing to start the replacement VM while the source VM is still running. Deallocate the source, then start this one.'
        }
        elseif ($PSCmdlet.ShouldProcess($TargetVmName, 'Start the replacement VM')) {
            $null = Start-AzVM -ResourceGroupName $effectiveResourceGroupName -Name $TargetVmName -ErrorAction Stop
            Write-Ok 'Replacement VM started.'
        }
    }
    else {
        Write-Detail 'The replacement VM has been created but NOT started. Start it when you are ready to cut over, and only once the source VM is deallocated.'
    }

    # ---------------------------------------------------------------- Report
    Write-Step 'Result'
    Write-Detail ("VM            : {0} ({1})" -f $TargetVmName, $TargetVmSize)
    Write-Detail ("Resource group: {0}" -f $effectiveResourceGroupName)
    Write-Detail ("OS disk       : {0}" -f $restoredOsDisk.Name)
    Write-Detail ("Data disks    : {0}" -f $restoredDataDisks.Count)
    Write-Detail ("NIC           : {0}" -f $nic.Name)
    Write-Detail ("Backup        : {0}" -f $(if ($backupApplied) { 'enabled' } else { 'NOT enabled' }))
    Write-Detail ("SQL VM        : {0}" -f $(if ($sqlApplied) { 'registered' } else { 'not registered' }))
    Write-Detail ("Extensions    : {0} re-added" -f $appliedExtensions.Count)

    if ($script:ManualChecklist.Count -gt 0) {
        Write-Host ''
        Write-Host ("MANUAL CHECKLIST - {0} item(s) that this script could not do for you:" -f $script:ManualChecklist.Count) -ForegroundColor Yellow
        $itemNumber = 1
        foreach ($item in $script:ManualChecklist) {
            Write-Host ("  {0}. {1}" -f $itemNumber, $item) -ForegroundColor Yellow
            $itemNumber++
        }
    }

    Write-Host ''
    Write-Host ("Next: .\compare-vm-fidelity.ps1 -ManifestPath '{0}' -TargetVmName '{1}'" -f $ManifestPath, $TargetVmName) -ForegroundColor Cyan

    [pscustomobject]@{
        VmName                        = $TargetVmName
        VmId                          = $createdVm.Id
        SubscriptionId                = $effectiveSubscriptionId
        ResourceGroupName             = $effectiveResourceGroupName
        Location                      = $effectiveLocation
        VmSize                        = $TargetVmSize
        RestoreMode                   = $RestoreMode
        Zone                          = @($effectiveZone)
        NicId                         = $nic.Id
        OsDiskName                    = $restoredOsDisk.Name
        DataDiskNames                 = @($restoredDataDisks | ForEach-Object { $_.Disk.Name })
        Started                       = $StartVm.IsPresent
        BackupProtectionApplied       = $backupApplied
        SqlRegistrationApplied        = $sqlApplied
        PatchSettingsApplied          = $patchSettingsApplied
        ExtensionsApplied             = @($appliedExtensions)
        DataCollectionRulesApplied    = @($appliedDcr)
        MaintenanceAssignmentsApplied = @($appliedMaintenance)
        CreatedResources              = @($script:CreatedResources)
        ManualChecklist               = @($script:ManualChecklist)
    }
}
catch {
    Write-Host ''
    Write-Host ("RESTORE FAILED: {0}" -f $_.Exception.Message) -ForegroundColor Red

    if ($script:CreatedResources.Count -gt 0) {
        Write-Host ''
        Write-Host 'These resources were created before the failure and are NOT cleaned up automatically, so you can inspect or reuse them:' -ForegroundColor Yellow
        foreach ($resource in $script:CreatedResources) {
            Write-Host ("  {0,-18} {1}" -f $resource.Type, $resource.Name) -ForegroundColor Yellow
        }

        Write-Host 'Delete them before retrying, or rerun with a different -TargetVmName and -DiskNamePrefix.' -ForegroundColor Yellow
    }

    throw
}
finally {
    Restore-AzContextState -Context $originalContext
}

#endregion
