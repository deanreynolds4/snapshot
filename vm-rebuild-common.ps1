<#
.SYNOPSIS
    Shared helpers for the Azure VM snapshot-and-rebuild toolkit.

.DESCRIPTION
    Dot-source this file from the capture, release, restore and compare scripts:

        . (Join-Path $PSScriptRoot 'vm-rebuild-common.ps1')

    Everything here is written for Windows PowerShell 5.1 as well as PowerShell 7,
    because the target host for this toolkit only has 5.1. That rules out the
    ternary operator, the null-coalescing operators, the '&&' and '||' pipeline
    chain operators, 'ConvertFrom-Json -Depth' and 'ConvertFrom-Json -AsHashtable'.

.NOTES
    Part of the Azure VM snapshot-and-rebuild toolkit. See README.md.
#>

# Deliberately no Set-StrictMode here. This file is dot-sourced, so anything it sets
# lands in the CALLER's scope - and dot-sourcing it from an interactive prompt would then
# leave that session strict, where reading an unset automatic variable such as
# $LASTEXITCODE starts throwing. Each entry-point script sets its own strict mode instead.

# Manifest schema version written by the capture script and required by the restore
# script. Bump the major number whenever a change would make an older manifest
# restore incorrectly rather than merely incompletely.
$script:VmRebuildManifestSchemaVersion = 2

# Azure resource name limits that this toolkit has to respect.
$script:AzureSnapshotNameMaxLength = 80
$script:AzureDiskNameMaxLength     = 80


#region Console output

function Write-Step {
    <#
    .SYNOPSIS
        Writes a numbered progress heading.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ''
    Write-Host ("==> {0}" -f $Message) -ForegroundColor Cyan
}

function Write-Detail {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("    {0}" -f $Message)
}

function Write-Ok {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("    [ ok ] {0}" -f $Message) -ForegroundColor Green
}

function Write-Gap {
    <#
    .SYNOPSIS
        Reports a fidelity gap: something that could not be captured or replayed.

    .DESCRIPTION
        Deliberately distinct from Write-Warning. A gap is an expected, documented
        limitation that belongs on the operator's manual checklist, not a fault.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host ("    [gap ] {0}" -f $Message) -ForegroundColor Yellow
}

#endregion


#region Resource ID parsing

function Get-SubscriptionIdFromResourceId {
    param(
        [AllowNull()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    if ($ResourceId -match '(?i)/subscriptions/([^/]+)') {
        return $Matches[1]
    }

    return $null
}

function Get-ResourceGroupNameFromResourceId {
    param(
        [AllowNull()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') {
        return $Matches[1]
    }

    return $null
}

function Get-ResourceNameFromResourceId {
    param(
        [AllowNull()]
        [string]$ResourceId
    )

    if ([string]::IsNullOrWhiteSpace($ResourceId)) {
        return $null
    }

    $trimmed = $ResourceId.TrimEnd('/')
    $lastSlash = $trimmed.LastIndexOf('/')
    if ($lastSlash -lt 0) {
        return $trimmed
    }

    return $trimmed.Substring($lastSlash + 1)
}

#endregion


#region Property access

function Get-ObjectPropertyValue {
    <#
    .SYNOPSIS
        Reads the first present, meaningful value from a list of candidate property names.

    .DESCRIPTION
        Azure SDK model types and JSON-deserialised PSCustomObjects frequently expose the
        same logical value under different names (for example SqlServerLicenseType on the
        Az.SqlVirtualMachine model versus LicenseType on older builds). This helper probes
        each candidate name in order.

        A property is skipped when it is absent or $null, and - for strings only - when it
        is empty or whitespace. Boolean $false and numeric 0 are returned as-is, because
        they are meaningful values rather than absences.

    .PARAMETER Default
        Returned when no candidate property yields a value.
    #>
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames,

        [AllowNull()]
        [object]$Default = $null
    )

    if ($null -eq $InputObject) {
        return $Default
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

    return $Default
}

function Test-ObjectHasProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $InputObject) {
        return $false
    }

    return [bool]$InputObject.PSObject.Properties[$PropertyName]
}

function Get-BooleanPropertyValue {
    <#
    .SYNOPSIS
        Reads a candidate property as a strict boolean, returning $false when absent.
    #>
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string[]]$PropertyNames
    )

    $value = Get-ObjectPropertyValue -InputObject $InputObject -PropertyNames $PropertyNames
    if ($null -eq $value) {
        return $false
    }

    return [bool]$value
}

