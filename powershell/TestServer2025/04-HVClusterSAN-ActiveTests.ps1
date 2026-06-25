#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Active HA tests for a Windows Server 2025 Hyper-V Failover Cluster.

.DESCRIPTION
Optionally performs Live Migration, Quick Migration and controlled node drain tests.
Dangerous tests such as hard host failure or SAN path removal are documented as manual validation steps.

.NOTES
File Name     : 04-HVClusterSAN-ActiveTests.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025",
    [string]$ClusterName = "",
    [string]$TestVmClusterRoleName = "",
    [string]$TargetNode = "",
    [string]$NodeToDrain = "",

    [switch]$AllowLiveMigration,
    [switch]$AllowQuickMigration,
    [switch]$AllowNodeDrain
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVClusterSAN-ActiveTests"

Import-Module FailoverClusters -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    $ClusterName = (Get-Cluster).Name
}

# HA: Planned Live Migration
try {
    if ($AllowLiveMigration) {
        if ([string]::IsNullOrWhiteSpace($TestVmClusterRoleName) -or [string]::IsNullOrWhiteSpace($TargetNode)) {
            throw "TestVmClusterRoleName and TargetNode are required for Live Migration."
        }

        $before = Get-ClusterGroup -Cluster $ClusterName -Name $TestVmClusterRoleName
        Move-ClusterVirtualMachineRole -Name $TestVmClusterRoleName -Node $TargetNode -MigrationType Live -Wait 0 -ErrorAction Stop

        Start-Sleep -Seconds 10
        $after = Get-ClusterGroup -Cluster $ClusterName -Name $TestVmClusterRoleName

        $status = if ($after.OwnerNode.Name -eq $TargetNode -and $after.State -eq "Online") {
            "Successful"
        }
        else {
            "ManualReview"
        }

        Add-TestResult `
            -Area "HA" `
            -TestCase "Planned Live Migration" `
            -ExpectedResult "VM migrates without interruption." `
            -Status $status `
            -Remark "Before=$($before.OwnerNode.Name); After=$($after.OwnerNode.Name); State=$($after.State)" `
            -Data @{
                Before = $before
                After = $after
            }
    }
    else {
        Add-TestResult -Area "HA" -TestCase "Planned Live Migration" -ExpectedResult "VM migrates without interruption." -Status "Skipped" -Remark "AllowLiveMigration was not specified."
    }
}
catch {
    Add-TestResult -Area "HA" -TestCase "Planned Live Migration" -ExpectedResult "VM migrates without interruption." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# HA: Quick Migration
try {
    if ($AllowQuickMigration) {
        if ([string]::IsNullOrWhiteSpace($TestVmClusterRoleName) -or [string]::IsNullOrWhiteSpace($TargetNode)) {
            throw "TestVmClusterRoleName and TargetNode are required for Quick Migration."
        }

        $before = Get-ClusterGroup -Cluster $ClusterName -Name $TestVmClusterRoleName
        Move-ClusterVirtualMachineRole -Name $TestVmClusterRoleName -Node $TargetNode -MigrationType Quick -Wait 0 -ErrorAction Stop

        Start-Sleep -Seconds 10
        $after = Get-ClusterGroup -Cluster $ClusterName -Name $TestVmClusterRoleName

        $status = if ($after.OwnerNode.Name -eq $TargetNode -and $after.State -eq "Online") {
            "Successful"
        }
        else {
            "ManualReview"
        }

        Add-TestResult `
            -Area "HA" `
            -TestCase "Quick Migration" `
            -ExpectedResult "VM is moved successfully." `
            -Status $status `
            -Remark "Before=$($before.OwnerNode.Name); After=$($after.OwnerNode.Name); State=$($after.State)" `
            -Data @{
                Before = $before
                After = $after
            }
    }
    else {
        Add-TestResult -Area "HA" -TestCase "Quick Migration" -ExpectedResult "VM is moved successfully." -Status "Skipped" -Remark "AllowQuickMigration was not specified."
    }
}
catch {
    Add-TestResult -Area "HA" -TestCase "Quick Migration" -ExpectedResult "VM is moved successfully." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# HA: Controlled node drain instead of uncontrolled host failure
try {
    if ($AllowNodeDrain) {
        if ([string]::IsNullOrWhiteSpace($NodeToDrain)) {
            throw "NodeToDrain is required for controlled node drain."
        }

        $beforeGroups = Get-ClusterGroup -Cluster $ClusterName | Where-Object OwnerNode -eq $NodeToDrain

        Suspend-ClusterNode -Cluster $ClusterName -Name $NodeToDrain -Drain -ErrorAction Stop
        Start-Sleep -Seconds 20

        $nodeState = Get-ClusterNode -Cluster $ClusterName -Name $NodeToDrain
        $afterGroups = Get-ClusterGroup -Cluster $ClusterName | Where-Object OwnerNode -eq $NodeToDrain

        Resume-ClusterNode -Cluster $ClusterName -Name $NodeToDrain -Failback Immediate -ErrorAction Stop

        $status = if (($afterGroups | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

        Add-TestResult `
            -Area "HA" `
            -TestCase "Controlled node drain" `
            -ExpectedResult "Cluster roles are drained from the node without service outage." `
            -Status $status `
            -Remark "Node=$NodeToDrain; BeforeGroups=$(( $beforeGroups | Measure-Object ).Count); RemainingGroups=$(( $afterGroups | Measure-Object ).Count)" `
            -Data @{
                BeforeGroups = $beforeGroups
                AfterGroups = $afterGroups
                NodeState = $nodeState
            }
    }
    else {
        Add-TestResult -Area "HA" -TestCase "Controlled node drain" -ExpectedResult "Cluster roles move away from the node." -Status "Skipped" -Remark "AllowNodeDrain was not specified."
    }
}
catch {
    Add-TestResult -Area "HA" -TestCase "Controlled node drain" -ExpectedResult "Cluster roles move away from the node." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# HA: Hard host failure simulation
Add-TestResult `
    -Area "HA" `
    -TestCase "Hard host failure simulation" `
    -ExpectedResult "Automatic failover is successful." `
    -Status "ManualReview" `
    -Remark "Do not automate hard host failure in this script. Manual test: select a non-critical test VM, confirm owner node, disconnect/power off the selected host according to approved change plan, verify failover with Get-ClusterGroup and event logs."

# HA: SAN path failure simulation
Add-TestResult `
    -Area "HA" `
    -TestCase "SAN path failure simulation" `
    -ExpectedResult "Operation continues via remaining paths." `
    -Status "ManualReview" `
    -Remark "Do not automate SAN path removal in this script. Manual test: disable one SAN fabric path or switch port according to approved storage change plan, verify MPIO path state, CSV availability and VM I/O."

# Disaster Recovery: Complete outage recovery documentation
try {
    $clusterInfo = Get-Cluster -Name $ClusterName
    $groups = Get-ClusterGroup -Cluster $ClusterName
    $resources = Get-ClusterResource -Cluster $ClusterName
    $networks = Get-ClusterNetwork -Cluster $ClusterName
    $quorum = Get-ClusterQuorum -Cluster $ClusterName

    Add-TestResult `
        -Area "Disaster Recovery" `
        -TestCase "Recovery documentation export" `
        -ExpectedResult "Recovery-relevant cluster state is exported and documented." `
        -Status "Successful" `
        -Remark "Cluster recovery state exported to result JSON files." `
        -Data @{
            Cluster = $clusterInfo
            Groups = $groups
            Resources = $resources
            Networks = $networks
            Quorum = $quorum
        }
}
catch {
    Add-TestResult -Area "Disaster Recovery" -TestCase "Recovery documentation export" -ExpectedResult "Cluster recovery state can be exported." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun