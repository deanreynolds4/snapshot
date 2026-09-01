[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Subscription,

    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$VmName,

    [Parameter(Mandatory)]
    [datetime]$StartTimeUtc,

    [Parameter(Mandatory)]
    [datetime]$EndTimeUtc,

    [ValidateRange(0, 63)]
    [int]$PrimaryDataLun = 0,

    [ValidateRange(0, 63)]
    [int]$TempDbLun = 3,

    [string]$PrimaryDataVolume = 'D:',

    [string]$TempDbVolume = 'T:',

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path -Path (Get-Location) -ChildPath ("azure-vm-disk-metrics-{0}.json" -f $timestamp)
}

if ($EndTimeUtc -le $StartTimeUtc) {
    throw 'EndTimeUtc must be later than StartTimeUtc.'
}

function Invoke-AzCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw ('Azure CLI command failed: az {0}' -f ($Arguments -join ' '))
    }

    return $output
}

function Invoke-AzCliJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $jsonText = Invoke-AzCli -Arguments ($Arguments + @('-o', 'json'))
    if (-not $jsonText) {
        return $null
    }

    return $jsonText | ConvertFrom-Json
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$PropertyName
    )

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-MetricSeriesSummary {
    param(
        [Parameter(Mandatory)]
        [object]$MetricPayload
    )

    $metricRows = foreach ($metric in @($MetricPayload.value)) {
        $averageValues = [System.Collections.Generic.List[double]]::new()
        $maximumValues = [System.Collections.Generic.List[double]]::new()
        $seriesCount = 0

        foreach ($series in @($metric.timeseries)) {
            $seriesCount++
            foreach ($point in @($series.data)) {
                $averageValue = Get-OptionalPropertyValue -InputObject $point -PropertyName 'average'
                if ($null -ne $averageValue) {
                    $averageValues.Add([double]$averageValue)
                }

                $maximumValue = Get-OptionalPropertyValue -InputObject $point -PropertyName 'maximum'
                if ($null -ne $maximumValue) {
                    $maximumValues.Add([double]$maximumValue)
                }
            }
        }

        $averageOfAverage = $null
        $peakAverage = $null
        $peakMaximum = $null

        if ($averageValues.Count -gt 0) {
            $averageOfAverage = [math]::Round((($averageValues | Measure-Object -Average).Average), 2)
            $peakAverage = [math]::Round((($averageValues | Measure-Object -Maximum).Maximum), 2)
        }

        if ($maximumValues.Count -gt 0) {
            $peakMaximum = [math]::Round((($maximumValues | Measure-Object -Maximum).Maximum), 2)
        }

        [pscustomobject]@{
            MetricName       = $metric.name.localizedValue
            MetricKey        = $metric.name.value
            TimeSeriesCount  = $seriesCount
            AverageOfAverage = $averageOfAverage
            PeakAverage      = $peakAverage
            PeakMaximum      = $peakMaximum
            Unit             = $metric.unit
        }
    }

    return @($metricRows)
}

$startIso = $StartTimeUtc.ToUniversalTime().ToString('o')
$endIso = $EndTimeUtc.ToUniversalTime().ToString('o')

Invoke-AzCli -Arguments @('account', 'set', '--subscription', $Subscription) | Out-Null

$subscriptionInfo = Invoke-AzCliJson -Arguments @(
    'account', 'show',
    '--query', '{name:name,id:id,tenantId:tenantId}'
)

$vmInfo = Invoke-AzCliJson -Arguments @(
    'vm', 'show',
    '-g', $ResourceGroup,
    '-n', $VmName
)

$vmId = $vmInfo.id

$diskMetrics = @(
    'Data Disk IOPS Consumed Percentage',
    'Data Disk Bandwidth Consumed Percentage',
    'Data Disk Queue Depth',
    'Data Disk Latency',
    'Data Disk Read Operations/Sec',
    'Data Disk Write Operations/Sec',
    'Data Disk Read Bytes/sec',
    'Data Disk Write Bytes/sec'
)

$vmMetrics = @(
    'VM Uncached IOPS Consumed Percentage',
    'VM Uncached Bandwidth Consumed Percentage'
)

$tempDbMetricArguments = @(
    'monitor', 'metrics', 'list',
    '--resource', $vmId,
    '--start-time', $startIso,
    '--end-time', $endIso,
    '--interval', 'PT1M',
    '--aggregation', 'Average', 'Maximum',
    '--metrics'
) + $diskMetrics + @(
    '--filter', ("LUN eq '{0}'" -f $TempDbLun)
)

$tempDbMetricPayload = Invoke-AzCliJson -Arguments $tempDbMetricArguments

$primaryDataMetricArguments = @(
    'monitor', 'metrics', 'list',
    '--resource', $vmId,
    '--start-time', $startIso,
    '--end-time', $endIso,
    '--interval', 'PT1M',
    '--aggregation', 'Average', 'Maximum',
    '--metrics'
) + $diskMetrics + @(
    '--filter', ("LUN eq '{0}'" -f $PrimaryDataLun)
)

$primaryDataMetricPayload = Invoke-AzCliJson -Arguments $primaryDataMetricArguments

$vmUncachedMetricArguments = @(
    'monitor', 'metrics', 'list',
    '--resource', $vmId,
    '--start-time', $startIso,
    '--end-time', $endIso,
    '--interval', 'PT1M',
    '--aggregation', 'Average', 'Maximum',
    '--metrics'
) + $vmMetrics

$vmUncachedMetricPayload = Invoke-AzCliJson -Arguments $vmUncachedMetricArguments

$result = [pscustomobject]@{
    GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    Subscription   = $subscriptionInfo
    VmSummary      = [pscustomobject]@{
        Name          = $vmInfo.name
        ResourceGroup = $vmInfo.resourceGroup
        Location      = $vmInfo.location
        VmSize        = $vmInfo.hardwareProfile.vmSize
        VmId          = $vmId
    }
    TimeRangeUtc   = [pscustomobject]@{
        Start = $startIso
        End   = $endIso
    }
    DiskTargets    = [pscustomobject]@{
        PrimaryData = [pscustomobject]@{
            Lun    = $PrimaryDataLun
            Volume = $PrimaryDataVolume
        }
        TempDb = [pscustomobject]@{
            Lun    = $TempDbLun
            Volume = $TempDbVolume
        }
    }
    Summaries      = [pscustomobject]@{
        TempDbDisk      = @(Get-MetricSeriesSummary -MetricPayload $tempDbMetricPayload)
        PrimaryDataDisk = @(Get-MetricSeriesSummary -MetricPayload $primaryDataMetricPayload)
        VmUncached      = @(Get-MetricSeriesSummary -MetricPayload $vmUncachedMetricPayload)
    }
    RawMetrics     = [pscustomobject]@{
        TempDbDisk      = $tempDbMetricPayload
        PrimaryDataDisk = $primaryDataMetricPayload
        VmUncached      = $vmUncachedMetricPayload
    }
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory) {
    $null = New-Item -Path $outputDirectory -ItemType Directory -Force
}

$result | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8

Write-Host ("Saved Azure VM disk metrics to {0}" -f $OutputPath) -ForegroundColor Green
[pscustomobject]@{
    OutputPath = $OutputPath
    TimeRange  = $result.TimeRangeUtc
    Summary    = $result.Summaries
}