#endregion


#region Type conversion

function ConvertTo-StringDictionary {
    <#
    .SYNOPSIS
        Builds a Dictionary[string,string] from a hashtable, a dictionary, or a
        JSON-deserialised PSCustomObject.

    .DESCRIPTION
        PSVirtualMachine.Tags is typed IDictionary[string,string]. Assigning either a
        PSCustomObject (what ConvertFrom-Json produces) or a plain Hashtable to it throws
        a conversion error on Windows PowerShell 5.1, so tags read back out of a manifest
        must be rebuilt into a genuine generic dictionary before they can be applied.

        Returns $null when there is nothing to convert, so callers can skip the
        assignment entirely rather than stamping an empty tag set onto a resource.
    #>
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $dictionary = New-Object 'System.Collections.Generic.Dictionary[string,string]'

    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($key in $InputObject.Keys) {
            $dictionary[[string]$key] = [string]$InputObject[$key]
        }
    }
    else {
        foreach ($property in $InputObject.PSObject.Properties) {
            if ($property.MemberType -ne 'NoteProperty' -and $property.MemberType -ne 'Property') {
                continue
            }

            $dictionary[[string]$property.Name] = [string]$property.Value
        }
    }

    if ($dictionary.Count -eq 0) {
        return $null
    }

    return $dictionary
}

function ConvertTo-PlainHashtable {
    <#
    .SYNOPSIS
        Recursively converts a JSON-deserialised PSCustomObject graph into nested
        hashtables and arrays.

    .DESCRIPTION
        Windows PowerShell 5.1 has no 'ConvertFrom-Json -AsHashtable', and several Az
        cmdlets that accept settings objects will not bind a PSCustomObject. This provides
        the missing conversion.
    #>
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string] -or $InputObject.GetType().IsPrimitive -or $InputObject -is [datetime]) {
        return $InputObject
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-PlainHashtable -InputObject $InputObject[$key]
        }

        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += , (ConvertTo-PlainHashtable -InputObject $item)
        }

        # The comma IS correct here, unlike in ConvertTo-StringArray. This function recurses
        # and its result is only ever bare-assigned ($result[$key] = ConvertTo-PlainHashtable
        # ...), never piped or wrapped in @(). Without the comma a nested array would be
        # flattened into the parent's output and the structure would be lost. Do not "fix"
        # this to match ConvertTo-StringArray - the two have opposite requirements.
        return , $items
    }

    if ($InputObject -is [psobject] -and $InputObject.PSObject.Properties.Count -gt 0) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[[string]$property.Name] = ConvertTo-PlainHashtable -InputObject $property.Value
        }

        return $result
    }

    return $InputObject
}

function Get-SafeArray {
    <#
    .SYNOPSIS
        Normalises a possibly-null value into an array, treating $null as EMPTY.

    .DESCRIPTION
        "@($null).Count" is 1 in PowerShell, not 0, so the common idiom "@($section.Data).Count"
        reports one item for a section that holds nothing. That turns "no extensions were
        captured" into "1 extension" in every count and summary that uses it.
    #>
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $list = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $InputObject) {
        foreach ($item in @($InputObject)) {
            if ($null -ne $item) {
                $list.Add($item)
            }
        }
    }

    return $list.ToArray()
}

function ConvertTo-StringArray {
    <#
    .SYNOPSIS
        Normalises a possibly-null, possibly-scalar value into a string array with no
        null or empty entries.

    .DESCRIPTION
        Regional (non-zonal) VMs serialise Zones as an array containing a single null,
        which naive '@($manifest.SourceVm.Zones).Count -gt 0' checks read as "this VM is
        zonal". Filtering the nulls out here removes that whole class of bug.
    #>
    param(
        [AllowNull()]
        [object]$InputObject
    )

    $values = New-Object 'System.Collections.Generic.List[string]'

    if ($null -ne $InputObject) {
        foreach ($item in @($InputObject)) {
            if ($null -eq $item) {
                continue
            }

            $text = [string]$item
            if ([string]::IsNullOrWhiteSpace($text)) {
                continue
            }

            $values.Add($text)
        }
    }

    # Returns a typed string[], NOT the ", $array" comma-wrap idiom. That idiom protects a
    # single-element array from unrolling on return, but it does so by emitting the array as
    # one pipeline object - so "@(ConvertTo-StringArray ...)" yields a one-element array
    # holding an array, and "ConvertTo-StringArray ... | Where-Object" hands the filter the
    # whole array as a single item and silently filters nothing. Verified on 5.1. A typed
    # string[] behaves correctly under bare assignment, @() and piping alike.
    return $values.ToArray()
}

#endregion


#region JSON file IO

function Write-JsonFile {
    <#
    .SYNOPSIS
        Serialises an object to UTF-8 JSON without a byte order mark.

    .DESCRIPTION
        'Set-Content -Encoding utf8' emits a BOM on Windows PowerShell 5.1, which trips up
        other tooling that reads the manifest. This writes clean UTF-8 and then reads the
        file straight back and re-parses it, so a manifest is never reported as written
        unless it is genuinely parseable.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$Depth = 32
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        $null = New-Item -Path $directory -ItemType Directory -Force
    }

    # [System.IO.File] resolves a relative path against the .NET process working directory,
    # which is NOT PowerShell's current location and is usually wherever the host started.
    # Anchor the path to PowerShell's location so a relative -Path lands where the operator
    # expects rather than somewhere they will never find it.
    $fullPath = $Path
    if (-not [System.IO.Path]::IsPathRooted($fullPath)) {
        $fullPath = Join-Path -Path (Get-Location).ProviderPath -ChildPath $Path
    }

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($fullPath, $json, $encoding)

    # Round-trip validation: prove the file we just wrote can be read back.
    try {
        $null = Read-JsonFile -Path $fullPath
    }
    catch {
        throw ("Wrote '{0}' but it could not be parsed back: {1}" -f $fullPath, $_.Exception.Message)
    }

    return $fullPath
}

function Read-JsonFile {
    <#
    .SYNOPSIS
        Reads and parses a JSON file on any supported PowerShell version.

    .DESCRIPTION
        Deliberately does not pass -Depth to ConvertFrom-Json: that parameter does not
        exist on Windows PowerShell 5.1 and using it makes the script fail at parameter
        binding before it does anything at all.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("File '{0}' does not exist." -f $Path)
    }

    # Read as UTF-8 explicitly. Write-JsonFile writes UTF-8 with no BOM, and on Windows
    # PowerShell 5.1 "Get-Content -Raw" with no -Encoding decodes a BOM-less file using the
    # system ANSI codepage - which silently mojibakes any non-ASCII tag value, resource name
    # or note, with no error at all. ConvertFrom-Json parses the corrupted text happily.
    $raw = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).ProviderPath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw ("File '{0}' is empty." -f $Path)
    }

    return $raw | ConvertFrom-Json
}

#endregion


#region Naming

