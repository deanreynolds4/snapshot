<#
.SYNOPSIS
    Creates a restorable snapshot set for an Azure VM and writes a manifest that can be used to build a replacement VM from those snapshots.

.DESCRIPTION
    This script is intended for VM migration and recovery scenarios where the operating system disk and attached data disks need to be preserved
    and reattached to a new VM definition, such as moving from a SKU without temporary storage to one that includes a temp disk.

    Workflow:
    - Signs in to Azure and prompts for the source VM name.
    - Enumerates all accessible subscriptions and searches for an exact VM name match.
    - Stops with a clear error if the VM is not found or if the same VM name exists in more than one accessible subscription or resource group.
    - Switches to the matched subscription context and generates one timestamp value for the whole snapshot batch.
    - Creates snapshots for the OS disk and every attached data disk by copying from the managed disk resource IDs.
    - Uses a consistent snapshot naming convention based on VM name, cleaned disk name, and timestamp.
    - Collects rebuild metadata into a JSON manifest, including source subscription, resource group, location, zone, VM size, OS type, tags,
            selected security settings, primary NIC subnet and IP metadata, capacity reservation group, backup protection details, direct maintenance assignments, SQL VM
            registration metadata, and the created snapshot identifiers.
    - Writes the manifest to the current working directory so the companion restore script can create managed disks and a replacement VM from
      the snapshot set.

.EXAMPLE
    pwsh ./script.ps1

    Signs in to Azure if required, prompts for the source VM name, creates snapshots for the matched VM, and writes a manifest JSON file in the
    current directory.

.EXAMPLE
    Get-Help ./script.ps1 -Full

    Displays the full built-in help for the capture script, including workflow notes and restore handoff details.

.NOTES
    Original Author: Vivek Chandran
    Date Created: 11-09-2023
    Companion Script: new-vm-from-snapshot-manifest.ps1
    Requirements: Az.Accounts, Az.Compute, and Az.Network modules, plus rights to read the source VM and create snapshots in the source resource group.
    Output: Azure snapshots in the source resource group and a local manifest file named <vm>-snapshot-manifest-<timestamp>.json.
    Safety: This script does not stop, deallocate, or delete the source VM, and application consistency still depends on the workload state at capture time.
#>

$ErrorActionPreference = 'Stop'

function Get-CleanDiskName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DiskName
    )

    $nameParts = $DiskName -split '_'
    if ($nameParts.Count -ge 2) {
        return ($nameParts[0..1] -join '_')
    }

    return $DiskName
}

function Get-PrimaryNetworkInterface {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    $primaryNicReference = $Vm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary } | Select-Object -First 1
    if (-not $primaryNicReference) {
        $primaryNicReference = $Vm.NetworkProfile.NetworkInterfaces | Select-Object -First 1
    }

    if (-not $primaryNicReference) {
        return $null
    }

    try {
        return Get-AzNetworkInterface -ResourceId $primaryNicReference.Id
    }
    catch {
        Write-Warning "Unable to retrieve metadata for the VM network interface '$($primaryNicReference.Id)'. $($_.Exception.Message)"
        return $null
    }
}

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

