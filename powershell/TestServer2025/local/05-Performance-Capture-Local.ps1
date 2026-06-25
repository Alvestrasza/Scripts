#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Local-only performance capture script for Windows Server 2025 Hyper-V hosts and cluster nodes.

.DESCRIPTION
Collects local CPU, memory, Hyper-V, network and disk counters. Optionally runs DiskSpd and iperf3
when tool paths and targets are provided. This script does not use PowerShell remoting.

.NOTES
File Name     : 05-Performance-Capture-Local.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025",
    [int]$SampleIntervalSeconds = 5,
    [int]$MaxSamples = 12,

    [string]$DiskSpdPath = "",
    [string]$DiskSpdTestPath = "D:\CustomerTests\Server2025\DiskSpd",

    [string]$Iperf3Path = "",
    [string]$Iperf3Server = "",
    [int]$Iperf3Seconds = 30
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "Performance-Capture-Local-$env:COMPUTERNAME"

$counters = @(
    "\Processor(_Total)\% Processor Time",
    "\Memory\Available MBytes",
    "\Memory\Committed Bytes",
    "\Hyper-V Hypervisor Logical Processor(_Total)\% Total Run Time",
    "\Hyper-V Dynamic Memory VM(*)\Current Pressure",
    "\Network Interface(*)\Bytes Total/sec",
    "\PhysicalDisk(_Total)\Disk Reads/sec",
    "\PhysicalDisk(_Total)\Disk Writes/sec",
    "\PhysicalDisk(_Total)\Avg. Disk sec/Read",
    "\PhysicalDisk(_Total)\Avg. Disk sec/Write"
)

try {
    $safeComputer = $env:COMPUTERNAME -replace '[\\/:*?"<>| ]', '_'
    $blgPath = Join-Path $script:CurrentOutputRoot "$safeComputer-performance.blg"
    $csvPath = Join-Path $script:CurrentOutputRoot "$safeComputer-performance.csv"

    $counterData = Get-Counter `
        -Counter $counters `
        -SampleInterval $SampleIntervalSeconds `
        -MaxSamples $MaxSamples `
        -ErrorAction Stop

    $counterData | Export-Counter -Path $blgPath -FileFormat BLG -Force
    $counterData.CounterSamples |
        Select-Object Timestamp, Path, InstanceName, CookedValue |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Add-TestResult `
        -Area "Performance" `
        -TestCase "Local performance counter capture" `
        -ExpectedResult "CPU, RAM, network and disk counters are captured locally." `
        -Status "Successful" `
        -Remark "Computer=$env:COMPUTERNAME; BLG=$blgPath; CSV=$csvPath"
}
catch {
    Add-TestResult -Area "Performance" -TestCase "Local performance counter capture" -ExpectedResult "Performance counters can be captured locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if (-not [string]::IsNullOrWhiteSpace($DiskSpdPath) -and (Test-Path $DiskSpdPath)) {
        New-Item -Path $DiskSpdTestPath -ItemType Directory -Force | Out-Null
        $diskSpdOutput = Join-Path $script:CurrentOutputRoot "diskspd-output.txt"
        $testFile = Join-Path $DiskSpdTestPath "diskspd-test.dat"

        & $DiskSpdPath -c4G -d60 -r -w30 -t4 -o8 -b64K -L $testFile | Tee-Object -FilePath $diskSpdOutput

        Add-TestResult `
            -Area "Performance" `
            -TestCase "Local storage I/O test with DiskSpd" `
            -ExpectedResult "Expected IOPS and latency are reached." `
            -Status "ManualReview" `
            -Remark "DiskSpd completed locally. Review output: $diskSpdOutput"
    }
    else {
        Add-TestResult -Area "Performance" -TestCase "Local storage I/O test with DiskSpd" -ExpectedResult "Expected IOPS and latency are reached." -Status "Skipped" -Remark "DiskSpdPath was not provided or does not exist."
    }
}
catch {
    Add-TestResult -Area "Performance" -TestCase "Local storage I/O test with DiskSpd" -ExpectedResult "Storage I/O test completes locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if (-not [string]::IsNullOrWhiteSpace($Iperf3Path) -and (Test-Path $Iperf3Path) -and -not [string]::IsNullOrWhiteSpace($Iperf3Server)) {
        $iperfOutput = Join-Path $script:CurrentOutputRoot "iperf3-output.txt"
        & $Iperf3Path -c $Iperf3Server -t $Iperf3Seconds | Tee-Object -FilePath $iperfOutput

        Add-TestResult `
            -Area "Performance" `
            -TestCase "Network throughput test with iperf3" `
            -ExpectedResult "Expected network bandwidth is reached." `
            -Status "ManualReview" `
            -Remark "iperf3 completed locally as client. Review output: $iperfOutput"
    }
    else {
        Add-TestResult -Area "Performance" -TestCase "Network throughput test with iperf3" -ExpectedResult "Expected network bandwidth is reached." -Status "Skipped" -Remark "Iperf3Path or Iperf3Server was not provided."
    }
}
catch {
    Add-TestResult -Area "Performance" -TestCase "Network throughput test with iperf3" -ExpectedResult "Network throughput test completes locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun
