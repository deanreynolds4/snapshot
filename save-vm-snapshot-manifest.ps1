#Requires -Version 5.1
<#
.SYNOPSIS
    Captures a complete fidelity manifest for an Azure VM and takes a consistent snapshot
    set of its managed disks, so a replacement VM can be rebuilt on a different VM size.

.DESCRIPTION
    This is the capture half of the snapshot-and-rebuild toolkit.

    The toolkit exists because Azure does not allow a VM to be resized between a size
    WITHOUT a local temporary disk and a size WITH one. The supported route is to snapshot
    the disks and build a new VM on the target size. That new VM is a different Azure
    resource, so everything attached to the old resource - backup protection, patch
    schedules, monitoring, identity, role assignments - has to be captured here and
    deliberately replayed by new-vm-from-snapshot-manifest.ps1.

    What this script does:
    - Resolves the source VM, preferring a single Azure Resource Graph query over scanning
      every subscription, and refuses to continue on an ambiguous name.
    - Enforces a consistency mode before taking any snapshot. The default requires the VM
      to be deallocated, because snapshotting a running multi-disk SQL Server VM one disk
      at a time produces a set whose disks are seconds or minutes apart and which is not
      guaranteed to be recoverable.
    - Reads full disk properties with Get-AzDisk rather than trusting the abbreviated view
      in the VM's storage profile, so encryption sets, performance tiers, provisioned IOPS
      and Trusted Launch settings survive the round trip.
    - Records every VM property, every NIC and IP configuration, extensions, identity,
      guest patch settings, backup protection, maintenance assignments, SQL VM registration,
      data collection rule associations, role assignments and resource locks.
    - Marks each optional section with an explicit capture status, so a section that is
      empty because the feature is not configured can never be confused with one that is
      empty because the read failed.
    - Plans and validates all snapshot names for uniqueness BEFORE creating anything, and
      refuses to overwrite an existing snapshot.
    - Writes a raw JSON archive of the source objects alongside the manifest, for the
      settings that no script can replay and an engineer has to reapply by hand.

.PARAMETER VmName
    Name of the source VM to capture.

.PARAMETER SubscriptionId
    Restricts the search to one subscription. Recommended: it skips discovery entirely.

.PARAMETER ResourceGroupName
    Restricts the search to one resource group, for when a VM name is not unique.

.PARAMETER SnapshotResourceGroupName
    Resource group to create the snapshots in. Defaults to the source VM's resource group.

.PARAMETER ConsistencyMode
    Deallocated  - default. Requires the VM to be deallocated before snapshots are taken.
                   This is the only mode that produces a set safe to cut over to.
    RestorePoint - creates a VM restore point, which Azure captures across all disks as a
                   single crash-consistent set while the VM keeps running. Use for
                   rehearsals, or when the outage cannot be taken yet. SQL Server will
                   perform crash recovery on first boot.
    LiveUnsafe   - snapshots each disk individually on a running VM. The disks will not
                   share a point in time. Provided only for non-critical rehearsals and
                   requires -Confirm to be answered explicitly.

.PARAMETER DeallocateVm
    Deallocates the source VM if it is not already deallocated. Without this, Deallocated
    mode stops and tells you to shut the VM down yourself.

.PARAMETER SnapshotSkuName
    Storage SKU for the snapshots. Standard_LRS by default; Standard_ZRS is available in
    regions that support it and is worth using for a zonal source VM.

.PARAMETER FullSnapshot
    Creates full snapshots instead of incremental ones. Incremental is the default because
    it is materially cheaper and faster for large SQL data disks.

.PARAMETER OutputDirectory
    Directory for the manifest, raw archive and transcript. Defaults to the current directory.

.PARAMETER SnapshotTag
    Extra tags to apply to every created snapshot, merged with the toolkit's own tags.

.PARAMETER SkipSnapshots
    Captures and writes the manifest without creating any snapshot. Use this to inventory a
    VM, review the fidelity gap list, and rehearse the migration before spending money.

.EXAMPLE
    .\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -SubscriptionId <guid> -SkipSnapshots

    Inventory only. Writes the manifest and prints the list of settings that cannot be
    replayed automatically, without creating a single billable resource.

.EXAMPLE
    .\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -SubscriptionId <guid> -DeallocateVm

    The real capture. Deallocates the VM, then takes an incremental snapshot of every disk
    while nothing is writing to them, and writes the manifest.

.EXAMPLE
    .\save-vm-snapshot-manifest.ps1 -VmName SQLPROD01 -ConsistencyMode RestorePoint

    Rehearsal capture with the VM left running, using an Azure VM restore point so the
    disks share one crash-consistent point in time.

.NOTES
    Companion scripts: release-vm-network-address.ps1, new-vm-from-snapshot-manifest.ps1,
    compare-vm-fidelity.ps1. See README.md for the full cutover runbook.

    This script creates snapshots, which are billable, and can deallocate the source VM.
    It never deletes anything.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [string]$SubscriptionId,

    [string]$ResourceGroupName,

    [string]$SnapshotResourceGroupName,

    [ValidateSet('Deallocated', 'RestorePoint', 'LiveUnsafe')]
    [string]$ConsistencyMode = 'Deallocated',

    [switch]$DeallocateVm,

    [ValidateSet('Standard_LRS', 'Standard_ZRS')]
    [string]$SnapshotSkuName = 'Standard_LRS',

    [switch]$FullSnapshot,

    [string]$OutputDirectory,

    [hashtable]$SnapshotTag,

    [switch]$SkipSnapshots
)

# Strict mode level 1, not 2. Level 1 catches references to uninitialised variables - the
# class of bug that made the original restore script call .Add() on a $null list. Level 2
# additionally throws on every missing or null property access, which is unusable against
# Az SDK objects, where navigating something like $vm.SecurityProfile.UefiSettings on a VM
# with no security profile is normal and must yield $null rather than end the migration.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'
. (Join-Path -Path $PSScriptRoot -ChildPath 'vm-rebuild-common.ps1')

# Tracks settings that exist on the source but cannot be replayed by the restore script.
# Surfaced at the end and written into the manifest so the README checklist is specific to
# this VM rather than generic.
$script:FidelityGaps = [System.Collections.Generic.List[string]]::new()

function Add-FidelityGap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:FidelityGaps.Add($Message)
    Write-Gap $Message
}


#region Section capture wrapper

function Invoke-CaptureSection {
    <#
    .SYNOPSIS
        Runs one optional capture step and records an explicit outcome.

    .DESCRIPTION
        The original script swallowed read failures, which made "this VM has no backup"
        indistinguishable from "I could not read the backup configuration". Both produced
        an absent manifest section, and the restore script then silently skipped the
        setting. Every optional section now carries a Status so the restore and compare
        scripts can tell the two apart and refuse to claim success.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [string]$RequiredModule
    )

    if ($RequiredModule -and -not (Get-Module -ListAvailable -Name $RequiredModule)) {
        Write-Gap ("{0}: skipped, module {1} is not installed." -f $Name, $RequiredModule)
        return [pscustomobject]@{
            Status = 'Skipped'
            Reason = ("Module {0} is not installed." -f $RequiredModule)
            Data   = $null
        }
    }

    try {
        $data = & $ScriptBlock
        if ($null -eq $data -or (($data -is [System.Collections.ICollection]) -and $data.Count -eq 0)) {
            Write-Detail ("{0}: none configured." -f $Name)
            return [pscustomobject]@{
                Status = 'NotConfigured'
                Reason = $null
                Data   = $null
            }
        }

        $count = 1
        if ($data -is [System.Collections.ICollection]) {
            $count = $data.Count
        }

        Write-Ok ("{0}: captured ({1})." -f $Name, $count)
        return [pscustomobject]@{
            Status = 'Captured'
            Reason = $null
            Data   = $data
        }
    }
    catch {
        Write-Warning ("{0}: capture FAILED. {1}" -f $Name, $_.Exception.Message)
        Add-FidelityGap ("{0} could not be read, so it is absent from the manifest and will NOT be replayed. Check it by hand." -f $Name)
        return [pscustomobject]@{
            Status = 'Failed'
            Reason = $_.Exception.Message
            Data   = $null
        }
    }
}

#endregion


#region VM property capture

