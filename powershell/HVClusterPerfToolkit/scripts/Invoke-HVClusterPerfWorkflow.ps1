<#
.SYNOPSIS
Runs the Hyper-V cluster performance toolkit on one or more cluster nodes.

.DESCRIPTION
Copies the toolkit to the target servers through admin shares and executes the selected action through
PowerShell Remoting. Supported actions are Initialize, Start, Stop, Export, StopAndExport, and Status.
Use this script from an administrative management host or from one of the cluster nodes.

.NOTES
File Name     : Invoke-HVClusterPerfWorkflow.ps1
Version       : v0.1.1
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Orchestrate Hyper-V cluster performance data collection across multiple hosts.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Initialize', 'Start', 'Stop', 'Export', 'StopAndExport', 'Status')]
    [string] $Action,

    [Parameter(Mandatory = $false)] [string] $ConfigPath,
    [Parameter(Mandatory = $false)] [string] $ClusterName,
    [Parameter(Mandatory = $false)] [string[]] $ComputerName,
    [Parameter(Mandatory = $false)] [string] $ToolkitRemotePath = 'D:\PerfLogs\HVClusterPerf\Toolkit',
    [Parameter(Mandatory = $false)] [string] $RunId,
    [Parameter(Mandatory = $false)] [string] $CounterFile,
    [Parameter(Mandatory = $false)] [switch] $SkipCopy,
    [Parameter(Mandatory = $false)] [switch] $CollectExports,
    [Parameter(Mandatory = $false)] [switch] $ForceRecreate,
    [Parameter(Mandatory = $false)] [switch] $SkipCounterValidation
)

. (Join-Path -Path $PSScriptRoot -ChildPath 'HVClusterPerf.Common.ps1')

$localRoot = Get-HVToolkitRoot
$config = Read-HVClusterPerfConfig -ConfigPath $ConfigPath
$nodes = Resolve-HVClusterPerfNodes -Config $config -ComputerName $ComputerName -ClusterName $ClusterName

if (-not $nodes -or $nodes.Count -eq 0) {
    throw 'No target nodes were resolved.'
}

if ([string]::IsNullOrWhiteSpace($RunId)) {
    $RunId = "Run-$(Get-HVTimestamp)"
}

Write-Host "Target nodes: $($nodes -join ', ')"
Write-Host "Action      : $Action"
Write-Host "RunId       : $RunId"
if (-not [string]::IsNullOrWhiteSpace($CounterFile)) { Write-Host "CounterFile : $CounterFile" }

$results = New-Object System.Collections.Generic.List[object]