function New-AzureResourceName {
    <#
    .SYNOPSIS
        Builds a safe, collision-resistant Azure resource name from parts.

    .DESCRIPTION
        Snapshot and disk names are limited to 80 characters and to letters, digits,
        underscores, periods and hyphens. Rather than truncating the source disk name -
        which is how sibling data disks end up sharing one snapshot name and silently
        overwriting each other - this keeps the caller-supplied discriminator (LUN, or
        'os') and the timestamp intact, and trims only the descriptive middle.

    .PARAMETER Prefix
        Leading component, normally the VM name.

    .PARAMETER Discriminator
        The component that guarantees uniqueness within the batch, such as 'os' or
        'lun3'. Never trimmed.

    .PARAMETER Suffix
        Trailing component, normally the batch timestamp. Never trimmed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$Discriminator,

        [Parameter(Mandatory = $true)]
        [string]$Suffix,

        [int]$MaxLength = 80
    )

    $clean = {
        param($text)
        $sanitised = [regex]::Replace([string]$text, '[^A-Za-z0-9_.-]', '-')
        return $sanitised.Trim('-')
    }

    $cleanPrefix = & $clean $Prefix
    $cleanDiscriminator = & $clean $Discriminator
    $cleanSuffix = & $clean $Suffix

    # Reserve room for the fixed parts and the two joining hyphens.
    $reserved = $cleanDiscriminator.Length + $cleanSuffix.Length + 2
    $available = $MaxLength - $reserved
    if ($available -lt 1) {
        throw ("Cannot build a resource name within {0} characters from discriminator '{1}' and suffix '{2}'." -f $MaxLength, $cleanDiscriminator, $cleanSuffix)
    }

    if ($cleanPrefix.Length -gt $available) {
        $cleanPrefix = $cleanPrefix.Substring(0, $available).TrimEnd('-')
    }

    return ('{0}-{1}-{2}' -f $cleanPrefix, $cleanDiscriminator, $cleanSuffix)
}

function New-BatchTimestamp {
    <#
    .SYNOPSIS
        Returns a sortable, culture-invariant, second-precision batch stamp.

    .DESCRIPTION
        The original 'dd-MM-yyyy_HH_mm' format sorts wrongly, changes meaning between
        locales, and repeats within the same minute, so a rerun inside 60 seconds
        produces names that collide with the previous batch.
    #>
    return (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Assert-UniqueName {
    <#
    .SYNOPSIS
        Throws if the supplied names are not all distinct.

    .DESCRIPTION
        Used to prove, before any billable resource is created, that a planned batch of
        snapshot or disk names contains no duplicates. A duplicate would otherwise cause
        one resource to silently replace another.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Name,

        [Parameter(Mandatory = $true)]
        [string]$What
    )

    $duplicates = @($Name | Group-Object | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) {
        $list = ($duplicates | ForEach-Object { "'$($_.Name)' x$($_.Count)" }) -join ', '
        throw ("Planned {0} names are not unique: {1}. Refusing to continue, because the duplicate would overwrite the first resource." -f $What, $list)
    }
}

#endregion


#region Cmdlet capability probing

function Test-CmdletSupportsParameter {
    <#
    .SYNOPSIS
        Reports whether the installed build of a cmdlet has a given parameter.

    .DESCRIPTION
        The Az modules add parameters over time - WriteAccelerator, DeleteOption,
        DiskControllerType and so on all arrived in different releases. Splatting a
        parameter that the installed build does not have fails at parameter binding and
        aborts the migration part-way through. Probing first lets the toolkit apply what it
        can on an older module and report precisely what it had to skip, instead of either
        crashing or silently pretending the setting was applied.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$CmdletName,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    $command = Get-Command -Name $CmdletName -ErrorAction SilentlyContinue
    if (-not $command) {
        return $false
    }

    return $command.Parameters.ContainsKey($ParameterName)
}

function Add-SupportedParameter {
    <#
    .SYNOPSIS
        Adds a value to a splat hashtable only if the target cmdlet supports the parameter
        and the value is meaningful.

    .OUTPUTS
        $true if the parameter was added, $false if it was skipped.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Splat,

        [Parameter(Mandatory = $true)]
        [string]$CmdletName,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName,

        [AllowNull()]
        [object]$Value,

        [switch]$AllowFalse
    )

    if ($null -eq $Value) {
        return $false
    }

    if (($Value -is [string]) -and [string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    if (($Value -is [bool]) -and (-not $Value) -and (-not $AllowFalse)) {
        return $false
    }

    if (-not (Test-CmdletSupportsParameter -CmdletName $CmdletName -ParameterName $ParameterName)) {
        Write-Warning ("{0} does not support -{1} in the installed Az module version; that setting will not be applied." -f $CmdletName, $ParameterName)
        return $false
    }

    $Splat[$ParameterName] = $Value
    return $true
}

#endregion


#region Azure context

function Assert-AzModule {
    <#
    .SYNOPSIS
        Verifies the required Az modules are installed and importable.

    .DESCRIPTION
        Reports every missing module at once with the exact install command, rather than
        failing on the first missing cmdlet part-way through a migration.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Name
    )

    $missing = @()
    foreach ($moduleName in $Name) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            $missing += $moduleName
        }
    }

    if ($missing.Count -gt 0) {
        $installList = ($missing | ForEach-Object { $_ }) -join ','
        throw ("Required Az module(s) not installed: {0}. Install with: Install-Module -Name {1} -Scope CurrentUser -Repository PSGallery -Force" -f ($missing -join ', '), $installList)
    }

    foreach ($moduleName in $Name) {
        if (-not (Get-Module -Name $moduleName)) {
            Import-Module -Name $moduleName -ErrorAction Stop
        }
    }
}