function Get-VmCoreProperties {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionName
    )

    $capacityReservationGroupId = $null
    if ($Vm.CapacityReservation -and $Vm.CapacityReservation.CapacityReservationGroup) {
        $capacityReservationGroupId = $Vm.CapacityReservation.CapacityReservationGroup.Id
    }

    $uefi = $null
    if ($Vm.SecurityProfile -and $Vm.SecurityProfile.UefiSettings) {
        $uefi = [pscustomobject]@{
            SecureBootEnabled = [bool]$Vm.SecurityProfile.UefiSettings.SecureBootEnabled
            VTpmEnabled       = [bool]$Vm.SecurityProfile.UefiSettings.VTpmEnabled
        }
    }

    $plan = $null
    if ($Vm.Plan) {
        # A marketplace VM cannot be recreated without its purchase plan. Omitting it makes
        # VM creation fail outright, so this is captured even though it is rarely present.
        $plan = [pscustomobject]@{
            Name          = $Vm.Plan.Name
            Publisher     = $Vm.Plan.Publisher
            Product       = $Vm.Plan.Product
            PromotionCode = (Get-ObjectPropertyValue -InputObject $Vm.Plan -PropertyNames @('PromotionCode'))
        }
    }

    $imageReference = $null
    if ($Vm.StorageProfile -and $Vm.StorageProfile.ImageReference) {
        $imageReference = [pscustomobject]@{
            Publisher              = $Vm.StorageProfile.ImageReference.Publisher
            Offer                  = $Vm.StorageProfile.ImageReference.Offer
            Sku                    = $Vm.StorageProfile.ImageReference.Sku
            Version                = $Vm.StorageProfile.ImageReference.Version
            ExactVersion           = Get-ObjectPropertyValue -InputObject $Vm.StorageProfile.ImageReference -PropertyNames @('ExactVersion')
            Id                     = $Vm.StorageProfile.ImageReference.Id
            SharedGalleryImageId   = Get-ObjectPropertyValue -InputObject $Vm.StorageProfile.ImageReference -PropertyNames @('SharedGalleryImageId')
            CommunityGalleryImageId = Get-ObjectPropertyValue -InputObject $Vm.StorageProfile.ImageReference -PropertyNames @('CommunityGalleryImageId')
        }
    }

    $bootDiagnostics = $null
    if ($Vm.DiagnosticsProfile -and $Vm.DiagnosticsProfile.BootDiagnostics) {
        $bootDiagnostics = [pscustomobject]@{
            Enabled    = [bool]$Vm.DiagnosticsProfile.BootDiagnostics.Enabled
            StorageUri = $Vm.DiagnosticsProfile.BootDiagnostics.StorageUri
        }
    }

    $scheduledEvents = $null
    if ($Vm.ScheduledEventsProfile) {
        $terminate = $null
        if ($Vm.ScheduledEventsProfile.TerminateNotificationProfile) {
            $terminate = [pscustomobject]@{
                Enable           = [bool]$Vm.ScheduledEventsProfile.TerminateNotificationProfile.Enable
                NotBeforeTimeout = $Vm.ScheduledEventsProfile.TerminateNotificationProfile.NotBeforeTimeout
            }
        }

        $scheduledEvents = [pscustomobject]@{ TerminateNotificationProfile = $terminate }
    }

    return [pscustomobject]@{
        Name                       = $Vm.Name
        Id                         = $Vm.Id
        VmId                       = $Vm.VmId
        SubscriptionId             = $SubscriptionId
        SubscriptionName           = $SubscriptionName
        ResourceGroupName          = $Vm.ResourceGroupName
        Location                   = $Vm.Location
        Zones                      = (ConvertTo-StringArray -InputObject $Vm.Zones)
        VmSize                     = $Vm.HardwareProfile.VmSize
        OsType                     = [string]$Vm.StorageProfile.OsDisk.OsType
        LicenseType                = $Vm.LicenseType
        Tags                       = (ConvertTo-StringDictionary -InputObject $Vm.Tags)
        Plan                       = $plan
        ImageReference             = $imageReference

        # Placement
        AvailabilitySetId          = (Get-ObjectPropertyValue -InputObject $Vm.AvailabilitySetReference -PropertyNames @('Id'))
        ProximityPlacementGroupId  = (Get-ObjectPropertyValue -InputObject $Vm.ProximityPlacementGroup -PropertyNames @('Id'))
        CapacityReservationGroupId = $capacityReservationGroupId
        HostId                     = (Get-ObjectPropertyValue -InputObject $Vm.Host -PropertyNames @('Id'))
        HostGroupId                = (Get-ObjectPropertyValue -InputObject $Vm.HostGroup -PropertyNames @('Id'))
        VirtualMachineScaleSetId   = (Get-ObjectPropertyValue -InputObject $Vm.VirtualMachineScaleSet -PropertyNames @('Id'))
        PlatformFaultDomain        = (Get-ObjectPropertyValue -InputObject $Vm -PropertyNames @('PlatformFaultDomain'))
        ExtendedLocation           = (Get-ObjectPropertyValue -InputObject $Vm -PropertyNames @('ExtendedLocation'))

        # Security
        SecurityType               = (Get-ObjectPropertyValue -InputObject $Vm.SecurityProfile -PropertyNames @('SecurityType'))
        EncryptionAtHost           = (Get-BooleanPropertyValue -InputObject $Vm.SecurityProfile -PropertyNames @('EncryptionAtHost'))
        UefiSettings               = $uefi

        # Capabilities and storage controller
        UltraSSDEnabled            = (Get-BooleanPropertyValue -InputObject $Vm.AdditionalCapabilities -PropertyNames @('UltraSSDEnabled'))
        HibernationEnabled         = (Get-BooleanPropertyValue -InputObject $Vm.AdditionalCapabilities -PropertyNames @('HibernationEnabled'))
        DiskControllerType         = (Get-ObjectPropertyValue -InputObject $Vm.StorageProfile -PropertyNames @('DiskControllerType'))

        # Spot / priority
        Priority                   = (Get-ObjectPropertyValue -InputObject $Vm -PropertyNames @('Priority'))
        EvictionPolicy             = (Get-ObjectPropertyValue -InputObject $Vm -PropertyNames @('EvictionPolicy'))
        MaxPrice                   = (Get-ObjectPropertyValue -InputObject $Vm.BillingProfile -PropertyNames @('MaxPrice'))

        # Misc
        UserData                   = (Get-ObjectPropertyValue -InputObject $Vm -PropertyNames @('UserData'))
        BootDiagnostics            = $bootDiagnostics
        ScheduledEventsProfile     = $scheduledEvents
    }
}

function Get-VmOsProfileProperties {
    <#
    .SYNOPSIS
        Captures the osProfile, including guest patch settings.

    .DESCRIPTION
        This section is captured for reference and for the compare script, but the restore
        script cannot set most of it. A VM built from a SPECIALIZED OS disk has no
        osProfile at all, and patchSettings live inside it. See the README for the
        consequences for Azure Update Manager.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    if (-not $Vm.OSProfile) {
        return $null
    }

    $readPatchSettings = {
        param($configuration)

        if (-not $configuration -or -not $configuration.PatchSettings) {
            return $null
        }

        $automatic = $null
        if ($configuration.PatchSettings.AutomaticByPlatformSettings) {
            $automatic = [pscustomobject]@{
                RebootSetting                          = Get-ObjectPropertyValue -InputObject $configuration.PatchSettings.AutomaticByPlatformSettings -PropertyNames @('RebootSetting')
                BypassPlatformSafetyChecksOnUserSchedule = Get-BooleanPropertyValue -InputObject $configuration.PatchSettings.AutomaticByPlatformSettings -PropertyNames @('BypassPlatformSafetyChecksOnUserSchedule')
            }
        }

        return [pscustomobject]@{
            PatchMode                 = Get-ObjectPropertyValue -InputObject $configuration.PatchSettings -PropertyNames @('PatchMode')
            AssessmentMode            = Get-ObjectPropertyValue -InputObject $configuration.PatchSettings -PropertyNames @('AssessmentMode')
            EnableHotpatching         = Get-BooleanPropertyValue -InputObject $configuration.PatchSettings -PropertyNames @('EnableHotpatching')
            AutomaticByPlatformSettings = $automatic
        }
    }

    $windows = $null
    if ($Vm.OSProfile.WindowsConfiguration) {
        $windows = [pscustomobject]@{
            ProvisionVMAgent        = Get-BooleanPropertyValue -InputObject $Vm.OSProfile.WindowsConfiguration -PropertyNames @('ProvisionVMAgent')
            EnableAutomaticUpdates  = Get-BooleanPropertyValue -InputObject $Vm.OSProfile.WindowsConfiguration -PropertyNames @('EnableAutomaticUpdates')
            TimeZone                = Get-ObjectPropertyValue -InputObject $Vm.OSProfile.WindowsConfiguration -PropertyNames @('TimeZone')
            PatchSettings           = & $readPatchSettings $Vm.OSProfile.WindowsConfiguration
        }
    }

    $linux = $null
    if ($Vm.OSProfile.LinuxConfiguration) {
        $linux = [pscustomobject]@{
            ProvisionVMAgent          = Get-BooleanPropertyValue -InputObject $Vm.OSProfile.LinuxConfiguration -PropertyNames @('ProvisionVMAgent')
            DisablePasswordAuthentication = Get-BooleanPropertyValue -InputObject $Vm.OSProfile.LinuxConfiguration -PropertyNames @('DisablePasswordAuthentication')
            PatchSettings             = & $readPatchSettings $Vm.OSProfile.LinuxConfiguration
        }
    }

    return [pscustomobject]@{
        ComputerName            = $Vm.OSProfile.ComputerName
        AdminUsername           = $Vm.OSProfile.AdminUsername
        AllowExtensionOperations = Get-BooleanPropertyValue -InputObject $Vm.OSProfile -PropertyNames @('AllowExtensionOperations')
        RequireGuestProvisionSignal = Get-BooleanPropertyValue -InputObject $Vm.OSProfile -PropertyNames @('RequireGuestProvisionSignal')
        WindowsConfiguration    = $windows
        LinuxConfiguration      = $linux
    }
}