foreach ($node in $nodes) {
    Write-Host "Processing $node ..."

    if (-not $SkipCopy) {
        $remoteUncPath = ConvertTo-HVAdminSharePath -ComputerName $node -LocalPath $ToolkitRemotePath
        if (-not (Test-Path -Path $remoteUncPath)) {
            New-Item -Path $remoteUncPath -ItemType Directory -Force | Out-Null
        }

        $robocopyLog = Join-Path -Path $env:TEMP -ChildPath "HVClusterPerfToolkit-Robocopy-$node-$(Get-HVTimestamp).log"
        $robocopyArgs = @(
            $localRoot,
            $remoteUncPath,
            '/MIR', '/R:2', '/W:2', '/NFL', '/NDL', '/NP', "/LOG:$robocopyLog"
        )

        & robocopy.exe @robocopyArgs | Out-Null
        if ($LASTEXITCODE -gt 7) {
            throw "Robocopy to $node failed with exit code $LASTEXITCODE. Log: $robocopyLog"
        }
    }

    $remoteResult = Invoke-Command -ComputerName $node -ScriptBlock {
        param(
            [string] $RemoteRoot,
            [string] $SelectedAction,
            [string] $RemoteRunId,
            [bool] $RemoteForceRecreate,
            [bool] $RemoteSkipCounterValidation,
            [string] $RemoteCounterFile
        )

        $configFile = Join-Path -Path $RemoteRoot -ChildPath 'config\HVClusterPerfConfig.json'
        $scriptRoot = Join-Path -Path $RemoteRoot -ChildPath 'scripts'
        $resolvedRemoteCounterFile = $null
        if (-not [string]::IsNullOrWhiteSpace($RemoteCounterFile)) {
            if ([System.IO.Path]::IsPathRooted($RemoteCounterFile)) {
                $resolvedRemoteCounterFile = $RemoteCounterFile
            }
            else {
                $resolvedRemoteCounterFile = Join-Path -Path $RemoteRoot -ChildPath $RemoteCounterFile
            }
        }

        switch ($SelectedAction) {
            'Initialize' {
                $script = Join-Path -Path $scriptRoot -ChildPath 'Initialize-HVClusterPerfCollector.ps1'
                & $script -ConfigPath $configFile -CounterFile $resolvedRemoteCounterFile -ForceRecreate:$RemoteForceRecreate -SkipCounterValidation:$RemoteSkipCounterValidation
            }
            'Start' {
                $script = Join-Path -Path $scriptRoot -ChildPath 'Start-HVClusterPerfCollector.ps1'
                & $script -ConfigPath $configFile
            }
            'Stop' {
                $script = Join-Path -Path $scriptRoot -ChildPath 'Stop-HVClusterPerfCollector.ps1'
                & $script -ConfigPath $configFile
            }
            'Export' {
                $script = Join-Path -Path $scriptRoot -ChildPath 'Export-HVClusterPerfEvidence.ps1'
                & $script -ConfigPath $configFile -RunId $RemoteRunId
            }
            'StopAndExport' {
                $stopScript = Join-Path -Path $scriptRoot -ChildPath 'Stop-HVClusterPerfCollector.ps1'
                $exportScript = Join-Path -Path $scriptRoot -ChildPath 'Export-HVClusterPerfEvidence.ps1'
                & $stopScript -ConfigPath $configFile
                & $exportScript -ConfigPath $configFile -RunId $RemoteRunId
            }
            'Status' {
                $configJson = Get-Content -Path $configFile -Raw | ConvertFrom-Json
                $collectorName = if ($configJson.CollectorName) { $configJson.CollectorName } else { 'HVCluster-HostPerf' }
                $statusText = & logman.exe query $collectorName 2>&1
                [pscustomobject]@{
                    ComputerName  = $env:COMPUTERNAME
                    CollectorName = $collectorName
                    Action        = 'Status'
                    ExitCode      = $LASTEXITCODE
                    Output        = ($statusText -join [Environment]::NewLine)
                }
            }
        }
    } -ArgumentList $ToolkitRemotePath, $Action, $RunId, [bool]$ForceRecreate, [bool]$SkipCounterValidation, $CounterFile

    foreach ($item in @($remoteResult)) {
        $results.Add($item)
    }

    if ($CollectExports -and ($Action -eq 'Export' -or $Action -eq 'StopAndExport')) {
        foreach ($item in @($remoteResult)) {
            if ($item.PSObject.Properties.Name -contains 'ZipPath' -and -not [string]::IsNullOrWhiteSpace($item.ZipPath)) {
                $sourceUnc = ConvertTo-HVAdminSharePath -ComputerName $node -LocalPath $item.ZipPath
                $localExportRoot = Join-Path -Path $localRoot -ChildPath "CollectedExports\$RunId"
                New-HVDirectory -Path $localExportRoot | Out-Null
                Copy-Item -Path $sourceUnc -Destination $localExportRoot -Force
            }
        }
    }
}

$summaryPath = Join-Path -Path $localRoot -ChildPath "WorkflowSummary-$RunId.csv"
$results | Export-Csv -Path $summaryPath -NoTypeInformation -Encoding UTF8 -Force
Write-Host "Workflow summary written to: $summaryPath"

return $results