function Connect-AzIfNeeded {
    <#
    .SYNOPSIS
        Signs in only when there is no usable context already.

    .DESCRIPTION
        Calling Connect-AzAccount unconditionally forces an interactive browser prompt on
        every run, which breaks unattended execution and is needless when a valid context
        exists. Returns the context in use.
    #>
    param(
        [string]$TenantId,
        [string]$SubscriptionId
    )

    $context = $null
    try {
        $context = Get-AzContext -ErrorAction Stop
    }
    catch {
        $context = $null
    }

    if ($context -and $context.Account) {
        Write-Detail ("Using existing Azure context: {0} / {1}" -f $context.Account.Id, $context.Subscription.Name)
        return $context
    }

    $connectParameters = @{ ErrorAction = 'Stop' }
    if ($TenantId) {
        $connectParameters.Tenant = $TenantId
    }

    if ($SubscriptionId) {
        $connectParameters.Subscription = $SubscriptionId
    }

    Write-Detail 'No Azure context found; signing in.'
    $null = Connect-AzAccount @connectParameters

    return Get-AzContext
}

function Save-AzContextState {
    <#
    .SYNOPSIS
        Captures the caller's current Azure context so it can be restored later.
    #>
    try {
        return Get-AzContext -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Restore-AzContextState {
    <#
    .SYNOPSIS
        Puts the caller's Azure subscription context back.

    .DESCRIPTION
        Scripts that iterate subscriptions with Set-AzContext otherwise leave the operator
        pointed at whichever subscription happened to be last in the list, which persists
        into their next command.
    #>
    param(
        [AllowNull()]
        [object]$Context
    )

    if ($null -eq $Context -or $null -eq $Context.Subscription) {
        return
    }

    try {
        $null = Set-AzContext -SubscriptionId $Context.Subscription.Id -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to restore the original Azure context to subscription '{0}'. {1}" -f $Context.Subscription.Id, $_.Exception.Message)
    }
}

function Set-AzSubscriptionContext {
    <#
    .SYNOPSIS
        Switches to a subscription and confirms the switch actually took effect.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
    $context = Get-AzContext
    if ($context.Subscription.Id -ne $SubscriptionId) {
        throw ("Failed to switch to subscription '{0}'; the active context is '{1}'." -f $SubscriptionId, $context.Subscription.Id)
    }

    return $context
}

#endregion


#region VM helpers

function Get-VmPowerState {
    <#
    .SYNOPSIS
        Returns the VM power state code, such as 'PowerState/deallocated'.

    .DESCRIPTION
        Get-AzVM only populates instance-view statuses when -Status is supplied, so the
        power state has to be fetched deliberately. Returns 'PowerState/unknown' when the
        instance view cannot be read.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name -Status -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to read the power state of VM '{0}'. {1}" -f $Name, $_.Exception.Message)
        return 'PowerState/unknown'
    }

    $powerStatus = @($status.Statuses | Where-Object { $_.Code -like 'PowerState/*' }) | Select-Object -First 1
    if (-not $powerStatus) {
        return 'PowerState/unknown'
    }

    return $powerStatus.Code
}

function Test-VmDeallocated {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ((Get-VmPowerState -ResourceGroupName $ResourceGroupName -Name $Name) -eq 'PowerState/deallocated')
}

function Find-AzVmAcrossSubscriptions {
    <#
    .SYNOPSIS
        Locates a VM by name across accessible subscriptions.

    .DESCRIPTION
        Uses Azure Resource Graph when Az.ResourceGraph is available, which is a single
        indexed query rather than one Get-AzVM listing per subscription. Falls back to
        iterating subscriptions, but - unlike a naive loop - surfaces subscriptions that
        could not be queried, because a swallowed error there turns a genuine duplicate
        VM name into a false "unique match".

    .PARAMETER SubscriptionId
        Restricts the search to one subscription, skipping discovery entirely.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$SubscriptionId,

        [string]$ResourceGroupName
    )

    $vmMatches = @()
    $unreadable = @()

    if (-not $SubscriptionId -and (Get-Module -ListAvailable -Name Az.ResourceGraph)) {
        Import-Module Az.ResourceGraph -ErrorAction SilentlyContinue
        try {
            $query = "Resources | where type =~ 'microsoft.compute/virtualmachines' and name =~ '$Name' | project id, name, resourceGroup, subscriptionId, location"
            $graphResults = Search-AzGraph -Query $query -First 100 -ErrorAction Stop
            foreach ($row in @($graphResults)) {
                if ($ResourceGroupName -and $row.resourceGroup -ne $ResourceGroupName) {
                    continue
                }

                $vmMatches += [pscustomobject]@{
                    SubscriptionId    = $row.subscriptionId
                    ResourceGroupName = $row.resourceGroup
                    Name              = $row.name
                    Id                = $row.id
                    Location          = $row.location
                }
            }

            return [pscustomobject]@{
                Matches                 = @($vmMatches)
                UnreadableSubscriptions = @()
                Method                  = 'ResourceGraph'
            }
        }
        catch {
            Write-Warning ("Resource Graph query failed, falling back to a per-subscription search. {0}" -f $_.Exception.Message)
        }
    }

    $subscriptionsToSearch = @()
    if ($SubscriptionId) {
        $subscriptionsToSearch = @([pscustomobject]@{ Id = $SubscriptionId; Name = $SubscriptionId })
    }
    else {
        $subscriptionsToSearch = @(Get-AzSubscription -ErrorAction Stop | Where-Object { $_.State -eq 'Enabled' })
    }

    foreach ($subscription in $subscriptionsToSearch) {
        try {
            $null = Set-AzContext -SubscriptionId $subscription.Id -ErrorAction Stop
            $found = @(Get-AzVM -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
        }
        catch {
            $unreadable += ("{0} ({1}): {2}" -f $subscription.Name, $subscription.Id, $_.Exception.Message)
            continue
        }

        foreach ($vm in $found) {
            if ($ResourceGroupName -and $vm.ResourceGroupName -ne $ResourceGroupName) {
                continue
            }

            $vmMatches += [pscustomobject]@{
                SubscriptionId    = $subscription.Id
                ResourceGroupName = $vm.ResourceGroupName
                Name              = $vm.Name
                Id                = $vm.Id
                Location          = $vm.Location
            }
        }
    }

    return [pscustomobject]@{
        Matches                 = @($vmMatches)
        UnreadableSubscriptions = @($unreadable)
        Method                  = 'SubscriptionScan'
    }
}

#endregion


#region Transcript

function Start-RunTranscript {
    <#
    .SYNOPSIS
        Begins a transcript alongside the output artefacts, if possible.

    .DESCRIPTION
        A production migration needs an auditable record of what was run. Transcript
        failures are non-fatal: losing the log is not a reason to abandon the migration.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $directory = Split-Path -Path $Path -Parent
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            $null = New-Item -Path $directory -ItemType Directory -Force
        }

        $null = Start-Transcript -LiteralPath $Path -Force -ErrorAction Stop
        return $Path
    }
    catch {
        Write-Warning ("Could not start a transcript at '{0}'. {1}" -f $Path, $_.Exception.Message)
        return $null
    }
}

function Stop-RunTranscript {
    try {
        $null = Stop-Transcript -ErrorAction SilentlyContinue
    }
    catch {
        # A transcript that was never started is not an error worth reporting.
    }
}

#endregion