function Get-VmIdentityProperties {
    <#
    .SYNOPSIS
        Captures managed identity assignment.

    .DESCRIPTION
        A user-assigned identity can be reattached to the new VM and keeps its principal ID,
        so every role assignment and Key Vault policy granted to it continues to work.
        A system-assigned identity cannot: the new VM gets a brand new principal ID, and
        every grant made to the old one has to be re-made.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    if (-not $Vm.Identity) {
        return $null
    }

    $userAssignedIds = @()
    if ($Vm.Identity.UserAssignedIdentities) {
        foreach ($key in $Vm.Identity.UserAssignedIdentities.Keys) {
            $userAssignedIds += [string]$key
        }
    }

    return [pscustomobject]@{
        Type                    = [string]$Vm.Identity.Type
        SystemAssignedPrincipalId = $Vm.Identity.PrincipalId
        TenantId                = $Vm.Identity.TenantId
        UserAssignedIdentityIds = @($userAssignedIds)
    }
}

#endregion


#region Disk capture

function Get-DiskDetail {
    <#
    .SYNOPSIS
        Reads the full managed disk resource and merges it with the VM's attach settings.

    .DESCRIPTION
        The VM's storage profile only carries how a disk is ATTACHED (LUN, caching, write
        accelerator). Everything about the disk ITSELF - its SKU, provisioned IOPS,
        performance tier, encryption set, Hyper-V generation, security type - lives on the
        disk resource and is lost unless Get-AzDisk is called. A disk restored without them
        silently reverts to platform defaults, which for a SQL data volume means a quiet
        performance regression nobody notices until month end.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$AttachedDisk,

        [Parameter(Mandatory = $true)]
        [ValidateSet('OS', 'Data')]
        [string]$DiskRole
    )

    $managedDiskId = $null
    if ($AttachedDisk.ManagedDisk) {
        $managedDiskId = $AttachedDisk.ManagedDisk.Id
    }

    if ([string]::IsNullOrWhiteSpace($managedDiskId)) {
        throw ("The {0} disk '{1}' has no managed disk resource ID. Unmanaged (page blob) disks are not supported by this toolkit." -f $DiskRole, $AttachedDisk.Name)
    }

    $diskResourceGroup = Get-ResourceGroupNameFromResourceId -ResourceId $managedDiskId
    $diskName = Get-ResourceNameFromResourceId -ResourceId $managedDiskId

    $disk = $null
    try {
        $disk = Get-AzDisk -ResourceGroupName $diskResourceGroup -DiskName $diskName -ErrorAction Stop
    }
    catch {
        throw ("Unable to read managed disk '{0}' in resource group '{1}'. {2}" -f $diskName, $diskResourceGroup, $_.Exception.Message)
    }

    $encryption = $null
    if ($disk.Encryption) {
        $encryption = [pscustomobject]@{
            Type                = [string]$disk.Encryption.Type
            DiskEncryptionSetId = $disk.Encryption.DiskEncryptionSetId
        }
    }

    # Legacy Azure Disk Encryption (in-guest BitLocker/dm-crypt). Restoring one of these
    # needs the original key vault secret and KEK, which is a manual step.
    $adeEnabled = $false
    if ($disk.EncryptionSettingsCollection) {
        $adeEnabled = [bool](Get-ObjectPropertyValue -InputObject $disk.EncryptionSettingsCollection -PropertyNames @('Enabled'))
    }

    return [pscustomobject]@{
        DiskRole                 = $DiskRole
        Lun                      = if ($DiskRole -eq 'Data') { [int]$AttachedDisk.Lun } else { $null }

        # How it is attached to the VM
        AttachedName             = $AttachedDisk.Name
        Caching                  = [string]$AttachedDisk.Caching
        WriteAcceleratorEnabled  = (Get-BooleanPropertyValue -InputObject $AttachedDisk -PropertyNames @('WriteAcceleratorEnabled'))
        DeleteOption             = (Get-ObjectPropertyValue -InputObject $AttachedDisk -PropertyNames @('DeleteOption'))

        # The disk resource itself
        DiskId                   = $disk.Id
        DiskName                 = $disk.Name
        DiskResourceGroupName    = $diskResourceGroup
        Location                 = $disk.Location
        Zones                    = (ConvertTo-StringArray -InputObject $disk.Zones)
        SkuName                  = (Get-ObjectPropertyValue -InputObject $disk.Sku -PropertyNames @('Name'))
        SkuTier                  = (Get-ObjectPropertyValue -InputObject $disk.Sku -PropertyNames @('Tier'))
        DiskSizeGB               = $disk.DiskSizeGB
        DiskIOPSReadWrite        = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('DiskIOPSReadWrite'))
        DiskMBpsReadWrite        = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('DiskMBpsReadWrite'))
        PerformanceTier          = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('Tier'))
        BurstingEnabled          = (Get-BooleanPropertyValue -InputObject $disk -PropertyNames @('BurstingEnabled'))
        MaxShares                = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('MaxShares'))
        HyperVGeneration         = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('HyperVGeneration'))
        OsType                   = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('OsType'))
        Architecture             = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('Architecture'))
        LogicalSectorSize        = (Get-ObjectPropertyValue -InputObject $disk.CreationData -PropertyNames @('LogicalSectorSize'))
        NetworkAccessPolicy      = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('NetworkAccessPolicy'))
        DiskAccessId             = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('DiskAccessId'))
        PublicNetworkAccess      = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('PublicNetworkAccess'))
        DataAccessAuthMode       = (Get-ObjectPropertyValue -InputObject $disk -PropertyNames @('DataAccessAuthMode'))
        OptimizedForFrequentAttach = (Get-BooleanPropertyValue -InputObject $disk -PropertyNames @('OptimizedForFrequentAttach'))
        SupportsHibernation      = (Get-BooleanPropertyValue -InputObject $disk -PropertyNames @('SupportsHibernation'))
        DiskSecurityType         = (Get-ObjectPropertyValue -InputObject $disk.SecurityProfile -PropertyNames @('SecurityType'))
        SecureVMDiskEncryptionSetId = (Get-ObjectPropertyValue -InputObject $disk.SecurityProfile -PropertyNames @('SecureVMDiskEncryptionSetId'))
        Encryption               = $encryption
        AzureDiskEncryptionEnabled = $adeEnabled
        Tags                     = (ConvertTo-StringDictionary -InputObject $disk.Tags)
    }
}

#endregion


#region Network capture

