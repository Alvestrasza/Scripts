<#
.SYNOPSIS
Creates or recreates the local Hyper-V cluster performance collector.

.DESCRIPTION
Creates the folder structure, validates the configured performance counters, and creates a local
logman counter data collector set for Hyper-V cluster performance analysis. The collector is not
started automatically unless Start-HVClusterPerfCollector.ps1 is called afterwards.

.NOTES
File Name     : Initialize-HVClusterPerfCollector.ps1
Version       : v0.1.1
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Initialize local logman performance collector for Hyper-V cluster analysis.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)] [string] $ConfigPath,
    [Parameter(Mandatory = $false)] [string] $CounterFile,
    [Parameter(Mandatory = $false)] [switch] $SkipCounterValidation,
    [Parameter(Mandatory = $false)] [switch] $ForceRecreate
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'HVClusterPerf.Common.ps1')

$config = Read-HVClusterPerfConfig -ConfigPath $ConfigPath
$rootPath = Get-HVPropertyValue -Object $config -Name 'RootPath' -Default 'D:\PerfLogs\HVClusterPerf'
$collectorName = Get-HVPropertyValue -Object $config -Name 'CollectorName' -Default 'HVCluster-HostPerf'
$sampleInterval = Get-HVPropertyValue -Object $config -Name 'SampleInterval' -Default '00:00:15'
$maxFileSizeMb = [int](Get-HVPropertyValue -Object $config -Name 'MaxFileSizeMB' -Default 4096)

if ([string]::IsNullOrWhiteSpace($CounterFile)) {
    $defaultCounterFile = Get-HVPropertyValue -Object $config -Name 'DefaultCounterFile' -Default 'counters\HostCounters-English.txt'
    $CounterFile = Resolve-HVToolkitRelativePath -Path $defaultCounterFile
}
else {
    $CounterFile = Resolve-HVToolkitRelativePath -Path $CounterFile
}

New-HVDirectory -Path $rootPath | Out-Null
$blgPath = New-HVDirectory -Path (Join-Path -Path $rootPath -ChildPath "BLG\$env:COMPUTERNAME")
$validationPath = New-HVDirectory -Path (Join-Path -Path $rootPath -ChildPath 'CounterValidation')
$snapshotPath = New-HVDirectory -Path (Join-Path -Path $rootPath -ChildPath "InitializationSnapshot\$env:COMPUTERNAME")

$counters = Read-HVCounterFile -CounterFile $CounterFile
$activeCounterFile = $CounterFile

if (-not $SkipCounterValidation) {
    Write-Host "Validating counters on $env:COMPUTERNAME ..."
    $validation = Test-HVCounterList -Counters $counters -OutputDirectory $validationPath
    $activeCounterFile = $validation.ValidFile

    if ($validation.ValidCount -eq 0) {
        throw 'No valid counters available. Collector creation was aborted.'
    }

    Write-Host "Counter validation completed. Valid counters: $($validation.ValidCount) / $($validation.TotalCount)"
    Write-Host "Validation report: $($validation.ResultCsv)"
}

$collectorOutput = Join-Path -Path $blgPath -ChildPath "$collectorName.blg"
$queryOutput = & logman.exe query $collectorName 2>&1
$collectorExists = ($LASTEXITCODE -eq 0)

if ($collectorExists) {
    if (-not $ForceRecreate) {
        Write-Host "Collector '$collectorName' already exists. Use -ForceRecreate to recreate it."
        return [pscustomobject]@{
            ComputerName  = $env:COMPUTERNAME
            CollectorName = $collectorName
            Status        = 'AlreadyExists'
            OutputPath    = $collectorOutput
        }
    }

    Write-Host "Stopping and deleting existing collector '$collectorName' on $env:COMPUTERNAME ..."
    & logman.exe stop $collectorName 2>$null | Out-Null
    & logman.exe delete $collectorName 2>$null | Out-Null
}

$args = @(
    'create', 'counter', $collectorName,
    '-cf', $activeCounterFile,
    '-si', $sampleInterval,
    '-f', 'bincirc',
    '-v', 'mmddhhmm',
    '-max', $maxFileSizeMb.ToString(),
    '-o', $collectorOutput
)

if ($PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Create logman collector $collectorName")) {
    Write-Host "Creating collector '$collectorName' on $env:COMPUTERNAME ..."
    $createResult = Invoke-HVExternalCommand -FilePath 'logman.exe' -ArgumentList $args -OutputFile (Join-Path -Path $rootPath -ChildPath "Initialize-$env:COMPUTERNAME.log")

    if ($createResult.ExitCode -ne 0) {
        throw "logman collector creation failed with exit code $($createResult.ExitCode). Output: $($createResult.Output)"
    }
}

Export-HVClusterPerfSnapshot -OutputDirectory $snapshotPath

return [pscustomobject]@{
    ComputerName      = $env:COMPUTERNAME
    CollectorName     = $collectorName
    Status            = 'Created'
    CounterFile       = $activeCounterFile
    OutputPath        = $collectorOutput
    SampleInterval    = $sampleInterval
    MaxFileSizeMB     = $maxFileSizeMb
    InitializationLog = (Join-Path -Path $rootPath -ChildPath "Initialize-$env:COMPUTERNAME.log")
}
