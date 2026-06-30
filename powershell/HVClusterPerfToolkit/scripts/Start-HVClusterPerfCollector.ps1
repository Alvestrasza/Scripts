<#
.SYNOPSIS
Starts the local Hyper-V cluster performance collector.

.DESCRIPTION
Starts the configured logman counter data collector set on the local server.

.NOTES
File Name     : Start-HVClusterPerfCollector.ps1
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Start local Hyper-V cluster performance data collection.
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
    throw "Collector '$collectorName' does not exist on $env:COMPUTERNAME. Run Initialize-HVClusterPerfCollector.ps1 first."
}

$result = Invoke-HVExternalCommand -FilePath 'logman.exe' -ArgumentList @('start', $collectorName) -OutputFile (Join-Path -Path $rootPath -ChildPath "Start-$env:COMPUTERNAME-$(Get-HVTimestamp).log")

return [pscustomobject]@{
    ComputerName  = $env:COMPUTERNAME
    CollectorName = $collectorName
    Action        = 'Start'
    ExitCode      = $result.ExitCode
    Output        = $result.Output
}
