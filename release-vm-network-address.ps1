#Requires -Version 5.1
<#
.SYNOPSIS
    Releases the source VM's private IP address (and optionally its public IP) so the
    replacement VM can claim the same address, and records a handover file that makes the
    change reversible.

.DESCRIPTION
    This is step 3 of the cutover. It exists because a private IP address stays owned by
    the NIC that holds it: deallocating or even stopping the source VM does not release it.
    Creating the replacement VM with the same address therefore fails until the address is
    moved off the old NIC.

    Rather than deleting the source NIC - which would destroy its load balancer membership,
    application security group membership and NSG association, and make rollback painful -
    this script reassigns the source NIC's primary IP configuration to a different, free
    "parking" address in the same subnet. The original address becomes available
    immediately, and the source VM stays intact and bootable for rollback.

    It also enforces the rule that only one of the two VMs is ever powered on: it refuses
    to release the address of a running VM unless you deallocate it first (or pass
    -DeallocateVm), because the moment the replacement boots with the same identity, the
    same hostname, the same AD computer account and the same SQL Server instance would be
    live twice.

    Run with -Rollback and the handover file to put the original address back.

.PARAMETER ManifestPath
    Manifest from save-vm-snapshot-manifest.ps1. Supplies the source VM, its NIC and the
    address to release, so nothing has to be typed twice.

.PARAMETER VmName
    Source VM name, when you are not working from a manifest.

.PARAMETER ResourceGroupName
    Source VM resource group. Required with -VmName.

.PARAMETER SubscriptionId
    Subscription containing the source VM. Required with -VmName.

.PARAMETER ParkingPrivateIpAddress
    The address to move the source NIC to. If omitted, the first free address in the
    subnet is chosen automatically and reported before anything changes.

.PARAMETER DetachPublicIp
    Also detaches the public IP from the source NIC, so the replacement VM can attach the
    same public IP resource.

.PARAMETER DeallocateVm
    Deallocates the source VM first if it is still running.

.PARAMETER HandoverPath
    Where to write (or, with -Rollback, read) the handover record. Defaults to a file next
    to the manifest.

.PARAMETER Rollback
    Restores the original private IP (and public IP) to the source NIC using the handover
    record. Fails if the address has since been claimed by the replacement VM, which is
    the correct behaviour: you must remove it from the replacement first.

.PARAMETER Force
    Skips the "source VM must not be running" guard. Only use this when you have already
    confirmed the replacement VM is not, and will not be, powered on at the same time.

.EXAMPLE
    .\release-vm-network-address.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-20260901-101500.json -WhatIf

    Shows which address would be released and which parking address would be used, without
    changing anything.

.EXAMPLE
    .\release-vm-network-address.ps1 -ManifestPath .\SQLPROD01-snapshot-manifest-20260901-101500.json -DeallocateVm -DetachPublicIp

    Deallocates the source VM, moves its NIC to a free parking address, detaches its public
    IP, and writes the handover record.

.EXAMPLE
    .\release-vm-network-address.ps1 -Rollback -HandoverPath .\SQLPROD01-ip-handover-20260901-101500.json

    Puts the original addresses back on the source NIC after an aborted cutover.

.NOTES
    Companion scripts: save-vm-snapshot-manifest.ps1, new-vm-from-snapshot-manifest.ps1,
    compare-vm-fidelity.ps1. See README.md for the full runbook.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High', DefaultParameterSetName = 'Manifest')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Manifest')]
    [ValidateNotNullOrEmpty()]
    [string]$ManifestPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrEmpty()]
    [string]$VmName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Explicit')]
    [ValidateNotNullOrEmpty()]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Rollback')]
    [switch]$Rollback,

    [string]$ParkingPrivateIpAddress,

    [switch]$DetachPublicIp,

    [switch]$DeallocateVm,

    [string]$HandoverPath,

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


function Get-SubnetObject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubnetId
    )

    # A subnet resource ID is .../virtualNetworks/<vnet>/subnets/<subnet>. There is no
    # Get-AzVirtualNetworkSubnetConfig by ID, so the parent VNet is fetched and the subnet
    # selected from it.
    if ($SubnetId -notmatch '(?i)^(?<vnetId>/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Network/virtualNetworks/[^/]+)/subnets/(?<subnet>[^/]+)$') {
        throw ("Cannot parse subnet resource ID '{0}'." -f $SubnetId)
    }

    $vnetId = $Matches['vnetId']
    $subnetName = $Matches['subnet']

    $vnet = Get-AzVirtualNetwork -Name (Get-ResourceNameFromResourceId -ResourceId $vnetId) -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $vnetId) -ErrorAction Stop
    $subnet = @($vnet.Subnets | Where-Object { $_.Name -eq $subnetName }) | Select-Object -First 1
    if (-not $subnet) {
        throw ("Subnet '{0}' was not found in virtual network '{1}'." -f $subnetName, $vnet.Name)
    }

    return [pscustomobject]@{
        VirtualNetwork = $vnet
        Subnet         = $subnet
    }
}

