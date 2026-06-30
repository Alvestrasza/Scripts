<#
.SYNOPSIS
Stops the local Hyper-V cluster performance collector.

.DESCRIPTION
Stops the configured logman counter data collector set on the local server. The collected BLG files
remain in the configured root path and can be exported afterwards.

.NOTES
File Name     : Stop-HVClusterPerfCollector.ps1
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Stop local Hyper-V cluster performance data collection.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)] [string] $ConfigPath
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'HVClusterPerf.Common.ps1')

$config = Read-HVClusterPerfConfig -ConfigPath $ConfigPath
$collectorName = Get-HVPropertyValue -Object $config -Name 'CollectorName' -Default 'HVCluster-HostPerf'
$rootPath = Get-HVPropertyValue -Object $config -Name 'RootPath' -Default 'D:\PerfLogs\HVClusterPerf'
New-HVDirectory -Path $rootPath | Out-Null

$queryOutput = & logman.exe query $collectorName 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Collector '$collectorName' does not exist on $env:COMPUTERNAME."
}

$result = Invoke-HVExternalCommand -FilePath 'logman.exe' -ArgumentList @('stop', $collectorName) -OutputFile (Join-Path -Path $rootPath -ChildPath "Stop-$env:COMPUTERNAME-$(Get-HVTimestamp).log")

return [pscustomobject]@{
    ComputerName  = $env:COMPUTERNAME
    CollectorName = $collectorName
    Action        = 'Stop'
    ExitCode      = $result.ExitCode
    Output        = $result.Output
}