function Get-ResourceGroupNameFromResourceId {
    param(
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    if ($ResourceId -match '/resourceGroups/([^/]+)/') {
        return $Matches[1]
    }

    return $null
}

function Get-SourceVmMaintenanceAssignments {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    try {
        $assignments = Get-AzConfigurationAssignment -ProviderName 'Microsoft.Compute' -ResourceGroupName $Vm.ResourceGroupName -ResourceType 'virtualMachines' -ResourceName $Vm.Name -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to read maintenance configuration assignments for VM '$($Vm.Name)'. $($_.Exception.Message)"
        return @()
    }

    return @($assignments | ForEach-Object {
        [pscustomobject]@{
            ConfigurationAssignmentName = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Name', 'ConfigurationAssignmentName')
            MaintenanceConfigurationId  = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('MaintenanceConfigurationId')
            Location                    = Get-ObjectPropertyValue -InputObject $_ -PropertyNames @('Location')
        }
    })
}

function Get-SourceVmBackupProtection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    try {
        $backupStatus = Get-AzRecoveryServicesBackupStatus -Name $Vm.Name -ResourceGroupName $Vm.ResourceGroupName -Type AzureVM -ErrorAction Stop
    }
    catch {
        Write-Warning "Unable to determine Recovery Services backup status for VM '$($Vm.Name)'. $($_.Exception.Message)"
        return $null
    }

    $vaultId = Get-ObjectPropertyValue -InputObject $backupStatus -PropertyNames @('VaultId')
    $vaultName = Get-ObjectPropertyValue -InputObject $backupStatus -PropertyNames @('VaultName')
    if (-not $vaultName -and $vaultId -match '/vaults/([^/]+)$') {
        $vaultName = $Matches[1]
    }

    $isProtectedValue = Get-ObjectPropertyValue -InputObject $backupStatus -PropertyNames @('BackedUp', 'IsBackedUp', 'Protected')
    $isProtected = [bool]$isProtectedValue
    if (-not $isProtected -and $vaultId) {
        $isProtected = $true
    }

    $policyName = $null
    $lastBackupStatus = $null
    $lastBackupTime = $null

    if ($vaultId) {
        try {
            $container = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVM -FriendlyName $Vm.Name -VaultId $vaultId -ErrorAction Stop | Select-Object -First 1
            if ($container) {
                $backupItem = Get-AzRecoveryServicesBackupItem -Container $container -WorkloadType AzureVM -VaultId $vaultId -ErrorAction Stop | Select-Object -First 1
                if ($backupItem) {
                    $policyName = Get-ObjectPropertyValue -InputObject $backupItem -PropertyNames @('PolicyName', 'ProtectionPolicyName')
                    $lastBackupStatus = Get-ObjectPropertyValue -InputObject $backupItem -PropertyNames @('LastBackupStatus')
                    $lastBackupTime = Get-ObjectPropertyValue -InputObject $backupItem -PropertyNames @('LastBackupTime')
                }
            }
        }
        catch {
            Write-Warning "Unable to resolve Recovery Services backup policy details for VM '$($Vm.Name)'. $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{
        IsProtected            = $isProtected
        BackupManagementType   = 'AzureVM'
        WorkloadType           = 'AzureVM'
        VaultId                = $vaultId
        VaultName              = $vaultName
        VaultResourceGroupName = Get-ResourceGroupNameFromResourceId -ResourceId $vaultId
        PolicyName             = $policyName
        ProtectionStatus       = Get-ObjectPropertyValue -InputObject $backupStatus -PropertyNames @('ProtectionStatus', 'Status')
        LastBackupStatus       = $lastBackupStatus
        LastBackupTime         = $lastBackupTime
    }
}

function Get-SourceSqlVirtualMachineMetadata {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm
    )

    try {
        $sqlVm = Get-AzSqlVM -ResourceGroupName $Vm.ResourceGroupName -Name $Vm.Name -ErrorAction Stop
    }
    catch {
        return $null
    }

    if (-not $sqlVm) {
        return $null
    }

    return [pscustomobject]@{
        IsRegistered       = $true
        Name               = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Name')
        Id                 = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Id')
        ResourceGroupName  = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('ResourceGroupName')
        LicenseType        = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('LicenseType')
        Offer              = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Offer')
        Sku                = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('Sku')
        SqlManagementType  = Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('SqlManagementType')
        EnableAutoUpgrade  = [bool](Get-ObjectPropertyValue -InputObject $sqlVm -PropertyNames @('EnableAutomaticUpgrade'))
    }
}

function New-VmDiskSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Vm,

        [Parameter(Mandatory = $true)]
        [object]$Disk,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$DiskType,

        [Parameter(Mandatory = $true)]
        [string]$SnapshotTimestamp
    )

    $diskResourceId = $Disk.ManagedDisk.Id
    if ([string]::IsNullOrWhiteSpace($diskResourceId)) {
        throw "Unable to determine the managed disk resource ID for the $DiskType disk '$($Disk.Name)'."
    }

    $cleanedDiskName = Get-CleanDiskName -DiskName $Disk.Name
    $snapshotName = "$($Vm.Name)-$cleanedDiskName-$SnapshotTimestamp"

    $snapshotConfig = New-AzSnapshotConfig -SourceResourceId $diskResourceId -Location $Vm.Location -CreateOption Copy -AccountType Standard_LRS
    $createdSnapshot = New-AzSnapshot -Snapshot $snapshotConfig -ResourceGroupName $ResourceGroupName -SnapshotName $snapshotName

    Write-Host "Snapshot created for $DiskType disk: $snapshotName"

    return [pscustomobject]@{
        DiskType              = $DiskType
        SnapshotName          = $snapshotName
        SnapshotId            = $createdSnapshot.Id
        SnapshotResourceGroup = $ResourceGroupName
        SourceDiskName        = $Disk.Name
        SourceDiskResourceId  = $diskResourceId
        StorageAccountType    = $Disk.ManagedDisk.StorageAccountType
        Lun                   = $Disk.Lun
        Caching               = [string]$Disk.Caching
    }
}