function Get-NetworkInterfaceDetail {
    <#
    .SYNOPSIS
        Captures one NIC in full, including every IP configuration and its memberships.

    .DESCRIPTION
        Load balancer backend pools, application gateway backend pools, inbound NAT rules
        and application security groups are all properties of the NIC's IP configuration,
        not of the load balancer. Recreating a NIC without them silently removes the VM
        from the load balancer with no error anywhere.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$NicReference
    )

    $nic = Get-AzNetworkInterface -ResourceId $NicReference.Id -ErrorAction Stop

    $ipConfigurations = @()
    foreach ($ipConfiguration in @($nic.IpConfigurations)) {
        $ipConfigurations += [pscustomobject]@{
            Name                       = $ipConfiguration.Name
            Primary                    = [bool]$ipConfiguration.Primary
            PrivateIpAddress           = $ipConfiguration.PrivateIpAddress
            PrivateIpAllocationMethod  = [string]$ipConfiguration.PrivateIpAllocationMethod
            PrivateIpAddressVersion    = [string](Get-ObjectPropertyValue -InputObject $ipConfiguration -PropertyNames @('PrivateIpAddressVersion'))
            SubnetId                   = (Get-ObjectPropertyValue -InputObject $ipConfiguration.Subnet -PropertyNames @('Id'))
            PublicIpAddressId          = (Get-ObjectPropertyValue -InputObject $ipConfiguration.PublicIpAddress -PropertyNames @('Id'))
            ApplicationSecurityGroupIds = @(@($ipConfiguration.ApplicationSecurityGroups) | Where-Object { $_ } | ForEach-Object { $_.Id })
            LoadBalancerBackendAddressPoolIds = @(@($ipConfiguration.LoadBalancerBackendAddressPools) | Where-Object { $_ } | ForEach-Object { $_.Id })
            LoadBalancerInboundNatRuleIds = @(@($ipConfiguration.LoadBalancerInboundNatRules) | Where-Object { $_ } | ForEach-Object { $_.Id })
            ApplicationGatewayBackendAddressPoolIds = @(@($ipConfiguration.ApplicationGatewayBackendAddressPools) | Where-Object { $_ } | ForEach-Object { $_.Id })
        }
    }

    $dnsServers = @()
    if ($nic.DnsSettings) {
        $dnsServers = (ConvertTo-StringArray -InputObject $nic.DnsSettings.DnsServers)
    }

    return [pscustomobject]@{
        Id                          = $nic.Id
        Name                        = $nic.Name
        ResourceGroupName           = $nic.ResourceGroupName
        Location                    = $nic.Location
        IsPrimary                   = [bool]$NicReference.Primary
        DeleteOption                = (Get-ObjectPropertyValue -InputObject $NicReference -PropertyNames @('DeleteOption'))
        EnableAcceleratedNetworking = [bool]$nic.EnableAcceleratedNetworking
        EnableIPForwarding          = [bool]$nic.EnableIPForwarding
        DisableTcpStateTracking     = (Get-BooleanPropertyValue -InputObject $nic -PropertyNames @('DisableTcpStateTracking'))
        NicType                     = (Get-ObjectPropertyValue -InputObject $nic -PropertyNames @('NicType'))
        AuxiliaryMode               = (Get-ObjectPropertyValue -InputObject $nic -PropertyNames @('AuxiliaryMode'))
        AuxiliarySku                = (Get-ObjectPropertyValue -InputObject $nic -PropertyNames @('AuxiliarySku'))
        NetworkSecurityGroupId      = (Get-ObjectPropertyValue -InputObject $nic.NetworkSecurityGroup -PropertyNames @('Id'))
        DnsServers                  = @($dnsServers)
        InternalDnsNameLabel        = (Get-ObjectPropertyValue -InputObject $nic.DnsSettings -PropertyNames @('InternalDnsNameLabel'))
        Tags                        = (ConvertTo-StringDictionary -InputObject $nic.Tags)
        IpConfigurations            = @($ipConfigurations)
    }
}

#endregion


#region Attached-resource capture

function Get-VmBackupProtection {
    <#
    .SYNOPSIS
        Reads Recovery Services backup protection for the VM.

    .DESCRIPTION
        Reports only what the service actually says. The original script forced
        IsProtected to true whenever a vault ID resolved, which meant a VM whose protection
        had been stopped-with-data-retained was recorded as protected with a null policy
        name, and the restore then failed at the point where the operator had already been
        told backup would carry over.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $status = Get-AzRecoveryServicesBackupStatus -Name $Vm.Name -ResourceGroupName $Vm.ResourceGroupName -Type AzureVM -ErrorAction Stop

    $vaultId = Get-ObjectPropertyValue -InputObject $status -PropertyNames @('VaultId')
    $backedUp = Get-BooleanPropertyValue -InputObject $status -PropertyNames @('BackedUp')

    if (-not $backedUp -and [string]::IsNullOrWhiteSpace($vaultId)) {
        return $null
    }

    $vaultName = Get-ResourceNameFromResourceId -ResourceId $vaultId
    $policyName = $null
    $policyId = $null
    $protectionState = $null
    $lastBackupStatus = $null
    $lastBackupTime = $null
    $backupItemName = $null

    if ($vaultId) {
        $container = @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $Vm.Name -VaultId $vaultId -ErrorAction Stop) | Select-Object -First 1
        if ($container) {
            $item = @(Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vaultId -ErrorAction Stop) | Select-Object -First 1
            if ($item) {
                $backupItemName  = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('Name')
                $policyName      = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('PolicyName', 'ProtectionPolicyName')
                $policyId        = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('PolicyId')
                $protectionState = [string](Get-ObjectPropertyValue -InputObject $item -PropertyNames @('ProtectionState'))
                $lastBackupStatus = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('LastBackupStatus')
                $lastBackupTime  = Get-ObjectPropertyValue -InputObject $item -PropertyNames @('LastBackupTime')
            }
        }
    }

    if ($backedUp -and [string]::IsNullOrWhiteSpace($policyName)) {
        Add-FidelityGap 'The VM appears to be protected by Azure Backup but the policy name could not be resolved. Backup will NOT be re-enabled automatically; do it by hand after cutover.'
    }

    return [pscustomobject]@{
        IsProtected            = $backedUp
        VaultId                = $vaultId
        VaultName              = $vaultName
        VaultResourceGroupName = (Get-ResourceGroupNameFromResourceId -ResourceId $vaultId)
        VaultSubscriptionId    = (Get-SubscriptionIdFromResourceId -ResourceId $vaultId)
        BackupItemName         = $backupItemName
        PolicyName             = $policyName
        PolicyId               = $policyId
        ProtectionState        = $protectionState
        LastBackupStatus       = $lastBackupStatus
        LastBackupTime         = $lastBackupTime
    }
}

function Get-VmSqlWorkloadBackup {
    <#
    .SYNOPSIS
        Detects SQL-in-VM workload backup, which is a different thing from VM backup.

    .DESCRIPTION
        A SQL Server VM is frequently protected twice: AzureVM backup for the machine, and
        AzureWorkload/MSSQL backup for the databases with its own container registration
        and auto-protection. The second is not re-established by enabling VM backup, and
        the toolkit cannot recreate it safely, so it is detected and reported as a manual
        step rather than silently ignored.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm,

        [AllowNull()]
        [string]$VaultId
    )

    if ([string]::IsNullOrWhiteSpace($VaultId)) {
        return $null
    }

    $containers = @(Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -VaultId $VaultId -ErrorAction Stop |
        Where-Object { $_.FriendlyName -eq $Vm.Name })

    if ($containers.Count -eq 0) {
        return $null
    }

    $container = $containers[0]
    $items = @()
    try {
        $items = @(Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType MSSQL -VaultId $VaultId -ErrorAction Stop)
    }
    catch {
        Write-Warning ("Unable to list SQL backup items for container '{0}'. {1}" -f $container.Name, $_.Exception.Message)
    }

    Add-FidelityGap 'This VM has SQL workload (database-level) backup registered. That registration is bound to the old VM and must be re-registered against the new VM by hand after cutover.'

    return [pscustomobject]@{
        ContainerName    = $container.Name
        ContainerStatus  = [string](Get-ObjectPropertyValue -InputObject $container -PropertyNames @('Status', 'RegistrationStatus'))
        ProtectedItems   = @($items | ForEach-Object {
            [pscustomobject]@{
                Name       = $_.Name
                ItemType   = [string](Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('WorkloadType'))
                PolicyName = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('PolicyName', 'ProtectionPolicyName')
            }
        })
    }
}

function Get-VmMaintenanceAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $assignments = @(Get-AzConfigurationAssignment -ProviderName 'Microsoft.Compute' -ResourceGroupName $Vm.ResourceGroupName -ResourceType 'virtualMachines' -ResourceName $Vm.Name -ErrorAction Stop)

    return @($assignments | ForEach-Object {
        [pscustomobject]@{
            ConfigurationAssignmentName = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Name', 'ConfigurationAssignmentName')
            MaintenanceConfigurationId  = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('MaintenanceConfigurationId')
            Location                    = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Location')
            ResourceId                  = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Id')
        }
    })
}

