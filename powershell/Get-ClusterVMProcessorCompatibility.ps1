<#
.SYNOPSIS
Reports Hyper-V processor compatibility settings for all clustered virtual machines.

.DESCRIPTION
Gets all virtual machine roles from a Hyper-V failover cluster and reports whether
processor compatibility for live migration to a physical computer with a different
processor version is enabled.

.EXAMPLE
Show all cluster vms
.\Get-ClusterVMProcessorCompatibility.ps1 -ClusterName "HV-CLUSTER01" | Format-Table -AutoSize

Only show vms with option disabled
.\Get-ClusterVMProcessorCompatibility.ps1 -ClusterName "HV-CLUSTER01" -OnlyDisabled | Format-Table -AutoSize

Export result as csv
.\Get-ClusterVMProcessorCompatibility.ps1 -ClusterName "HV-CLUSTER01" -CsvPath ".\HyperV_VM_CPU_Compatibility.csv"

.NOTES
File Name     : Get-ClusterVMProcessorCompatibility.ps1
Version       : v0.1.0
Created       : 2026-06-11
Last Modified : 2026-06-11
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ClusterName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$CsvPath,

    [Parameter(Mandatory = $false)]
    [switch]$OnlyDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module FailoverClusters -ErrorAction Stop
Import-Module Hyper-V -ErrorAction Stop

$clusterGroups = Get-ClusterGroup -Cluster $ClusterName -ErrorAction Stop |
    Where-Object { $_.GroupType -eq 'VirtualMachine' }

$results = foreach ($clusterGroup in $clusterGroups) {
    try {
        $vm = $clusterGroup | Get-VM -ErrorAction Stop
        $processor = $vm | Get-VMProcessor -ErrorAction Stop

        [pscustomobject]@{
            ClusterName                      = $ClusterName
            ClusterGroupName                 = $clusterGroup.Name
            VMName                           = $vm.Name
            VMState                          = $vm.State
            OwnerNode                        = [string]$clusterGroup.OwnerNode
            ComputerName                     = $vm.ComputerName
            CompatibilityForMigrationEnabled = $processor.CompatibilityForMigrationEnabled
            Status                           = 'OK'
            ErrorMessage                     = $null
        }
    }
    catch {
        [pscustomobject]@{
            ClusterName                      = $ClusterName
            ClusterGroupName                 = $clusterGroup.Name
            VMName                           = $null
            VMState                          = $null
            OwnerNode                        = [string]$clusterGroup.OwnerNode
            ComputerName                     = $null
            CompatibilityForMigrationEnabled = $null
            Status                           = 'Error'
            ErrorMessage                     = $_.Exception.Message
        }
    }
}

if ($OnlyDisabled) {
    $results = $results | Where-Object {
        $_.Status -eq 'OK' -and $_.CompatibilityForMigrationEnabled -eq $false
    }
}

$results = $results | Sort-Object VMName, ClusterGroupName

if ($CsvPath) {
    $results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
}

$results