try {
    Connect-AzAccount | Out-Null

    $computerName = Read-Host -Prompt "Please enter the name of the VM you want to snapshot"
    if ([string]::IsNullOrWhiteSpace($computerName)) {
        throw "VM name cannot be empty."
    }

    $subscriptions = Get-AzSubscription
    if (-not $subscriptions) {
        throw "No Azure subscriptions were returned for the current account."
    }

    $matchingVms = @()

    foreach ($subscription in $subscriptions) {
        Write-Host "Searching subscription '$($subscription.Name)' for VM '$computerName'..."

        try {
            $null = Set-AzContext -SubscriptionId $subscription.Id
            $subscriptionMatches = Get-AzVM | Where-Object { $_.Name -eq $computerName }
        }
        catch {
            Write-Warning "Skipping subscription '$($subscription.Name)' because it could not be queried. $($_.Exception.Message)"
            continue
        }

        foreach ($match in $subscriptionMatches) {
            $matchingVms += [pscustomobject]@{
                SubscriptionId   = $subscription.Id
                SubscriptionName = $subscription.Name
                Vm               = $match
            }
        }
    }

    if (-not $matchingVms) {
        throw "VM '$computerName' was not found in any accessible subscription."
    }

    if ($matchingVms.Count -gt 1) {
        $duplicateSummary = $matchingVms | ForEach-Object {
            "Subscription='$($_.SubscriptionName)', ResourceGroup='$($_.Vm.ResourceGroupName)', VM='$($_.Vm.Name)'"
        }

        throw "Multiple VMs named '$computerName' were found:`n$($duplicateSummary -join [Environment]::NewLine)`nNarrow the search and rerun the script."
    }

    $selectedMatch = $matchingVms[0]
    $vm = $selectedMatch.Vm
    $resourceGroup = $vm.ResourceGroupName
    $snapshotTimestamp = Get-Date -Format 'dd-MM-yyyy_HH_mm'

    $null = Set-AzContext -SubscriptionId $selectedMatch.SubscriptionId
    Write-Host "VM '$computerName' found in subscription '$($selectedMatch.SubscriptionName)' and resource group '$resourceGroup'."

    $dataDiskSnapshots = @()
    if (-not $vm.StorageProfile.DataDisks) {
        Write-Host "No data disks are attached to VM '$computerName'."
    }
    else {
        foreach ($disk in $vm.StorageProfile.DataDisks) {
            $dataDiskSnapshots += New-VmDiskSnapshot -Vm $vm -Disk $disk -ResourceGroupName $resourceGroup -DiskType 'data' -SnapshotTimestamp $snapshotTimestamp
        }
    }

    $osDiskSnapshot = New-VmDiskSnapshot -Vm $vm -Disk $vm.StorageProfile.OsDisk -ResourceGroupName $resourceGroup -DiskType 'OS' -SnapshotTimestamp $snapshotTimestamp

    $primaryNic = Get-PrimaryNetworkInterface -Vm $vm
    $primaryIpConfiguration = $null
    if ($primaryNic) {
        $primaryIpConfiguration = $primaryNic.IpConfigurations | Where-Object { $_.Primary } | Select-Object -First 1
        if (-not $primaryIpConfiguration) {
            $primaryIpConfiguration = $primaryNic.IpConfigurations | Select-Object -First 1
        }
    }

    $backupProtection = Get-SourceVmBackupProtection -Vm $vm
    $maintenanceAssignments = @(Get-SourceVmMaintenanceAssignments -Vm $vm)
    $sqlVirtualMachine = Get-SourceSqlVirtualMachineMetadata -Vm $vm
    $capacityReservationGroupId = $null
    $capacityReservationGroup = Get-ObjectPropertyValue -InputObject $vm.CapacityReservation -PropertyNames @('CapacityReservationGroup')
    if ($capacityReservationGroup) {
        $capacityReservationGroupId = Get-ObjectPropertyValue -InputObject $capacityReservationGroup -PropertyNames @('Id')
    }

    $manifestPath = Join-Path -Path (Get-Location).Path -ChildPath ("{0}-snapshot-manifest-{1}.json" -f $vm.Name, $snapshotTimestamp)
    $manifest = [pscustomobject]@{
        SchemaVersion          = 1
        GeneratedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
        SnapshotBatchTimestamp = $snapshotTimestamp
        SourceVm               = [pscustomobject]@{
            Name                      = $vm.Name
            Id                        = $vm.Id
            SubscriptionId            = $selectedMatch.SubscriptionId
            SubscriptionName          = $selectedMatch.SubscriptionName
            ResourceGroupName         = $resourceGroup
            Location                  = $vm.Location
            Zones                     = @($vm.Zones)
            VmSize                    = $vm.HardwareProfile.VmSize
            OsType                    = [string]$vm.StorageProfile.OsDisk.OsType
            LicenseType               = $vm.LicenseType
            CapacityReservationGroupId = $capacityReservationGroupId
            AvailabilitySetId         = $vm.AvailabilitySetReference.Id
            ProximityPlacementGroupId = $vm.ProximityPlacementGroup.Id
            EncryptionAtHost          = [bool]$vm.SecurityProfile.EncryptionAtHost
            SecurityType              = $vm.SecurityProfile.SecurityType
            UefiSettings              = if ($vm.SecurityProfile.UefiSettings) {
                [pscustomobject]@{
                    SecureBootEnabled = [bool]$vm.SecurityProfile.UefiSettings.SecureBootEnabled
                    VTpmEnabled       = [bool]$vm.SecurityProfile.UefiSettings.VTpmEnabled
                }
            }
            else {
                $null
            }
            Tags = $vm.Tags
        }
        Network                = [pscustomobject]@{
            PrimaryNic = if ($primaryNic) {
                [pscustomobject]@{
                    Id                          = $primaryNic.Id
                    Name                        = $primaryNic.Name
                    ResourceGroupName           = $primaryNic.ResourceGroupName
                    SubnetId                    = $primaryIpConfiguration.Subnet.Id
                    PrivateIpAllocationMethod   = [string]$primaryIpConfiguration.PrivateIpAllocationMethod
                    PrivateIpAddress            = $primaryIpConfiguration.PrivateIpAddress
                    PublicIpAddressId           = $primaryIpConfiguration.PublicIpAddress.Id
                    NetworkSecurityGroupId      = $primaryNic.NetworkSecurityGroup.Id
                    EnableAcceleratedNetworking = [bool]$primaryNic.EnableAcceleratedNetworking
                }
            }
            else {
                $null
            }
        }
        BackupProtection        = $backupProtection
        MaintenanceAssignments  = @($maintenanceAssignments)
        SqlVirtualMachine       = $sqlVirtualMachine
        Snapshots              = [pscustomobject]@{
            OsDisk   = [pscustomobject]@{
                SnapshotName          = $osDiskSnapshot.SnapshotName
                SnapshotId            = $osDiskSnapshot.SnapshotId
                SnapshotResourceGroup = $osDiskSnapshot.SnapshotResourceGroup
                SourceDiskName        = $osDiskSnapshot.SourceDiskName
                SourceDiskResourceId  = $osDiskSnapshot.SourceDiskResourceId
                StorageAccountType    = $osDiskSnapshot.StorageAccountType
                Caching               = $osDiskSnapshot.Caching
            }
            DataDisks = @($dataDiskSnapshots)
        }
    }

    $manifest | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Write-Host "Snapshot manifest written to '$manifestPath'."

    Write-Host "Snapshot process completed successfully."
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