function Get-SqlVirtualMachineDetail {
    <#
    .SYNOPSIS
        Captures the Microsoft.SqlVirtualMachine registration in depth.

    .DESCRIPTION
        Property names here are deliberately probed under both their modern model names
        (SqlServerLicenseType, SqlImageSku, SqlImageOffer, SqlManagement) and their older
        short names. Reading only the short names - as the original script did - returns
        null on current Az.SqlVirtualMachine builds, which silently drops Azure Hybrid
        Benefit for SQL and re-registers the new VM at pay-as-you-go rates.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $sqlVm = $null
    try {
        $sqlVm = Get-AzSqlVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    }
    catch {
        # Not registered is the common case and is not an error.
        return $null
    }

    if (-not $sqlVm) {
        return $null
    }

    $licenseType = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('SqlServerLicenseType', 'LicenseType')
    if ([string]::IsNullOrWhiteSpace($licenseType)) {
        Add-FidelityGap 'The SQL VM is registered but its SQL license type could not be read. Confirm Azure Hybrid Benefit on the new VM by hand or you may be billed at pay-as-you-go rates.'
    }

    $autoPatching = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('AutoPatchingSettings')
    $storageConfiguration = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('StorageConfigurationSettings')
    if ($storageConfiguration) {
        Add-FidelityGap 'The SQL VM has storage configuration settings (data/log/TempDB layout). Review sqlTempDbSettings after cutover: on a size with a local temp disk, TempDB placement is exactly what this migration is meant to change.'
    }

    return [pscustomobject]@{
        IsRegistered              = $true
        Name                      = $sqlVm.Name
        Id                        = $sqlVm.Id
        ResourceGroupName         = (Get-ResourceGroupNameFromResourceId -ResourceId $sqlVm.Id)
        Location                  = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Location'))
        LicenseType               = $licenseType
        Sku                       = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('SqlImageSku', 'Sku'))
        Offer                     = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('SqlImageOffer', 'Offer'))
        SqlManagementType         = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('SqlManagement', 'SqlManagementType'))
        EnableAutomaticUpgrade    = (Get-BooleanPropertyValue -InputObject $sqlVm -PropertyNames @('EnableAutomaticUpgrade', 'EnableAutoUpgrade'))
        LeastPrivilegeMode        = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('LeastPrivilegeMode'))
        AutoPatchingSettings      = $autoPatching
        AutoBackupSettings        = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('AutoBackupSettings'))
        KeyVaultCredentialSettings = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('KeyVaultCredentialSettings'))
        ServerConfigurationsManagementSettings = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('ServerConfigurationsManagementSettings'))
        StorageConfigurationSettings = $storageConfiguration
        AssessmentSettings        = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('AssessmentSettings'))
        VirtualMachineResourceId  = (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('VirtualMachineResourceId'))
        Tags                      = (ConvertTo-StringDictionary -InputObject (Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Tags')))
    }
}

function Get-VmExtensionDetail {
    <#
    .SYNOPSIS
        Captures installed VM extensions and their public settings.

    .DESCRIPTION
        Protected settings are write-only in Azure and cannot be read back, so any
        extension that carries a secret has to be re-added manually with that secret.
        Those are flagged individually rather than lumped into a generic warning.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $extensions = @(Get-AzVMExtension -ResourceGroupName $Vm.ResourceGroupName -VMName $Vm.Name -ErrorAction Stop)

    $result = @()
    foreach ($extension in $extensions) {
        $hasProtectedSettings = $false
        if (Test-ObjectHasProperty -InputObject $extension -PropertyName 'ProtectedSettings') {
            $hasProtectedSettings = ($null -ne $extension.ProtectedSettings)
        }

        $result += [pscustomobject]@{
            Name                    = $extension.Name
            Publisher               = $extension.Publisher
            ExtensionType           = (Get-ObjectPropertyValue -InputObject $extension -PropertyNames @('ExtensionType', 'ExtensionHandlerVersion', 'Type'))
            TypeHandlerVersion      = $extension.TypeHandlerVersion
            AutoUpgradeMinorVersion = (Get-BooleanPropertyValue -InputObject $extension -PropertyNames @('AutoUpgradeMinorVersion'))
            EnableAutomaticUpgrade  = (Get-BooleanPropertyValue -InputObject $extension -PropertyNames @('EnableAutomaticUpgrade'))
            ProvisioningState       = (Get-ObjectPropertyValue -InputObject $extension -PropertyNames @('ProvisioningState'))
            Location                = $extension.Location
            PublicSettings          = (Get-ObjectPropertyValue -InputObject $extension -PropertyNames @('PublicSettings', 'Settings'))
            HasProtectedSettings    = $hasProtectedSettings
        }
    }

    if ($result.Count -gt 0) {
        Add-FidelityGap ("The VM has {0} extension(s). Their protected settings (passwords, keys, workspace keys, domain-join credentials) are write-only in Azure and cannot be captured. Re-add any extension that needs a secret manually." -f $result.Count)
    }

    return @($result)
}

#endregion


#region Snapshot creation

function New-DiskSnapshotPlan {
    <#
    .SYNOPSIS
        Works out every snapshot name up front and proves they are unique.

    .DESCRIPTION
        Names are built from the VM name, a role discriminator that is unique by
        construction ('os', or 'lun<n>' - a LUN is unique per VM by definition) and the
        batch timestamp. The source disk NAME is deliberately not used, because truncating
        it is how sibling data disks end up sharing a snapshot name and overwriting each
        other with no error.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Disk,

        [Parameter(Mandatory = $true)]
        [string]$VmName,

        [Parameter(Mandatory = $true)]
        [string]$BatchTimestamp
    )

    $plan = @()
    foreach ($item in $Disk) {
        $discriminator = 'os'
        if ($item.DiskRole -eq 'Data') {
            $discriminator = ('lun{0}' -f $item.Lun)
        }

        $plan += [pscustomobject]@{
            Disk         = $item
            SnapshotName = (New-AzureResourceName -Prefix $VmName -Discriminator $discriminator -Suffix $BatchTimestamp -MaxLength $script:AzureSnapshotNameMaxLength)
        }
    }

    Assert-UniqueName -Name @($plan | ForEach-Object { $_.SnapshotName }) -What 'snapshot'

    return @($plan)
}

function New-DiskSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Disk,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotName,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter(Mandatory = $true)]
        [string]$SkuName,

        [Parameter(Mandatory = $true)]
        [bool]$Incremental,

        [hashtable]$Tag
    )

    $existing = Get-AzSnapshot -ResourceGroupName $SnapshotResourceGroupName -SnapshotName $SnapshotName -ErrorAction SilentlyContinue
    if ($existing) {
        throw ("A snapshot named '{0}' already exists in resource group '{1}'. Refusing to overwrite it." -f $SnapshotName, $SnapshotResourceGroupName)
    }

    $configParameters = @{
        Location         = $Location
        CreateOption     = 'Copy'
        SourceResourceId = $Disk.DiskId
        SkuName          = $SkuName
    }

    if ($Incremental) {
        $configParameters.Incremental = $true
    }

    if ($Tag) {
        $configParameters.Tag = $Tag
    }

    # Carry the customer-managed key forward. Without this the snapshot, and therefore the
    # restored disk, silently falls back to platform-managed encryption.
    if ($Disk.Encryption -and $Disk.Encryption.DiskEncryptionSetId) {
        $configParameters.DiskEncryptionSetId = $Disk.Encryption.DiskEncryptionSetId
        if ($Disk.Encryption.Type) {
            $configParameters.EncryptionType = $Disk.Encryption.Type
        }
    }

    if ($Disk.DiskRole -eq 'OS') {
        if ($Disk.HyperVGeneration) {
            $configParameters.HyperVGeneration = $Disk.HyperVGeneration
        }

        if ($Disk.OsType) {
            $configParameters.OsType = $Disk.OsType
        }
    }

    $config = New-AzSnapshotConfig @configParameters
    $snapshot = New-AzSnapshot -Snapshot $config -ResourceGroupName $SnapshotResourceGroupName -SnapshotName $SnapshotName -ErrorAction Stop

    return [pscustomobject]@{
        SourceKind            = 'Snapshot'
        SourceResourceId      = $snapshot.Id
        SnapshotName          = $snapshot.Name
        SnapshotId            = $snapshot.Id
        SnapshotResourceGroup = $SnapshotResourceGroupName
        SnapshotSubscriptionId = (Get-SubscriptionIdFromResourceId -ResourceId $snapshot.Id)
        Incremental           = $Incremental
        CapturedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
        Disk                  = $Disk
    }
}

