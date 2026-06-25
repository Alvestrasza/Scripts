#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Read-only assessment for a Windows Server 2025 Hyper-V Failover Cluster with SAN storage.

.DESCRIPTION
Checks cluster nodes, cluster networks, Live Migration configuration, SR-IOV readiness,
SAN paths, MPIO, CSV state, VM roles, updates, CAU state, SMB, NTLM policy state,
event logs, quorum, cluster functional level, integration services, and driver information.

.NOTES
File Name     : 03-HVClusterSAN-Assessment.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = ".\Logs",
    [string]$ClusterName = "",
    [string[]]$ExpectedNodes = @(),
    [switch]$RunClusterValidation,
    [string]$NodeFqdnSuffix = "",
    [string]$WindowsAdminCenterUrl = ""
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVClusterSAN-Assessment"

Import-Module FailoverClusters -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    $ClusterName = (Get-Cluster).Name
}

# Cluster: Validation
try {
    if ($RunClusterValidation) {
        $reportPath = Join-Path $script:CurrentOutputRoot "ClusterValidation"
        New-Item -Path $reportPath -ItemType Directory -Force | Out-Null

        $validation = Test-Cluster -Cluster $ClusterName -ReportName (Join-Path $reportPath "validation-report") -Verbose

        Add-TestResult `
            -Area "Cluster" `
            -TestCase "Run cluster validation" `
            -ExpectedResult "Validation report has no critical errors." `
            -Status "ManualReview" `
            -Remark "Cluster validation executed. Review generated validation report." `
            -Data $validation
    }
    else {
        Add-TestResult `
            -Area "Cluster" `
            -TestCase "Run cluster validation" `
            -ExpectedResult "Validation report has no critical errors." `
            -Status "Skipped" `
            -Remark "RunClusterValidation was not specified."
    }
}
catch {
    Add-TestResult -Area "Cluster" -TestCase "Run cluster validation" -ExpectedResult "Validation report can be generated." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Cluster: Cluster service and nodes
try {
    $nodes = Get-ClusterNode -Cluster $ClusterName
    $missingNodes = @()

    foreach ($expected in $ExpectedNodes) {
        if ($expected -notin $nodes.Name) {
            $missingNodes += $expected
        }
    }

    $downNodes = $nodes | Where-Object State -ne "Up"

    $status = if (($downNodes | Measure-Object).Count -eq 0 -and $missingNodes.Count -eq 0) {
        "Successful"
    }
    else {
        "NotSuccessful"
    }

    Add-TestResult `
        -Area "Cluster" `
        -TestCase "Cluster service check" `
        -ExpectedResult "All cluster nodes are online." `
        -Status $status `
        -Remark "Nodes=$($nodes.Name -join ', '); Down=$($downNodes.Name -join ', '); Missing=$($missingNodes -join ', ')" `
        -Data $nodes
}
catch {
    Add-TestResult -Area "Cluster" -TestCase "Cluster service check" -ExpectedResult "Cluster nodes can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Resolve cluster node names to FQDNs when required.
# This is important in environments using Remote Credential Guard,
# Kerberos-only authentication, cross-domain administration, or strict SPN validation.

$clusterNodes = @(Get-ClusterNode -Cluster $ClusterName | Select-Object -ExpandProperty Name)

function Convert-ToNodeFqdn {
    param(
        [Parameter(Mandatory)]
        [string]$NodeName,

        [string]$Suffix = ""
    )

    if ($NodeName -match "\.") {
        return $NodeName.ToLower()
    }

    if (-not [string]::IsNullOrWhiteSpace($Suffix)) {
        return "$NodeName.$Suffix".ToLower()
    }

    try {
        $dnsResult = Resolve-DnsName -Name $NodeName -Type A -ErrorAction Stop |
            Select-Object -First 1

        if ($dnsResult.Name -match "\.") {
            return $dnsResult.Name.ToLower().TrimEnd(".")
        }
    }
    catch {
        Write-Warning "Could not resolve FQDN for node '$NodeName'. Falling back to short name."
    }

    return $NodeName
}

$nodeNames = @(
    foreach ($node in $clusterNodes) {
        Convert-ToNodeFqdn -NodeName $node -Suffix $NodeFqdnSuffix
    }
)

Write-Host "Cluster nodes used for PowerShell remoting:" -ForegroundColor Cyan
$nodeNames | ForEach-Object {
    Write-Host "  $_" -ForegroundColor Cyan
}

# Network: Management connectivity
try {
    $networkChecks = foreach ($node in $nodeNames) {
        Test-TcpPort -ComputerName $node -Port 5985
        Test-TcpPort -ComputerName $node -Port 3389
    }

    $failed = $networkChecks | Where-Object { -not $_.PingSucceeded -and -not $_.TcpSucceeded }
    $status = if (($failed | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Management network test" `
        -ExpectedResult "All nodes are reachable." `
        -Status $status `
        -Remark "Checked nodes: $($nodeNames -join ', ')" `
        -Data $networkChecks
}
catch {
    Add-TestResult -Area "Network" -TestCase "Management network test" -ExpectedResult "All nodes are reachable." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Network: Cluster networks and heartbeat
try {
    $clusterNetworks = Get-ClusterNetwork -Cluster $ClusterName
    $clusterInterfaces = Get-ClusterNetworkInterface -Cluster $ClusterName

    $downInterfaces = $clusterInterfaces | Where-Object State -ne "Up"
    $status = if (($downInterfaces | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster network and heartbeat check" `
        -ExpectedResult "Cluster networks and heartbeat interfaces are stable." `
        -Status $status `
        -Remark "Networks=$($clusterNetworks.Name -join ', '); DownInterfaces=$($downInterfaces.Name -join ', ')" `
        -Data @{
            Networks = $clusterNetworks
            Interfaces = $clusterInterfaces
        }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Cluster network and heartbeat check" -ExpectedResult "Cluster networks can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Network: Live Migration configuration
try {
    $liveMigration = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        Get-VMHost | Select-Object ComputerName, VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationPerformanceOption
    }

    $disabled = $liveMigration | Where-Object { $_.VirtualMachineMigrationEnabled -ne $true }
    $status = if (($disabled | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Live Migration network configuration check" `
        -ExpectedResult "Live Migration is configured on all nodes." `
        -Status $status `
        -Remark "Live Migration disabled on: $($disabled.ComputerName -join ', ')" `
        -Data $liveMigration
}
catch {
    Add-TestResult -Area "Network" -TestCase "Live Migration network configuration check" -ExpectedResult "Live Migration configuration can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Network: SR-IOV on cluster nodes
try {
    $sriov = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        $switches = Get-VMSwitch | Select-Object Name, SwitchType, IovEnabled, IovSupport, IovSupportReasons
        $adapters = if (Get-Command Get-NetAdapterSriov -ErrorAction SilentlyContinue) {
            Get-NetAdapterSriov
        }
        else {
            $null
        }

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Switches = $switches
            SriovAdapters = $adapters
        }
    }

    Add-TestResult `
        -Area "Network" `
        -TestCase "SR-IOV cluster check" `
        -ExpectedResult "SR-IOV is available for cluster VMs where required." `
        -Status "ManualReview" `
        -Remark "SR-IOV information collected from cluster nodes." `
        -Data $sriov
}
catch {
    Add-TestResult -Area "Network" -TestCase "SR-IOV cluster check" -ExpectedResult "SR-IOV can be checked on all nodes." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# SAN Storage: SAN paths and MPIO
try {
    $sanData = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        $initiatorPorts = Get-InitiatorPort -ErrorAction SilentlyContinue
        $iscsiSessions = Get-IscsiSession -ErrorAction SilentlyContinue
        $disks = Get-Disk | Select-Object Number, FriendlyName, SerialNumber, BusType, OperationalStatus, HealthStatus, IsOffline, IsReadOnly

        $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
        $mpioSetting = if (Get-Command Get-MPIOSetting -ErrorAction SilentlyContinue) {
            Get-MPIOSetting
        }
        else {
            $null
        }

        $mpclaim = & mpclaim.exe -s -d 2>$null

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            InitiatorPorts = $initiatorPorts
            IscsiSessions = $iscsiSessions
            Disks = $disks
            MpioFeature = $mpioFeature
            MpioSetting = $mpioSetting
            Mpclaim = $mpclaim
        }
    }

    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "SAN paths and MPIO check" `
        -ExpectedResult "All SAN paths are available and redundant paths work." `
        -Status "ManualReview" `
        -Remark "SAN and MPIO data collected from all nodes." `
        -Data $sanData
}
catch {
    Add-TestResult -Area "SAN Storage" -TestCase "SAN paths and MPIO check" -ExpectedResult "SAN and MPIO state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# SAN Storage: CSV
try {
    $csv = Get-ClusterSharedVolume -Cluster $ClusterName
    $offlineCsv = $csv | Where-Object State -ne "Online"

    $status = if (($csv | Measure-Object).Count -gt 0 -and ($offlineCsv | Measure-Object).Count -eq 0) {
        "Successful"
    }
    else {
        "NotSuccessful"
    }

    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "CSV check" `
        -ExpectedResult "Cluster Shared Volumes are online and available." `
        -Status $status `
        -Remark "CSV count=$(( $csv | Measure-Object ).Count); Offline=$($offlineCsv.Name -join ', ')" `
        -Data $csv
}
catch {
    Add-TestResult -Area "SAN Storage" -TestCase "CSV check" -ExpectedResult "CSV state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# VM Operation / HA: Cluster VM roles
try {
    $groups = Get-ClusterGroup -Cluster $ClusterName
    $vmGroups = $groups | Where-Object GroupType -eq "VirtualMachine"

    $failedVmGroups = $vmGroups | Where-Object State -ne "Online"
    $status = if (($failedVmGroups | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "HA" `
        -TestCase "Cluster VM role check" `
        -ExpectedResult "Cluster VMs are online and highly available." `
        -Status $status `
        -Remark "Cluster VM roles=$(( $vmGroups | Measure-Object ).Count); Offline=$($failedVmGroups.Name -join ', ')" `
        -Data $vmGroups
}
catch {
    Add-TestResult -Area "HA" -TestCase "Cluster VM role check" -ExpectedResult "Cluster VM roles can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Updates: Host updates
try {
    $updates = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30
    }

    Add-TestResult `
        -Area "Updates" `
        -TestCase "Cluster node updates check" `
        -ExpectedResult "All cluster nodes have current patch state documented." `
        -Status "ManualReview" `
        -Remark "Patch data collected from nodes: $($nodeNames -join ', ')" `
        -Data $updates
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Cluster node updates check" -ExpectedResult "Installed updates can be queried on all nodes." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Updates: Cluster-Aware Updating state
try {
    if (Test-CommandExists -Name "Get-CauClusterRole") {
        $cauRole = Get-CauClusterRole -ClusterName $ClusterName -ErrorAction SilentlyContinue

        Add-TestResult `
            -Area "Updates" `
            -TestCase "Cluster-Aware Updating check" `
            -ExpectedResult "CAU role and update method are documented." `
            -Status "ManualReview" `
            -Remark "CAU role collected. Review configuration." `
            -Data $cauRole
    }
    else {
        Add-TestResult `
            -Area "Updates" `
            -TestCase "Cluster-Aware Updating check" `
            -ExpectedResult "CAU can be checked." `
            -Status "Skipped" `
            -Remark "CAU cmdlets are not available on this system."
    }
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Cluster-Aware Updating check" -ExpectedResult "CAU state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Security: SMB and NTLM on nodes
try {
    $securityData = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        $ntlmPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
        $lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            SmbServer = Get-SmbServerConfiguration
            SmbClient = Get-SmbClientConfiguration
            NTLM = if (Test-Path $ntlmPath) { Get-ItemProperty -Path $ntlmPath } else { $null }
            LSA = Get-ItemProperty -Path $lsaPath
        }
    }

    Add-TestResult `
        -Area "Security" `
        -TestCase "SMB and NTLM configuration check" `
        -ExpectedResult "SMB and NTLM state are documented on all cluster nodes." `
        -Status "ManualReview" `
        -Remark "Security configuration collected from nodes." `
        -Data $securityData
}
catch {
    Add-TestResult -Area "Security" -TestCase "SMB and NTLM configuration check" -ExpectedResult "SMB and NTLM settings can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Monitoring: Cluster logs and recent errors
try {
    $eventData = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        $events = Get-WinEvent -FilterHashtable @{
            LogName = "System"
            Level = @(1, 2, 3)
            StartTime = (Get-Date).AddHours(-24)
        } -ErrorAction SilentlyContinue

        $clusterEvents = Get-WinEvent -FilterHashtable @{
            LogName = "Microsoft-Windows-FailoverClustering/Operational"
            Level = @(1, 2, 3)
            StartTime = (Get-Date).AddHours(-24)
        } -ErrorAction SilentlyContinue

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            SystemEvents = $events | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message
            ClusterEvents = $clusterEvents | Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message
        }
    }

    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Cluster event logs check" `
        -ExpectedResult "No critical cluster or system errors are present." `
        -Status "ManualReview" `
        -Remark "Recent System and FailoverClustering events collected." `
        -Data $eventData
}
catch {
    Add-TestResult -Area "Monitoring" -TestCase "Cluster event logs check" -ExpectedResult "Cluster logs can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Disaster Recovery: Quorum
try {
    $quorum = Get-ClusterQuorum -Cluster $ClusterName
    Add-TestResult `
        -Area "Disaster Recovery" `
        -TestCase "Cluster quorum check" `
        -ExpectedResult "Quorum is correctly configured." `
        -Status "ManualReview" `
        -Remark "QuorumResource=$($quorum.QuorumResource); QuorumType=$($quorum.QuorumType)" `
        -Data $quorum
}
catch {
    Add-TestResult -Area "Disaster Recovery" -TestCase "Cluster quorum check" -ExpectedResult "Quorum can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Special Server 2025: Cluster functional level
try {
    $cluster = Get-Cluster -Name $ClusterName
    $clusterVersionInfo = $cluster | Select-Object Name, ClusterFunctionalLevel, ClusterUpgradeVersion

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Cluster functional level check" `
        -ExpectedResult "Cluster functional level is documented and appropriate for Server 2025." `
        -Status "ManualReview" `
        -Remark "ClusterFunctionalLevel=$($cluster.ClusterFunctionalLevel); ClusterUpgradeVersion=$($cluster.ClusterUpgradeVersion)" `
        -Data $clusterVersionInfo
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Cluster functional level check" -ExpectedResult "Cluster functional level can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Special Server 2025: Hyper-V Integration Services
try {
    $integration = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        Get-VM | ForEach-Object {
            Get-VMIntegrationService -VMName $_.Name |
                Select-Object VMName, Name, Enabled, PrimaryStatusDescription, SecondaryStatusDescription
        }
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Hyper-V integration services check" `
        -ExpectedResult "Hyper-V integration services are current and healthy." `
        -Status "ManualReview" `
        -Remark "Integration services collected for VMs on all nodes." `
        -Data $integration
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Hyper-V integration services check" -ExpectedResult "Integration services can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Special Server 2025: VBS / Credential Guard / HVCI on nodes
try {
    $vbsData = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        $deviceGuard = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
        $cg = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -ErrorAction SilentlyContinue
        $hvci = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" -ErrorAction SilentlyContinue

        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            DeviceGuard = $deviceGuard
            CredentialGuard = $cg
            HVCI = $hvci
        }
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "VBS Credential Guard HVCI cluster check" `
        -ExpectedResult "VBS, Credential Guard and HVCI state are documented on all nodes." `
        -Status "ManualReview" `
        -Remark "Security feature state collected from all nodes." `
        -Data $vbsData
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "VBS Credential Guard HVCI cluster check" -ExpectedResult "Security feature state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Windows Admin Center reachability
try {
    if ([string]::IsNullOrWhiteSpace($WindowsAdminCenterUrl)) {
        Add-TestResult `
            -Area "Special Server 2025" `
            -TestCase "Windows Admin Center connectivity check" `
            -ExpectedResult "Windows Admin Center is reachable." `
            -Status "Skipped" `
            -Remark "No WAC host or URL was provided."
    }
    else {
        $wacHost = ($WindowsAdminCenterUrl -replace "^https?://", "" -split "/")[0] -split ":" | Select-Object -First 1
        $check = Test-TcpPort -ComputerName $wacHost -Port 443
        $status = if ($check.TcpSucceeded) { "Successful" } else { "NotSuccessful" }

        Add-TestResult `
            -Area "Special Server 2025" `
            -TestCase "Windows Admin Center connectivity check" `
            -ExpectedResult "Windows Admin Center is reachable via HTTPS." `
            -Status $status `
            -Remark "WAC host=$wacHost; HTTPS=$($check.TcpSucceeded)" `
            -Data $check
    }
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Windows Admin Center connectivity check" -ExpectedResult "WAC reachability can be tested." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Firmware and driver inventory
try {
    $drivers = Invoke-Command -ComputerName $nodeNames -ScriptBlock {
        Get-CimInstance Win32_PnPSignedDriver |
            Where-Object {
                $_.DeviceClass -in @("NET", "SCSIADAPTER", "HDC", "SYSTEM", "STORAGECONTROLLER")
            } |
            Select-Object PSComputerName, DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Firmware and driver inventory" `
        -ExpectedResult "NIC, HBA, RAID and storage related driver states are documented." `
        -Status "ManualReview" `
        -Remark "Driver entries collected from all nodes." `
        -Data $drivers
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Firmware and driver inventory" -ExpectedResult "Driver information can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun