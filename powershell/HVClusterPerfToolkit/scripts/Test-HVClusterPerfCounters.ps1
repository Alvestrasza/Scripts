<#
.SYNOPSIS
Validates performance counter paths for the local server.

.DESCRIPTION
Reads a counter file, tests each performance counter with Get-Counter, writes validation results,
and creates a valid counter file that can be consumed by logman.

.NOTES
File Name     : Test-HVClusterPerfCounters.ps1
Version       : v0.1.1
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Validate Hyper-V cluster performance counters before collector creation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ConfigPath,
    [Parameter(Mandatory = $false)] [string] $CounterFile,
    [Parameter(Mandatory = $false)] [string] $OutputDirectory
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'HVClusterPerf.Common.ps1')

$config = Read-HVClusterPerfConfig -ConfigPath $ConfigPath
$rootPath = Get-HVPropertyValue -Object $config -Name 'RootPath' -Default 'D:\PerfLogs\HVClusterPerf'

if ([string]::IsNullOrWhiteSpace($CounterFile)) {
    $defaultCounterFile = Get-HVPropertyValue -Object $config -Name 'DefaultCounterFile' -Default 'counters\HostCounters-English.txt'
    $CounterFile = Resolve-HVToolkitRelativePath -Path $defaultCounterFile
}
else {
    $CounterFile = Resolve-HVToolkitRelativePath -Path $CounterFile
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path -Path $rootPath -ChildPath 'CounterValidation'
}

$counters = Read-HVCounterFile -CounterFile $CounterFile
$result = Test-HVCounterList -Counters $counters -OutputDirectory $OutputDirectory

$result | Format-List

if ($result.ValidCount -eq 0) {
    throw 'No valid performance counters were found. Check OS language, Hyper-V role installation, and counter file localization.'
}