function Select-ParkingAddress {
    <#
    .SYNOPSIS
        Picks a free private address in the subnet to move the source NIC onto.

    .DESCRIPTION
        Uses Test-AzPrivateIPAddressAvailability, which returns both whether a given
        address is free and a list of available addresses in the subnet. The chosen address
        is reported before any change is made, so an operator can substitute their own with
        -ParkingPrivateIpAddress if the automatic choice conflicts with a reservation the
        service does not know about.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$VirtualNetwork,

        [Parameter(Mandatory = $true)]
        [string]$CurrentAddress,

        [string]$Requested
    )

    if ($Requested) {
        $check = Test-AzPrivateIPAddressAvailability -VirtualNetwork $VirtualNetwork -IPAddress $Requested -ErrorAction Stop
        if (-not $check.Available) {
            throw ("The requested parking address '{0}' is not available in virtual network '{1}'." -f $Requested, $VirtualNetwork.Name)
        }

        return $Requested
    }

    $probe = Test-AzPrivateIPAddressAvailability -VirtualNetwork $VirtualNetwork -IPAddress $CurrentAddress -ErrorAction Stop
    $available = ConvertTo-StringArray -InputObject $probe.AvailableIPAddresses
    $candidates = @($available | Where-Object { $_ -ne $CurrentAddress })
    if ($candidates.Count -eq 0) {
        throw ("No free private IP address could be found in virtual network '{0}' to park the source NIC on. Supply one with -ParkingPrivateIpAddress." -f $VirtualNetwork.Name)
    }

    # Guard against the array-of-array shape that a comma-wrapped return would produce.
    # Assigning that to a string property silently space-joins every candidate into one
    # garbage value, and the failure only shows up later at Set-AzNetworkInterface.
    if ($candidates[0] -isnot [string]) {
        throw 'Internal error: the parking address candidate list is not a flat list of strings.'
    }

    return $candidates[0]
}

function Get-PrimaryIpConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [object]$NetworkInterface
    )

    $ipConfiguration = @($NetworkInterface.IpConfigurations | Where-Object { $_.Primary }) | Select-Object -First 1
    if (-not $ipConfiguration) {
        $ipConfiguration = @($NetworkInterface.IpConfigurations) | Select-Object -First 1
    }

    if (-not $ipConfiguration) {
        throw ("Network interface '{0}' has no IP configuration." -f $NetworkInterface.Name)
    }

    return $ipConfiguration
}


$originalContext = $null

try {
    Write-Step 'Checking prerequisites'
    Assert-AzModule -Name @('Az.Accounts', 'Az.Compute', 'Az.Network')
    $originalContext = Save-AzContextState
    $null = Connect-AzIfNeeded

    # ---------------------------------------------------------------- Rollback path
    if ($Rollback) {
        if (-not $HandoverPath) {
            throw 'Rollback requires -HandoverPath pointing at the handover record written when the address was released.'
        }

        Write-Step 'Rolling back the address handover'
        $handover = Read-JsonFile -Path $HandoverPath
        $null = Set-AzSubscriptionContext -SubscriptionId $handover.SubscriptionId

        $nic = Get-AzNetworkInterface -ResourceId $handover.NetworkInterfaceId -ErrorAction Stop
        $ipConfiguration = Get-PrimaryIpConfiguration -NetworkInterface $nic

        Write-Detail ("NIC '{0}' currently holds {1}; restoring {2}." -f $nic.Name, $ipConfiguration.PrivateIpAddress, $handover.OriginalPrivateIpAddress)

        $availability = Test-AzPrivateIPAddressAvailability -VirtualNetwork (Get-SubnetObject -SubnetId $handover.SubnetId).VirtualNetwork -IPAddress $handover.OriginalPrivateIpAddress -ErrorAction Stop
        if (-not $availability.Available) {
            throw ("The original address {0} is currently in use - most likely by the replacement VM. Remove it there first, then rerun this rollback." -f $handover.OriginalPrivateIpAddress)
        }

        if ($PSCmdlet.ShouldProcess($nic.Name, ("Restore private IP {0}" -f $handover.OriginalPrivateIpAddress))) {
            $ipConfiguration.PrivateIpAddress = $handover.OriginalPrivateIpAddress
            $ipConfiguration.PrivateIpAllocationMethod = $handover.OriginalPrivateIpAllocationMethod

            if ($handover.PublicIpDetached -and $handover.OriginalPublicIpAddressId) {
                $publicIp = Get-AzPublicIpAddress -Name (Get-ResourceNameFromResourceId -ResourceId $handover.OriginalPublicIpAddressId) -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $handover.OriginalPublicIpAddressId) -ErrorAction Stop
                $ipConfiguration.PublicIpAddress = $publicIp
            }

            $null = Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop
            Write-Ok ("Restored {0} to NIC '{1}'." -f $handover.OriginalPrivateIpAddress, $nic.Name)
        }

        return [pscustomobject]@{
            Action                 = 'Rollback'
            NetworkInterfaceId     = $nic.Id
            RestoredPrivateIpAddress = $handover.OriginalPrivateIpAddress
        }
    }

    # ---------------------------------------------------------------- Release path
    $sourceVmName = $VmName
    $sourceResourceGroupName = $ResourceGroupName
    $sourceSubscriptionId = $SubscriptionId
    $manifest = $null

    if ($PSCmdlet.ParameterSetName -eq 'Manifest') {
        $manifest = Read-JsonFile -Path $ManifestPath
        $sourceVmName = $manifest.SourceVm.Name
        $sourceResourceGroupName = $manifest.SourceVm.ResourceGroupName
        $sourceSubscriptionId = $manifest.SourceVm.SubscriptionId
        Write-Detail ("Manifest: {0}" -f $ManifestPath)
    }

    $null = Set-AzSubscriptionContext -SubscriptionId $sourceSubscriptionId

    Write-Step ("Inspecting source VM '{0}'" -f $sourceVmName)
    $vm = Get-AzVM -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName -ErrorAction Stop
    $powerState = Get-VmPowerState -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName
    Write-Detail ("Power state: {0}" -f $powerState)

    if ($powerState -ne 'PowerState/deallocated') {
        if ($DeallocateVm) {
            if (-not $PSCmdlet.ShouldProcess($sourceVmName, 'Deallocate the source VM before releasing its address')) {
                # Falling through here would release the address of a VM that is still
                # running, which is the exact condition this script exists to prevent.
                throw 'Deallocation was declined, so the address was not released. Deallocate the source VM yourself and rerun.'
            }

            Write-Detail 'Deallocating the source VM.'
            $null = Stop-AzVM -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName -Force -ErrorAction Stop
            $powerState = Get-VmPowerState -ResourceGroupName $sourceResourceGroupName -Name $sourceVmName
            if ($powerState -ne 'PowerState/deallocated') {
                throw ("Stop-AzVM returned but the source VM reports '{0}' rather than deallocated. Not releasing its address." -f $powerState)
            }

            Write-Ok ("Source VM is now {0}." -f $powerState)
        }
        elseif (-not $Force) {
            throw ("The source VM reports '{0}'. Releasing its address while it is running would let the replacement VM come up with the same hostname, AD computer account and SQL instance while the original is still live. Deallocate it first, pass -DeallocateVm, or override with -Force if you are certain." -f $powerState)
        }
        else {
            Write-Warning ("Proceeding with -Force while the source VM reports '{0}'. Ensure the replacement VM is NOT started until this one is deallocated." -f $powerState)
        }
    }

    $nicReference = @($vm.NetworkProfile.NetworkInterfaces | Where-Object { $_.Primary }) | Select-Object -First 1
    if (-not $nicReference) {
        $nicReference = @($vm.NetworkProfile.NetworkInterfaces) | Select-Object -First 1
    }

    if (-not $nicReference) {
        throw ("VM '{0}' has no network interface." -f $sourceVmName)
    }

    $nic = Get-AzNetworkInterface -ResourceId $nicReference.Id -ErrorAction Stop
    $ipConfiguration = Get-PrimaryIpConfiguration -NetworkInterface $nic

    $originalPrivateIp = $ipConfiguration.PrivateIpAddress
    $originalAllocation = [string]$ipConfiguration.PrivateIpAllocationMethod
    $originalPublicIpId = $null
    if ($ipConfiguration.PublicIpAddress) {
        $originalPublicIpId = $ipConfiguration.PublicIpAddress.Id
    }

    $subnetId = $ipConfiguration.Subnet.Id
    $subnetInfo = Get-SubnetObject -SubnetId $subnetId

    Write-Detail ("NIC              : {0}" -f $nic.Name)
    Write-Detail ("IP configuration : {0}" -f $ipConfiguration.Name)
    Write-Detail ("Private IP       : {0} ({1})" -f $originalPrivateIp, $originalAllocation)
    Write-Detail ("Subnet           : {0}" -f (Get-ResourceNameFromResourceId -ResourceId $subnetId))
    if ($originalPublicIpId) {
        Write-Detail ("Public IP        : {0}" -f (Get-ResourceNameFromResourceId -ResourceId $originalPublicIpId))
    }

    if ($nic.IpConfigurations.Count -gt 1) {
        Write-Gap ("This NIC has {0} IP configurations. Only the primary one is moved; the others keep their addresses and stay on the source NIC." -f $nic.IpConfigurations.Count)
    }

    Write-Step 'Choosing a parking address'
    $parkingAddress = Select-ParkingAddress -VirtualNetwork $subnetInfo.VirtualNetwork -CurrentAddress $originalPrivateIp -Requested $ParkingPrivateIpAddress
    Write-Detail ("The source NIC will be moved to {0}, freeing {1} for the replacement VM." -f $parkingAddress, $originalPrivateIp)

    $handoverRecord = [pscustomobject]@{
        GeneratedAtUtc                   = (Get-Date).ToUniversalTime().ToString('o')
        SubscriptionId                   = $sourceSubscriptionId
        SourceVmName                     = $sourceVmName
        SourceResourceGroupName          = $sourceResourceGroupName
        SourceVmPowerState               = $powerState
        NetworkInterfaceId               = $nic.Id
        NetworkInterfaceName             = $nic.Name
        IpConfigurationName              = $ipConfiguration.Name
        SubnetId                         = $subnetId
        OriginalPrivateIpAddress         = $originalPrivateIp
        OriginalPrivateIpAllocationMethod = $originalAllocation
        ParkingPrivateIpAddress          = $parkingAddress
        OriginalPublicIpAddressId        = $originalPublicIpId
        PublicIpDetached                 = ($DetachPublicIp.IsPresent -and $null -ne $originalPublicIpId)
    }

    if (-not $HandoverPath) {
        $directory = (Get-Location).Path
        if ($ManifestPath) {
            $manifestDirectory = Split-Path -Path (Resolve-Path -LiteralPath $ManifestPath).Path -Parent
            if ($manifestDirectory) {
                $directory = $manifestDirectory
            }
        }

        $HandoverPath = Join-Path -Path $directory -ChildPath ("{0}-ip-handover-{1}.json" -f $sourceVmName, (New-BatchTimestamp))
    }

    Write-Step 'Releasing the address'
    $target = ("{0} ({1} -> {2})" -f $nic.Name, $originalPrivateIp, $parkingAddress)
    if (-not $PSCmdlet.ShouldProcess($target, 'Move the source NIC to a parking address, releasing the original')) {
        Write-Detail 'No change made.'
        return $handoverRecord
    }

    # Write the handover record BEFORE mutating the NIC. If the update then fails halfway,
    # the record still describes what the original state was.
    $null = Write-JsonFile -InputObject $handoverRecord -Path $HandoverPath -Depth 8
    Write-Detail ("Handover record: {0}" -f $HandoverPath)

    $ipConfiguration.PrivateIpAddress = $parkingAddress
    $ipConfiguration.PrivateIpAllocationMethod = 'Static'

    if ($DetachPublicIp -and $originalPublicIpId) {
        $ipConfiguration.PublicIpAddress = $null
        Write-Detail 'Detaching the public IP from the source NIC.'
    }

    $null = Set-AzNetworkInterface -NetworkInterface $nic -ErrorAction Stop

    Write-Step 'Verifying'
    $availability = Test-AzPrivateIPAddressAvailability -VirtualNetwork $subnetInfo.VirtualNetwork -IPAddress $originalPrivateIp -ErrorAction Stop
    if ($availability.Available) {
        Write-Ok ("{0} is now free and can be claimed by the replacement VM." -f $originalPrivateIp)
    }
    else {
        throw ("The NIC was updated but {0} is still reported as in use. Check for another NIC or a reservation holding it before creating the replacement VM." -f $originalPrivateIp)
    }

    if ($DetachPublicIp -and $originalPublicIpId) {
        $publicIp = Get-AzPublicIpAddress -Name (Get-ResourceNameFromResourceId -ResourceId $originalPublicIpId) -ResourceGroupName (Get-ResourceGroupNameFromResourceId -ResourceId $originalPublicIpId) -ErrorAction Stop
        if ($publicIp.IpConfiguration) {
            Write-Warning 'The public IP still reports an IP configuration association. Verify it before attaching it to the replacement VM.'
        }
        else {
            Write-Ok ("Public IP '{0}' is detached and available." -f $publicIp.Name)
        }
    }

    Write-Host ''
    Write-Host ("Next: new-vm-from-snapshot-manifest.ps1 -UseSourcePrivateIp, which will claim {0}." -f $originalPrivateIp) -ForegroundColor Cyan
    Write-Host ("To undo: .\release-vm-network-address.ps1 -Rollback -HandoverPath '{0}'" -f $HandoverPath) -ForegroundColor Cyan

    $handoverRecord | Add-Member -NotePropertyName 'HandoverPath' -NotePropertyValue $HandoverPath -Force
    $handoverRecord
}
finally {
    Restore-AzContextState -Context $originalContext
}