function New-VmRestorePointSet {
    <#
    .SYNOPSIS
        Creates a VM restore point, which Azure captures across all disks as one
        crash-consistent set.

    .DESCRIPTION
        Preferred over per-disk snapshots whenever the VM has to stay running, because
        individual snapshots of a live multi-disk VM are taken seconds or minutes apart and
        a SQL Server data file can end up newer than its own log.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$BatchTimestamp,

        [Parameter(Mandatory = $true)]
        [object[]]$Disk
    )

    $collectionName = New-AzureResourceName -Prefix $Vm.Name -Discriminator 'rpc' -Suffix $BatchTimestamp
    $restorePointName = New-AzureResourceName -Prefix $Vm.Name -Discriminator 'rp' -Suffix $BatchTimestamp

    Write-Detail ("Creating restore point collection '{0}'." -f $collectionName)
    $null = New-AzRestorePointCollection -ResourceGroupName $ResourceGroupName -Name $collectionName -SourceId $Vm.Id -Location $Vm.Location -ErrorAction Stop

    Write-Detail ("Creating restore point '{0}'. This can take several minutes." -f $restorePointName)
    $null = New-AzRestorePoint -ResourceGroupName $ResourceGroupName -RestorePointCollectionName $collectionName -Name $restorePointName -ErrorAction Stop

    $restorePoint = Get-AzRestorePoint -ResourceGroupName $ResourceGroupName -RestorePointCollectionName $collectionName -Name $restorePointName -ErrorAction Stop

    $storageProfile = $restorePoint.SourceMetadata.StorageProfile
    $results = @()

    $osDiskRestorePointId = $storageProfile.OsDisk.DiskRestorePoint.Id
    $osDisk = @($Disk | Where-Object { $_.DiskRole -eq 'OS' }) | Select-Object -First 1
    $results += [pscustomobject]@{
        SourceKind             = 'DiskRestorePoint'
        SourceResourceId       = $osDiskRestorePointId
        SnapshotName           = $restorePointName
        SnapshotId             = $osDiskRestorePointId
        SnapshotResourceGroup  = $ResourceGroupName
        SnapshotSubscriptionId = (Get-SubscriptionIdFromResourceId -ResourceId $osDiskRestorePointId)
        Incremental            = $false
        CapturedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
        Disk                   = $osDisk
    }

    foreach ($dataDisk in @($storageProfile.DataDisks)) {
        $lun = [int]$dataDisk.Lun
        $matchingDisk = @($Disk | Where-Object { $_.DiskRole -eq 'Data' -and $_.Lun -eq $lun }) | Select-Object -First 1
        if (-not $matchingDisk) {
            throw ("The restore point reported a data disk at LUN {0} that was not present in the captured disk inventory." -f $lun)
        }

        $results += [pscustomobject]@{
            SourceKind             = 'DiskRestorePoint'
            SourceResourceId       = $dataDisk.DiskRestorePoint.Id
            SnapshotName           = $restorePointName
            SnapshotId             = $dataDisk.DiskRestorePoint.Id
            SnapshotResourceGroup  = $ResourceGroupName
            SnapshotSubscriptionId = (Get-SubscriptionIdFromResourceId -ResourceId $dataDisk.DiskRestorePoint.Id)
            Incremental            = $false
            CapturedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
            Disk                   = $matchingDisk
        }
    }

    return [pscustomobject]@{
        RestorePointCollectionName = $collectionName
        RestorePointName           = $restorePointName
        Entries                    = @($results)
    }
}

#endregion


#region Main

$originalContext = $null
$transcriptPath = $null

