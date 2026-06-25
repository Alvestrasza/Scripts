#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Common helper functions for Windows Server 2025 Hyper-V and Failover Cluster test plans.

.DESCRIPTION
Provides reusable functions for logging, result collection, CSV/JSON export, safe command execution,
event log checks, and administrative validation.

.NOTES
File Name     : 00-Common-TestHelpers.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

Set-StrictMode -Version Latest

$script:TestResults = [System.Collections.Generic.List[object]]::new()
$script:CurrentOutputRoot = $null
$script:CurrentRunName = $null

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-TestRun {
    param(
        [Parameter(Mandatory)]
        [string]$OutputRoot,

        [Parameter(Mandatory)]
        [string]$RunName
    )

    if (-not (Test-IsAdministrator)) {
        throw "This script must be run from an elevated PowerShell session."
    }

    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $script:CurrentRunName = "$RunName-$timestamp"
    $script:CurrentOutputRoot = Join-Path $OutputRoot $script:CurrentRunName

    New-Item -Path $script:CurrentOutputRoot -ItemType Directory -Force | Out-Null

    try {
        Start-Transcript -Path (Join-Path $script:CurrentOutputRoot "transcript.log") -Force | Out-Null
    }
    catch {
        Write-Warning "Could not start transcript: $($_.Exception.Message)"
    }

    Write-Host "Test output path: $script:CurrentOutputRoot" -ForegroundColor Cyan
}

function Add-TestResult {
    param(
        [Parameter(Mandatory)]
        [string]$Area,

        [Parameter(Mandatory)]
        [string]$TestCase,

        [Parameter(Mandatory)]
        [string]$ExpectedResult,

        [Parameter(Mandatory)]
        [ValidateSet("Successful", "NotSuccessful", "ManualReview", "Skipped")]
        [string]$Status,

        [string]$Tester = $env:USERNAME,

        [string]$Remark = "",

        [object]$Data = $null
    )

    $result = [pscustomobject]@{
        Timestamp      = (Get-Date).ToString("s")
        ComputerName   = $env:COMPUTERNAME
        Area           = $Area
        TestCase       = $TestCase
        ExpectedResult = $ExpectedResult
        Status         = $Status
        Tester         = $Tester
        Remark         = $Remark
    }

    $script:TestResults.Add($result)

    $color = switch ($Status) {
        "Successful"    { "Green" }
        "NotSuccessful" { "Red" }
        "ManualReview"  { "Yellow" }
        "Skipped"       { "DarkYellow" }
    }

    Write-Host "[$Status] $Area - $TestCase" -ForegroundColor $color
    if ($Remark) {
        Write-Host "  $Remark"
    }

    if ($null -ne $Data -and $script:CurrentOutputRoot) {
        $safeName = ($Area + "_" + $TestCase) -replace '[\\/:*?"<>| ]', '_'
        $dataPath = Join-Path $script:CurrentOutputRoot "$safeName.json"
        $Data | ConvertTo-Json -Depth 8 | Out-File -FilePath $dataPath -Encoding UTF8
    }
}

function Complete-TestRun {
    if (-not $script:CurrentOutputRoot) {
        throw "Test run was not initialized."
    }

    $csvPath = Join-Path $script:CurrentOutputRoot "test-results.csv"
    $jsonPath = Join-Path $script:CurrentOutputRoot "test-results.json"

    $script:TestResults | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    $script:TestResults | ConvertTo-Json -Depth 8 | Out-File -FilePath $jsonPath -Encoding UTF8

    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Warning "Could not stop transcript: $($_.Exception.Message)"
    }

    Write-Host "Result CSV : $csvPath" -ForegroundColor Cyan
    Write-Host "Result JSON: $jsonPath" -ForegroundColor Cyan
}

function Test-CommandExists {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-RecentEventSummary {
    param(
        [int]$Hours = 24,
        [string[]]$LogNames = @("System", "Application"),
        [int[]]$Levels = @(1, 2, 3)
    )

    $startTime = (Get-Date).AddHours(-$Hours)
    $events = foreach ($logName in $LogNames) {
        try {
            Get-WinEvent -FilterHashtable @{
                LogName   = $logName
                Level     = $Levels
                StartTime = $startTime
            } -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not read log '$logName': $($_.Exception.Message)"
        }
    }

    return $events | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, LogName, Message
}

function Test-TcpPort {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [int]$Port
    )

    try {
        $result = Test-NetConnection -ComputerName $ComputerName -Port $Port -WarningAction SilentlyContinue
        return [pscustomobject]@{
            ComputerName = $ComputerName
            Port         = $Port
            TcpSucceeded = $result.TcpTestSucceeded
            PingSucceeded = $result.PingSucceeded
        }
    }
    catch {
        return [pscustomobject]@{
            ComputerName = $ComputerName
            Port         = $Port
            TcpSucceeded = $false
            PingSucceeded = $false
            Error        = $_.Exception.Message
        }
    }
}