#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Local network monitor for Hyper-V Live Migration tests.

.DESCRIPTION
Runs locally on a Hyper-V cluster node during a Live Migration test. The script captures ICMP reachability,
Windows Network Interface performance counters, host network inventory, Live Migration host settings,
and optional pktmon NIC counters. It does not use PowerShell remoting and is intended for hardened
environments where Remote Credential Guard, Kerberos-only operation, WinRM hardening, or restrictive
security baselines prevent remote collection.

Run this script locally on both the source and target Hyper-V hosts before starting the Live Migration.
Use PeerTarget for the other host's Live Migration IP/FQDN and optionally VmTarget for the migrated VM.

.NOTES
File Name     : 07-LiveMigration-NetworkMonitor-Local.ps1
Version       : v0.1.0
Created       : 2026-06-26
Last Modified : 2026-06-26
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

[CmdletBinding()]
param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025\LiveMigrationNetworkTests",

    [string]$RunName = "LiveMigration-NetworkMonitor",

    [int]$DurationSeconds = 300,

    [int]$SampleIntervalSeconds = 1,

    [int]$PingTimeoutMs = 1000,

    [string]$PeerTarget = "",

    [string]$VmTarget = "",

    [string]$CounterInstanceFilterRegex = "",

    [switch]$SkipPktmon,

    [switch]$SkipPerformanceCounters,

    [switch]$SkipPing,

    [switch]$OpenResultFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-SafeFileName {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return ($Value -replace '[\\/:*?"<>| ]', '_')
}

function Get-ObjectPropertyValueSafe {
    param(
        [object]$InputObject,
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]

    if ($null -eq $property) {
        return $DefaultValue
    }

    return $property.Value
}

function Write-LogMessage {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("Info", "Warning", "Error", "Success")]
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$timestamp][$Level] $Message"

    $color = switch ($Level) {
        "Info"    { "Cyan" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        "Success" { "Green" }
    }

    Write-Host $line -ForegroundColor $color
}

function Invoke-IcmpProbe {
    param(
        [Parameter(Mandatory)]
        [string]$Target,

        [int]$TimeoutMs = 1000
    )

    $timestamp = Get-Date

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return [pscustomobject]@{
            Timestamp    = $timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
            ComputerName = $env:COMPUTERNAME
            Target       = $Target
            Success      = $false
            Status       = "Skipped"
            LatencyMs    = $null
            Error        = "Target is empty."
        }
    }

    try {
        $ping = [System.Net.NetworkInformation.Ping]::new()
        $reply = $ping.Send($Target, $TimeoutMs)

        return [pscustomobject]@{
            Timestamp    = $timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
            ComputerName = $env:COMPUTERNAME
            Target       = $Target
            Success      = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
            Status       = $reply.Status.ToString()
            LatencyMs    = if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) { $reply.RoundtripTime } else { $null }
            Error        = ""
        }
    }
    catch {
        return [pscustomobject]@{
            Timestamp    = $timestamp.ToString("yyyy-MM-dd HH:mm:ss.fff")
            ComputerName = $env:COMPUTERNAME
            Target       = $Target
            Success      = $false
            Status       = "Error"
            LatencyMs    = $null
            Error        = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $ping) {
            $ping.Dispose()
        }
    }
}

function Get-PingSummary {
    param(
        [Parameter(Mandatory)]
        [object[]]$PingData,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $total = @($PingData).Count
    $successful = @($PingData | Where-Object { $_.Success -eq $true }).Count
    $lost = $total - $successful
    $latencies = @($PingData | Where-Object { $_.Success -eq $true -and $null -ne $_.LatencyMs } | ForEach-Object { [double]$_.LatencyMs })

    $lossPercent = if ($total -gt 0) { [math]::Round(($lost / $total) * 100, 2) } else { 0 }
    $avgLatency = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Average).Average, 2) } else { $null }
    $maxLatency = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Maximum).Maximum, 2) } else { $null }
    $minLatency = if ($latencies.Count -gt 0) { [math]::Round(($latencies | Measure-Object -Minimum).Minimum, 2) } else { $null }

    return [pscustomobject]@{
        Name          = $Name
        ComputerName  = $env:COMPUTERNAME
        Target        = if ($total -gt 0) { $PingData[0].Target } else { "" }
        TotalSamples  = $total
        Successful    = $successful
        Lost          = $lost
        LossPercent   = $lossPercent
        MinLatencyMs  = $minLatency
        AvgLatencyMs  = $avgLatency
        MaxLatencyMs  = $maxLatency
    }
}

function Get-NetworkCounterSamplesSafe {
    param(
        [string]$InstanceFilterRegex = ""
    )

    $counterPaths = @(
        "\Network Interface(*)\Packets Received Errors",
        "\Network Interface(*)\Packets Outbound Errors",
        "\Network Interface(*)\Packets Received Discarded",
        "\Network Interface(*)\Packets Outbound Discarded",
        "\Network Interface(*)\Bytes Total/sec",
        "\Network Interface(*)\Packets/sec"
    )

    try {
        $sampleSet = Get-Counter -Counter $counterPaths -ErrorAction Stop

        $samples = foreach ($sample in $sampleSet.CounterSamples) {
            if (-not [string]::IsNullOrWhiteSpace($InstanceFilterRegex)) {
                if ($sample.InstanceName -notmatch $InstanceFilterRegex -and $sample.Path -notmatch $InstanceFilterRegex) {
                    continue
                }
            }

            [pscustomobject]@{
                Timestamp    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
                ComputerName = $env:COMPUTERNAME
                Path         = $sample.Path
                InstanceName = $sample.InstanceName
                CookedValue  = [math]::Round([double]$sample.CookedValue, 4)
            }
        }

        return @($samples)
    }
    catch {
        Write-LogMessage -Level Warning -Message "Could not collect network performance counters: $($_.Exception.Message)"
        return @()
    }
}

function Get-NetworkCounterSummary {
    param(
        [Parameter(Mandatory)]
        [object[]]$CounterData
    )

    $summary = foreach ($group in ($CounterData | Group-Object Path, InstanceName)) {
        $ordered = @($group.Group | Sort-Object Timestamp)

        if ($ordered.Count -eq 0) {
            continue
        }

        $values = @($ordered | ForEach-Object { [double]$_.CookedValue })
        $first = $values[0]
        $last = $values[$values.Count - 1]
        $max = ($values | Measure-Object -Maximum).Maximum
        $avg = ($values | Measure-Object -Average).Average

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Path         = $ordered[0].Path
            InstanceName = $ordered[0].InstanceName
            Samples      = $ordered.Count
            FirstValue   = [math]::Round($first, 4)
            LastValue    = [math]::Round($last, 4)
            Delta        = [math]::Round(($last - $first), 4)
            MaxValue     = [math]::Round($max, 4)
            AvgValue     = [math]::Round($avg, 4)
        }
    }

    return @($summary)
}

function Save-JsonSafe {
    param(
        [Parameter(Mandatory)]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$Depth = 8
    )

    try {
        $InputObject | ConvertTo-Json -Depth $Depth | Out-File -FilePath $Path -Encoding UTF8
    }
    catch {
        Write-LogMessage -Level Warning -Message "Could not write JSON file '$Path': $($_.Exception.Message)"
    }
}

if (-not (Test-IsAdministrator)) {
    throw "This script must be run from an elevated PowerShell session."
}

if ($DurationSeconds -lt 1) {
    throw "DurationSeconds must be greater than zero."
}

if ($SampleIntervalSeconds -lt 1) {
    throw "SampleIntervalSeconds must be greater than zero."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$safeRunName = New-SafeFileName -Value $RunName
$resultPath = Join-Path $OutputRoot "$safeRunName-$env:COMPUTERNAME-$timestamp"
New-Item -Path $resultPath -ItemType Directory -Force | Out-Null

$transcriptPath = Join-Path $resultPath "transcript.log"
Start-Transcript -Path $transcriptPath -Force | Out-Null

$pktmonStarted = $false
$peerPingResults = [System.Collections.Generic.List[object]]::new()
$vmPingResults = [System.Collections.Generic.List[object]]::new()
$counterResults = [System.Collections.Generic.List[object]]::new()

try {
    Write-LogMessage -Level Info -Message "Output path: $resultPath"
    Write-LogMessage -Level Info -Message "Computer: $env:COMPUTERNAME"
    Write-LogMessage -Level Info -Message "Duration: $DurationSeconds seconds; Sample interval: $SampleIntervalSeconds second(s)"

    $hostInventory = [ordered]@{
        ComputerName = $env:COMPUTERNAME
        Timestamp    = (Get-Date).ToString("s")
        NetAdapters  = @(Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, VlanID, ifIndex)
        NetIPConfig  = @(Get-NetIPConfiguration | Select-Object InterfaceAlias, InterfaceIndex, IPv4Address, IPv4DefaultGateway, DNSServer)
        VMSwitches   = @()
        VMHost       = $null
    }

    if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
        $hostInventory.VMSwitches = @(Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription, IovEnabled, IovSupport, IovSupportReasons, BandwidthReservationMode)
    }

    if (Get-Command Get-VMHost -ErrorAction SilentlyContinue) {
        $hostInventory.VMHost = Get-VMHost | Select-Object ComputerName, VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationPerformanceOption, MaximumVirtualMachineMigrations, MaximumStorageMigrations
    }

    Save-JsonSafe -InputObject $hostInventory -Path (Join-Path $resultPath "host-network-inventory.json") -Depth 8

    if (-not $SkipPktmon) {
        if (Get-Command pktmon.exe -ErrorAction SilentlyContinue) {
            Write-LogMessage -Level Info -Message "Starting pktmon NIC counters."

            & pktmon.exe filter remove | Out-File -FilePath (Join-Path $resultPath "pktmon-filter-remove.txt") -Encoding UTF8
            & pktmon.exe reset | Out-File -FilePath (Join-Path $resultPath "pktmon-reset.txt") -Encoding UTF8
            & pktmon.exe start --capture --counters-only --comp nics | Out-File -FilePath (Join-Path $resultPath "pktmon-start.txt") -Encoding UTF8

            $pktmonStarted = $true
        }
        else {
            Write-LogMessage -Level Warning -Message "pktmon.exe was not found. Skipping pktmon capture."
        }
    }
    else {
        Write-LogMessage -Level Info -Message "pktmon capture skipped by parameter."
    }

    $endTime = (Get-Date).AddSeconds($DurationSeconds)
    $sampleNumber = 0

    Write-LogMessage -Level Info -Message "Monitoring started. Start or continue the Live Migration now."

    while ((Get-Date) -lt $endTime) {
        $sampleNumber++

        if (-not $SkipPing) {
            if (-not [string]::IsNullOrWhiteSpace($PeerTarget)) {
                $peerPingResults.Add((Invoke-IcmpProbe -Target $PeerTarget -TimeoutMs $PingTimeoutMs))
            }

            if (-not [string]::IsNullOrWhiteSpace($VmTarget)) {
                $vmPingResults.Add((Invoke-IcmpProbe -Target $VmTarget -TimeoutMs $PingTimeoutMs))
            }
        }

        if (-not $SkipPerformanceCounters) {
            $samples = Get-NetworkCounterSamplesSafe -InstanceFilterRegex $CounterInstanceFilterRegex
            foreach ($sample in $samples) {
                $counterResults.Add($sample)
            }
        }

        if (($sampleNumber % 10) -eq 0) {
            $remaining = [math]::Max(0, [int]($endTime - (Get-Date)).TotalSeconds)
            Write-LogMessage -Level Info -Message "Collected sample $sampleNumber. Remaining: $remaining seconds."
        }

        Start-Sleep -Seconds $SampleIntervalSeconds
    }

    Write-LogMessage -Level Info -Message "Monitoring duration completed."
}
finally {
    if ($pktmonStarted) {
        Write-LogMessage -Level Info -Message "Collecting pktmon counters and stopping pktmon."

        try {
            & pktmon.exe counters | Out-File -FilePath (Join-Path $resultPath "pktmon-counters.txt") -Encoding UTF8
        }
        catch {
            Write-LogMessage -Level Warning -Message "Could not collect pktmon text counters: $($_.Exception.Message)"
        }

        try {
            & pktmon.exe counters --json | Out-File -FilePath (Join-Path $resultPath "pktmon-counters.json") -Encoding UTF8
        }
        catch {
            Write-LogMessage -Level Warning -Message "Could not collect pktmon JSON counters: $($_.Exception.Message)"
        }

        try {
            & pktmon.exe stop | Out-File -FilePath (Join-Path $resultPath "pktmon-stop.txt") -Encoding UTF8
        }
        catch {
            Write-LogMessage -Level Warning -Message "Could not stop pktmon: $($_.Exception.Message)"
        }
    }

    if ($peerPingResults.Count -gt 0) {
        $peerPingPath = Join-Path $resultPath "ping-peer.csv"
        $peerPingResults | Export-Csv -Path $peerPingPath -NoTypeInformation -Encoding UTF8
    }

    if ($vmPingResults.Count -gt 0) {
        $vmPingPath = Join-Path $resultPath "ping-vm.csv"
        $vmPingResults | Export-Csv -Path $vmPingPath -NoTypeInformation -Encoding UTF8
    }

    if ($counterResults.Count -gt 0) {
        $counterPath = Join-Path $resultPath "network-counters.csv"
        $counterResults | Export-Csv -Path $counterPath -NoTypeInformation -Encoding UTF8

        $counterSummary = Get-NetworkCounterSummary -CounterData @($counterResults)
        $counterSummary | Export-Csv -Path (Join-Path $resultPath "network-counter-summary.csv") -NoTypeInformation -Encoding UTF8
    }

    $summary = [System.Collections.Generic.List[object]]::new()

    if ($peerPingResults.Count -gt 0) {
        $summary.Add((Get-PingSummary -PingData @($peerPingResults) -Name "PeerTarget"))
    }

    if ($vmPingResults.Count -gt 0) {
        $summary.Add((Get-PingSummary -PingData @($vmPingResults) -Name "VmTarget"))
    }

    if ($counterResults.Count -gt 0) {
        $errorOrDiscardSummary = Get-NetworkCounterSummary -CounterData @($counterResults) |
            Where-Object {
                $_.Path -match "Errors|Discarded"
            }

        foreach ($item in $errorOrDiscardSummary) {
            $summary.Add([pscustomobject]@{
                Name          = "NetworkCounter"
                ComputerName  = $env:COMPUTERNAME
                Target        = $item.InstanceName
                TotalSamples  = $item.Samples
                Successful    = "n/a"
                Lost          = "n/a"
                LossPercent   = "n/a"
                MinLatencyMs  = "n/a"
                AvgLatencyMs  = "n/a"
                MaxLatencyMs  = "n/a"
                CounterPath   = $item.Path
                FirstValue    = $item.FirstValue
                LastValue     = $item.LastValue
                Delta         = $item.Delta
                MaxValue      = $item.MaxValue
            })
        }
    }

    $summary | Export-Csv -Path (Join-Path $resultPath "live-migration-network-summary.csv") -NoTypeInformation -Encoding UTF8
    Save-JsonSafe -InputObject $summary -Path (Join-Path $resultPath "live-migration-network-summary.json") -Depth 8

    Write-LogMessage -Level Success -Message "Result path: $resultPath"

    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Warning "Could not stop transcript: $($_.Exception.Message)"
    }

    if ($OpenResultFolder) {
        Invoke-Item -Path $resultPath
    }
}