try {
    if (-not $OutputDirectory) {
        $OutputDirectory = (Get-Location).Path
    }

    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        $null = New-Item -Path $OutputDirectory -ItemType Directory -Force
    }

    $batchTimestamp = New-BatchTimestamp
    $transcriptPath = Start-RunTranscript -Path (Join-Path -Path $OutputDirectory -ChildPath ("capture-{0}-{1}.log" -f $VmName, $batchTimestamp))

    Write-Step 'Checking prerequisites'
    Assert-AzModule -Name @('Az.Accounts', 'Az.Compute', 'Az.Network')
    $originalContext = Save-AzContextState
    $null = Connect-AzIfNeeded -SubscriptionId $SubscriptionId

    Write-Step ("Locating VM '{0}'" -f $VmName)
    $search = Find-AzVmAcrossSubscriptions -Name $VmName -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName
    Write-Detail ("Search method: {0}" -f $search.Method)

    if ($search.UnreadableSubscriptions.Count -gt 0) {
        # A swallowed per-subscription failure turns a genuine duplicate name into a false
        # "unique match", so this is surfaced rather than ignored.
        Write-Warning 'Some subscriptions could not be searched, so the uniqueness check below is not conclusive:'
        foreach ($entry in $search.UnreadableSubscriptions) {
            Write-Warning ("  {0}" -f $entry)
        }
    }

    if ($search.Matches.Count -eq 0) {
        throw ("VM '{0}' was not found in any accessible subscription. Narrow the search with -SubscriptionId and -ResourceGroupName if you know where it lives." -f $VmName)
    }

    if ($search.Matches.Count -gt 1) {
        $summary = ($search.Matches | ForEach-Object { "Subscription={0} ResourceGroup={1}" -f $_.SubscriptionId, $_.ResourceGroupName }) -join [Environment]::NewLine
        throw ("Multiple VMs named '{0}' were found:{1}{2}{1}Disambiguate with -SubscriptionId and -ResourceGroupName." -f $VmName, [Environment]::NewLine, $summary)
    }

    $match = $search.Matches[0]
    $context = Set-AzSubscriptionContext -SubscriptionId $match.SubscriptionId
    $subscriptionName = $context.Subscription.Name

    # Re-fetch the VM by name. The objects returned by a Get-AzVM listing are less complete
    # than a targeted get, and several properties this toolkit depends on are absent there.
    $vm = Get-AzVM -ResourceGroupName $match.ResourceGroupName -Name $match.Name -ErrorAction Stop
    Write-Ok ("Found {0} in {1} / {2} ({3}, size {4})" -f $vm.Name, $subscriptionName, $vm.ResourceGroupName, $vm.Location, $vm.HardwareProfile.VmSize)

    if (-not $SnapshotResourceGroupName) {
        $SnapshotResourceGroupName = $vm.ResourceGroupName
    }

    Write-Step 'Reading disk inventory'
    $disks = @()
    $disks += Get-DiskDetail -AttachedDisk $vm.StorageProfile.OsDisk -DiskRole 'OS'
    foreach ($dataDisk in @($vm.StorageProfile.DataDisks)) {
        $disks += Get-DiskDetail -AttachedDisk $dataDisk -DiskRole 'Data'
    }

    foreach ($disk in $disks) {
        $label = if ($disk.DiskRole -eq 'OS') { 'OS  ' } else { ('LUN{0}' -f $disk.Lun) }
        Write-Detail ("{0}  {1,-40} {2,-16} {3,6} GB  caching={4}" -f $label, $disk.DiskName, $disk.SkuName, $disk.DiskSizeGB, $disk.Caching)
    }

    if (@($disks | Where-Object { $_.SkuName -eq 'UltraSSD_LRS' -or $_.SkuName -eq 'PremiumV2_LRS' }).Count -gt 0) {
        Add-FidelityGap 'One or more disks are Ultra or Premium SSD v2. These have restricted snapshot support; verify the snapshot and restore path for them before relying on this toolkit for the cutover.'
    }

    if (@($disks | Where-Object { $_.AzureDiskEncryptionEnabled }).Count -gt 0) {
        Add-FidelityGap 'One or more disks use Azure Disk Encryption (in-guest BitLocker/dm-crypt). Restoring these requires the original Key Vault secret and key encryption key to be reattached to the new VM manually.'
    }

    if (@($disks | Where-Object { $_.WriteAcceleratorEnabled }).Count -gt 0) {
        Write-Detail 'Write Accelerator is enabled on at least one disk; it is only supported on M-series sizes and will be re-applied at attach time.'
    }

    Write-Step 'Capturing VM configuration'
    $sourceVm = Get-VmCoreProperties -Vm $vm -SubscriptionId $match.SubscriptionId -SubscriptionName $subscriptionName
    $osProfile = Get-VmOsProfileProperties -Vm $vm
    $identity = Get-VmIdentityProperties -Vm $vm

    if ($identity -and ([string]$identity.Type) -match 'SystemAssigned') {
        Add-FidelityGap 'The VM has a SYSTEM-assigned managed identity. The replacement VM gets a brand new principal ID, so every role assignment, Key Vault access policy and SQL login granted to the old identity must be re-granted. Consider moving to a user-assigned identity before cutover.'
    }

    if ($osProfile -and $osProfile.WindowsConfiguration -and $osProfile.WindowsConfiguration.PatchSettings) {
        Write-Detail ("Guest patch mode: {0}, assessment mode: {1}" -f $osProfile.WindowsConfiguration.PatchSettings.PatchMode, $osProfile.WindowsConfiguration.PatchSettings.AssessmentMode)
    }

    if ($sourceVm.Plan) {
        Write-Detail ("Marketplace plan: {0}/{1}/{2}" -f $sourceVm.Plan.Publisher, $sourceVm.Plan.Product, $sourceVm.Plan.Name)
    }

    Write-Step 'Capturing network configuration'
    $nics = @()
    foreach ($nicReference in @($vm.NetworkProfile.NetworkInterfaces)) {
        $nics += Get-NetworkInterfaceDetail -NicReference $nicReference
    }

    # When no NIC is flagged primary, Azure treats the first as primary. Make that explicit
    # so the restore script does not have to guess.
    if (@($nics | Where-Object { $_.IsPrimary }).Count -eq 0 -and $nics.Count -gt 0) {
        $nics[0].IsPrimary = $true
    }

    foreach ($nic in $nics) {
        $primaryIp = @($nic.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
        if (-not $primaryIp) {
            $primaryIp = @($nic.IpConfigurations) | Select-Object -First 1
        }

        Write-Detail ("NIC {0}{1}: {2} ({3})" -f $nic.Name, $(if ($nic.IsPrimary) { ' [primary]' } else { '' }), $primaryIp.PrivateIpAddress, $primaryIp.PrivateIpAllocationMethod)
    }

    if ($nics.Count -gt 1) {
        Add-FidelityGap ("The VM has {0} network interfaces. The restore script recreates or reuses the PRIMARY NIC only; the others must be attached by hand." -f $nics.Count)
    }

    $lbBound = @($nics | ForEach-Object { $_.IpConfigurations } | Where-Object { $_.LoadBalancerBackendAddressPoolIds.Count -gt 0 -or $_.ApplicationGatewayBackendAddressPoolIds.Count -gt 0 })
    if ($lbBound.Count -gt 0) {
        Add-FidelityGap 'The VM is a member of a load balancer or application gateway backend pool. Reusing the original NIC preserves that membership; creating a new NIC does not, and the VM will silently drop out of the pool.'
    }

    Write-Step 'Capturing attached resources'
    $extensionsSection = Invoke-CaptureSection -Name 'VM extensions' -ScriptBlock { Get-VmExtensionDetail -Vm $vm }
    $backupSection = Invoke-CaptureSection -Name 'Azure Backup protection' -RequiredModule 'Az.RecoveryServices' -ScriptBlock { Get-VmBackupProtection -Vm $vm }

    $sqlWorkloadSection = [pscustomobject]@{ Status = 'Skipped'; Reason = 'VM backup protection was not captured.'; Data = $null }
    if ($backupSection.Status -eq 'Captured' -and $backupSection.Data.VaultId) {
        $vaultId = $backupSection.Data.VaultId
        $sqlWorkloadSection = Invoke-CaptureSection -Name 'SQL workload backup' -RequiredModule 'Az.RecoveryServices' -ScriptBlock { Get-VmSqlWorkloadBackup -Vm $vm -VaultId $vaultId }
    }

    $maintenanceSection = Invoke-CaptureSection -Name 'Maintenance assignments' -RequiredModule 'Az.Maintenance' -ScriptBlock { Get-VmMaintenanceAssignments -Vm $vm }
    $sqlVmSection = Invoke-CaptureSection -Name 'SQL VM registration' -RequiredModule 'Az.SqlVirtualMachine' -ScriptBlock { Get-SqlVirtualMachineDetail -Vm $vm }
    $dcrSection = Invoke-CaptureSection -Name 'Data collection rule associations' -RequiredModule 'Az.Monitor' -ScriptBlock {
        @(Get-AzDataCollectionRuleAssociation -TargetResourceId $vm.Id -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name                    = $_.Name
                DataCollectionRuleId    = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('DataCollectionRuleId')
                DataCollectionEndpointId = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('DataCollectionEndpointId')
                # Associations stamped with a provisioning owner belong to Defender for
                # Cloud, VM Insights, Change Tracking or Sentinel. The restore script must
                # not recreate those by hand; the owning feature has to do it.
                ProvisionedBy           = Get-ObjectPropertyValue -InputObject (Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Metadata')) -PropertyNames @('ProvisionedBy')
            }
        })
    }

    $roleAssignmentSection = Invoke-CaptureSection -Name 'Role assignments at VM scope' -RequiredModule 'Az.Resources' -ScriptBlock {
        @(Get-AzRoleAssignment -Scope $vm.Id -ErrorAction Stop |
            Where-Object { $_.Scope -eq $vm.Id } |
            ForEach-Object {
                [pscustomobject]@{
                    DisplayName        = $_.DisplayName
                    ObjectId           = $_.ObjectId
                    ObjectType         = $_.ObjectType
                    RoleDefinitionName = $_.RoleDefinitionName
                    RoleDefinitionId   = $_.RoleDefinitionId
                    Scope              = $_.Scope
                }
            })
    }

    $lockSection = Invoke-CaptureSection -Name 'Resource locks' -RequiredModule 'Az.Resources' -ScriptBlock {
        @(Get-AzResourceLock -Scope $vm.Id -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{
                Name       = $_.Name
                Level      = [string]$_.Properties.level
                Notes      = [string]$_.Properties.notes
                ResourceId = $_.ResourceId
            }
        })
    }

    if ($dcrSection.Status -eq 'Captured') {
        Add-FidelityGap 'Data collection rule associations exist. They are scoped to the old VM resource ID and are recreated against the new VM by the restore script, but verify Azure Monitor data is flowing afterwards.'
    }

    if ($roleAssignmentSection.Status -eq 'Captured') {
        Add-FidelityGap 'Role assignments are scoped directly to the VM resource. The new VM has a different resource ID, so these must be re-granted; they are recorded in the manifest for reference.'
    }

    if ($lockSection.Status -eq 'Captured') {
        Add-FidelityGap 'The VM carries a resource lock. It will not be copied to the new VM, and it may also block the source VM deletion step of the cutover.'
    }

    Write-Step 'Checking consistency preconditions'
    $powerState = Get-VmPowerState -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
    Write-Detail ("Power state: {0}" -f $powerState)

    if ($ConsistencyMode -eq 'Deallocated' -and $powerState -ne 'PowerState/deallocated') {
        if ($DeallocateVm) {
            if ($PSCmdlet.ShouldProcess($vm.Name, 'Deallocate the source VM so its disks can be snapshotted consistently')) {
                Write-Detail 'Deallocating the source VM. This stops the workload.'
                $null = Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -ErrorAction Stop
                $powerState = Get-VmPowerState -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name
                if ($powerState -ne 'PowerState/deallocated') {
                    throw ("The VM did not reach a deallocated state; it reports '{0}'." -f $powerState)
                }

                Write-Ok 'Source VM deallocated.'
            }
            else {
                throw 'Deallocation declined, so a consistent snapshot set cannot be taken. Rerun with -ConsistencyMode RestorePoint for a live crash-consistent capture.'
            }
        }
        else {
            throw ("ConsistencyMode is 'Deallocated' but the VM reports '{0}'. Shut the VM down and deallocate it, rerun with -DeallocateVm to have this script do it, or use -ConsistencyMode RestorePoint to capture a crash-consistent set while it runs." -f $powerState)
        }
    }

    if ($ConsistencyMode -eq 'LiveUnsafe') {
        Add-FidelityGap 'Snapshots were taken per-disk on a RUNNING VM. The disks do not share a point in time and the set is not guaranteed to be recoverable. Do not cut over to it.'
        if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Take per-disk snapshots of a RUNNING VM, producing a set that is NOT guaranteed to be recoverable')) {
            throw 'Live unsafe capture declined.'
        }
    }

    $snapshotEntries = @()
    $restorePointInfo = $null

    if ($SkipSnapshots) {
        Write-Step 'Skipping snapshot creation (-SkipSnapshots)'
        Write-Detail 'The manifest will be written without any disk source, and cannot be restored from.'
    }
    elseif ($ConsistencyMode -eq 'RestorePoint') {
        Write-Step 'Creating a crash-consistent VM restore point'
        if ($PSCmdlet.ShouldProcess($vm.Name, 'Create a VM restore point collection and restore point')) {
            $restorePointInfo = New-VmRestorePointSet -Vm $vm -ResourceGroupName $SnapshotResourceGroupName -BatchTimestamp $batchTimestamp -Disk $disks
            $snapshotEntries = @($restorePointInfo.Entries)
            Write-Ok ("Restore point '{0}' created with {1} disk restore point(s)." -f $restorePointInfo.RestorePointName, $snapshotEntries.Count)
        }
    }
    else {
        Write-Step 'Creating disk snapshots'
        $plan = New-DiskSnapshotPlan -Disk $disks -VmName $vm.Name -BatchTimestamp $batchTimestamp

        $snapshotTags = @{
            'vm-rebuild-toolkit'  = 'true'
            'vm-rebuild-source'   = $vm.Name
            'vm-rebuild-batch'    = $batchTimestamp
        }

        if ($SnapshotTag) {
            foreach ($key in $SnapshotTag.Keys) {
                $snapshotTags[$key] = [string]$SnapshotTag[$key]
            }
        }

        $useIncremental = -not $FullSnapshot.IsPresent
        Write-Detail ("{0} snapshots, SKU {1}, into resource group '{2}'." -f $(if ($useIncremental) { 'Incremental' } else { 'Full' }), $SnapshotSkuName, $SnapshotResourceGroupName)

        foreach ($entry in $plan) {
            if (-not $PSCmdlet.ShouldProcess($entry.SnapshotName, 'Create disk snapshot')) {
                throw 'Snapshot creation declined; aborting so a partial set is not left behind.'
            }

            $created = New-DiskSnapshot -Disk $entry.Disk -SnapshotName $entry.SnapshotName -SnapshotResourceGroupName $SnapshotResourceGroupName -Location $vm.Location -SkuName $SnapshotSkuName -Incremental $useIncremental -Tag $snapshotTags
            $snapshotEntries += $created
            Write-Ok ("{0}" -f $created.SnapshotName)
        }
    }

    Write-Step 'Writing manifest'

    $osEntry = @($snapshotEntries | Where-Object { $_.Disk.DiskRole -eq 'OS' }) | Select-Object -First 1
    $dataEntries = @($snapshotEntries | Where-Object { $_.Disk.DiskRole -eq 'Data' } | Sort-Object { $_.Disk.Lun })

    $manifest = [pscustomobject]@{
        SchemaVersion  = $script:VmRebuildManifestSchemaVersion
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        GeneratedBy    = [pscustomobject]@{
            Script            = 'save-vm-snapshot-manifest.ps1'
            PowerShellVersion = $PSVersionTable.PSVersion.ToString()
            Account           = (Get-AzContext).Account.Id
            Machine           = $env:COMPUTERNAME
        }
        Capture        = [pscustomobject]@{
            BatchTimestamp     = $batchTimestamp
            ConsistencyMode    = $ConsistencyMode
            PowerStateAtCapture = $powerState
            IsConsistent       = ($ConsistencyMode -eq 'Deallocated' -and $powerState -eq 'PowerState/deallocated') -or ($ConsistencyMode -eq 'RestorePoint')
            SnapshotsCreated   = (-not $SkipSnapshots.IsPresent)
            IncrementalSnapshots = (-not $FullSnapshot.IsPresent)
            SnapshotSkuName    = $SnapshotSkuName
            RestorePointCollectionName = (Get-ObjectPropertyValue -InputObject $restorePointInfo -PropertyNames @('RestorePointCollectionName'))
            RestorePointName   = (Get-ObjectPropertyValue -InputObject $restorePointInfo -PropertyNames @('RestorePointName'))
        }
        SourceVm       = $sourceVm
        OsProfile      = $osProfile
        Identity       = $identity
        Disks          = @($disks)
        Network        = [pscustomobject]@{
            NetworkInterfaces = @($nics)
        }
        Extensions     = $extensionsSection
        BackupProtection = $backupSection
        SqlWorkloadBackup = $sqlWorkloadSection
        MaintenanceAssignments = $maintenanceSection
        SqlVirtualMachine = $sqlVmSection
        DataCollectionRuleAssociations = $dcrSection
        RoleAssignments = $roleAssignmentSection
        ResourceLocks  = $lockSection
        Snapshots      = [pscustomobject]@{
            OsDisk    = $osEntry
            DataDisks = @($dataEntries)
        }
        FidelityGaps   = @($script:FidelityGaps)
    }

    $manifestPath = Join-Path -Path $OutputDirectory -ChildPath ("{0}-snapshot-manifest-{1}.json" -f $vm.Name, $batchTimestamp)
    $null = Write-JsonFile -InputObject $manifest -Path $manifestPath -Depth 32
    Write-Ok ("Manifest: {0}" -f $manifestPath)

    # Raw archive: everything the manifest normalises away, kept verbatim so an engineer
    # can look up a setting the toolkit does not know how to replay.
    $archive = [pscustomobject]@{
        VirtualMachine   = $vm
        NetworkInterfaces = @(@($vm.NetworkProfile.NetworkInterfaces) | ForEach-Object { Get-AzNetworkInterface -ResourceId $_.Id -ErrorAction SilentlyContinue })
        Disks            = @(@($disks) | ForEach-Object { Get-AzDisk -ResourceGroupName $_.DiskResourceGroupName -DiskName $_.DiskName -ErrorAction SilentlyContinue })
        Extensions       = $extensionsSection.Data
        SqlVirtualMachine = $sqlVmSection.Data
    }

    $archivePath = Join-Path -Path $OutputDirectory -ChildPath ("{0}-raw-archive-{1}.json" -f $vm.Name, $batchTimestamp)
    try {
        $null = Write-JsonFile -InputObject $archive -Path $archivePath -Depth 12
        Write-Ok ("Raw archive: {0}" -f $archivePath)
    }
    catch {
        Write-Warning ("Could not write the raw archive. The manifest is still valid. {0}" -f $_.Exception.Message)
        $archivePath = $null
    }

    Write-Step 'Summary'
    Write-Detail ("Source VM        : {0} ({1})" -f $vm.Name, $vm.HardwareProfile.VmSize)
    Write-Detail ("Consistency      : {0} / power state {1}" -f $ConsistencyMode, $powerState)
    Write-Detail ("Disks captured   : {0} ({1} data)" -f $disks.Count, @($disks | Where-Object { $_.DiskRole -eq 'Data' }).Count)
    Write-Detail ("Disk sources     : {0}" -f $snapshotEntries.Count)

    if ($script:FidelityGaps.Count -gt 0) {
        Write-Host ''
        Write-Host ("{0} setting(s) cannot be replayed automatically and need manual action:" -f $script:FidelityGaps.Count) -ForegroundColor Yellow
        $index = 1
        foreach ($gap in $script:FidelityGaps) {
            Write-Host ("  {0}. {1}" -f $index, $gap) -ForegroundColor Yellow
            $index++
        }
    }

    Write-Host ''
    Write-Host 'Next: review the manifest, then run release-vm-network-address.ps1 to free the source IP, then new-vm-from-snapshot-manifest.ps1 -PreflightOnly.' -ForegroundColor Cyan

    [pscustomobject]@{
        ManifestPath   = $manifestPath
        RawArchivePath = $archivePath
        TranscriptPath = $transcriptPath
        VmName         = $vm.Name
        SubscriptionId = $match.SubscriptionId
        ResourceGroupName = $vm.ResourceGroupName
        ConsistencyMode = $ConsistencyMode
        PowerStateAtCapture = $powerState
        DiskCount      = $disks.Count
        SnapshotCount  = $snapshotEntries.Count
        FidelityGaps   = @($script:FidelityGaps)
    }
}
finally {
    Restore-AzContextState -Context $originalContext
    Stop-RunTranscript
}

#endregion
