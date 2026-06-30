<#
.SYNOPSIS
Exports Hyper-V cluster performance evidence from the local server.

.DESCRIPTION
Exports BLG files, event logs, cluster status, Hyper-V settings, VM inventory, network information,
storage information, MPIO/iSCSI data, and selected command outputs into a ZIP archive per host.

.NOTES
File Name     : Export-HVClusterPerfEvidence.ps1
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Export local Hyper-V cluster performance evidence into a compressed archive.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ConfigPath,
    [Parameter(Mandatory = $false)] [string] $RunId,
    [Parameter(Mandatory = $false)] [switch] $SkipEventLogs,
    [Parameter(Mandatory = $false)] [switch] $SkipBlgCopy
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'HVClusterPerf.Common.ps1')

$config = Read-HVClusterPerfConfig -ConfigPath $ConfigPath
$rootPath = Get-HVPropertyValue -Object $config -Name 'RootPath' -Default 'D:\PerfLogs\HVClusterPerf'
$eventLookbackHours = [int](Get-HVPropertyValue -Object $config -Name 'EventLookbackHours' -Default 12)
$eventLogs = @(Get-HVPropertyValue -Object $config -Name 'EventLogs' -Default @('System', 'Application'))

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "Run-$(Get-HVTimestamp)"
}

$exportRoot = New-HVDirectory -Path (Join-Path -Path $rootPath -ChildPath "Exports\$RunId\$env:COMPUTERNAME")
$metadataPath = New-HVDirectory -Path (Join-Path -Path $exportRoot -ChildPath 'Metadata')
$eventPath = New-HVDirectory -Path (Join-Path -Path $exportRoot -ChildPath 'Events')
$blgExportPath = New-HVDirectory -Path (Join-Path -Path $exportRoot -ChildPath 'BLG')
$snapshotPath = New-HVDirectory -Path (Join-Path -Path $exportRoot -ChildPath 'Snapshot')

[pscustomobject]@{
    ComputerName       = $env:COMPUTERNAME
    RunId              = $RunId
    ExportStarted      = (Get-Date).ToString('s')
    RootPath           = $rootPath
    EventLookbackHours = $eventLookbackHours
    User               = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
} | Export-Csv -Path (Join-Path -Path $metadataPath -ChildPath 'ExportMetadata.csv') -NoTypeInformation -Encoding UTF8 -Force

Export-HVClusterPerfSnapshot -OutputDirectory $snapshotPath

if (-not $SkipEventLogs) {
    Export-HVEventLogs -OutputDirectory $eventPath -LogNames $eventLogs -LookbackHours $eventLookbackHours
}

if (-not $SkipBlgCopy) {
    $blgSourcePath = Join-Path -Path $rootPath -ChildPath "BLG\$env:COMPUTERNAME"
    if (Test-Path -Path $blgSourcePath) {
        Get-ChildItem -Path $blgSourcePath -Filter '*.blg' -File -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-Item -Path $_.FullName -Destination (Join-Path -Path $blgExportPath -ChildPath $_.Name) -Force
        }
    }
    else {
        "BLG source path not found: $blgSourcePath" | Out-File -FilePath (Join-Path -Path $blgExportPath -ChildPath 'BLGSourcePathMissing.txt') -Encoding UTF8 -Force
    }
}

$zipPath = Join-Path -Path (Split-Path -Path $exportRoot -Parent) -ChildPath "$env:COMPUTERNAME-$RunId.zip"
if (Test-Path -Path $zipPath) {
    Remove-Item -Path $zipPath -Force
}

Compress-Archive -Path (Join-Path -Path $exportRoot -ChildPath '*') -DestinationPath $zipPath -Force

return [pscustomobject]@{
    ComputerName = $env:COMPUTERNAME
    RunId        = $RunId
    ExportPath   = $exportRoot
    ZipPath      = $zipPath
    Status       = 'Exported'
}
