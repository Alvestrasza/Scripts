#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Local-only assessment for a Windows Server 2025 Hyper-V Failover Cluster node with SAN storage.

.DESCRIPTION
Runs locally on a cluster node. Checks cluster-wide state through the local Failover Clustering API
and checks node-local Hyper-V, SAN, MPIO, SMB, NTLM, VBS, updates, event logs and driver information.
This script does not use Invoke-Command, New-PSSession or Enter-PSSession.
Run it once on every cluster node to collect node-local evidence.

.NOTES
File Name     : 03-HVClusterSAN-Assessment-Local.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025",
    [string]$ClusterName = "",
    [string]$ClusterFqdn = "",
    [string[]]$ExpectedNodes = @(),
    [switch]$RunClusterValidation,
    [string]$WindowsAdminCenterHost = "",
    [int]$WindowsAdminCenterPort = 443
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVClusterSAN-Assessment-Local-$env:COMPUTERNAME"

try {
    Import-Module FailoverClusters -ErrorAction Stop
}
catch {
    Add-TestResult -Area "Cluster" -TestCase "FailoverClusters module import" -ExpectedResult "FailoverClusters module is available." -Status "NotSuccessful" -Remark $_.Exception.Message
    Complete-TestRun
    exit 1
}

try {
    if (-not [string]::IsNullOrWhiteSpace($ClusterFqdn)) {
        $ClusterAccessName = $ClusterFqdn
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $ClusterAccessName = $ClusterName
    }
    else {
        $ClusterAccessName = (Get-Cluster -ErrorAction Stop).Name
    }

    if ($ClusterAccessName -in @("True", "False")) {
        throw "Invalid cluster name '$ClusterAccessName'. ClusterName and ClusterFqdn must be string parameters."
    }

    Write-Host "Cluster access name used by script: $ClusterAccessName" -ForegroundColor Cyan
}
catch {
    Add-TestResult -Area "Cluster" -TestCase "Resolve cluster access name" -ExpectedResult "Cluster access name can be resolved." -Status "NotSuccessful" -Remark $_.Exception.Message
    Complete-TestRun
    exit 1
}

try {
    if ($RunClusterValidation) {
        $reportPath = Join-Path $script:CurrentOutputRoot "ClusterValidation"
        New-Item -Path $reportPath -ItemType Directory -Force | Out-Null

        $validation = Test-Cluster `
            -Cluster $ClusterAccessName `
            -ReportName (Join-Path $reportPath "validation-report") `
            -Verbose `
            -ErrorAction Stop

        Add-TestResult `
            -Area "Cluster" `
            -TestCase "Run cluster validation" `
            -ExpectedResult "Validation report has no critical errors." `
            -Status "ManualReview" `
            -Remark "Cluster validation executed locally. Review generated validation report." `
            -Data $validation
    }
    else {
        Add-TestResult -Area "Cluster" -TestCase "Run cluster validation" -ExpectedResult "Validation report has no critical errors." -Status "Skipped" -Remark "RunClusterValidation was not specified."
    }
}
catch {
    Add-TestResult -Area "Cluster" -TestCase "Run cluster validation" -ExpectedResult "Validation report can be generated." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $nodes = Get-ClusterNode -Cluster $ClusterAccessName -ErrorAction Stop
    $missingNodes = foreach ($expected in $ExpectedNodes) {
        if ($expected -notin $nodes.Name) { $expected }
    }
    $downNodes = $nodes | Where-Object State -ne "Up"
    $status = if (($downNodes | Measure-Object).Count -eq 0 -and ($missingNodes | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

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

try {
    $clusterNetworks = Get-ClusterNetwork -Cluster $ClusterAccessName -ErrorAction Stop
    $clusterInterfaces = Get-ClusterNetworkInterface -Cluster $ClusterAccessName -ErrorAction Stop
    $downInterfaces = $clusterInterfaces | Where-Object State -ne "Up"
    $status = if (($downInterfaces | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster network and heartbeat check" `
        -ExpectedResult "Cluster networks and heartbeat interfaces are stable." `
        -Status $status `
        -Remark "Networks=$($clusterNetworks.Name -join ', '); DownInterfaces=$($downInterfaces.Name -join ', ')" `
        -Data @{ Networks = $clusterNetworks; Interfaces = $clusterInterfaces }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Cluster network and heartbeat check" -ExpectedResult "Cluster networks can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $nodePingChecks = foreach ($node in ($nodes | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue)) {
        Test-PingSafe -ComputerName $node
    }
    $failed = $nodePingChecks | Where-Object { -not $_.PingSucceeded }
    $status = if (($failed | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster node ICMP reachability check" `
        -ExpectedResult "Cluster nodes are reachable by ICMP where allowed." `
        -Status $status `
        -Remark "ICMP check does not use PowerShell remoting." `
        -Data $nodePingChecks
}
catch {
    Add-TestResult -Area "Network" -TestCase "Cluster node ICMP reachability check" -ExpectedResult "Cluster node reachability can be checked." -Status "ManualReview" -Remark $_.Exception.Message
}

try {
    $vmHost = Get-VMHost -ErrorAction Stop |
        Select-Object ComputerName, VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType, VirtualMachineMigrationPerformanceOption, MacAddressMinimum, MacAddressMaximum
    Add-TestResult `
        -Area "Network" `
        -TestCase "Local Live Migration configuration check" `
        -ExpectedResult "Live Migration is configured on the local node." `
        -Status "ManualReview" `
        -Remark "Local node=$env:COMPUTERNAME; LiveMigrationEnabled=$($vmHost.VirtualMachineMigrationEnabled)" `
        -Data $vmHost
}
catch {
    Add-TestResult -Area "Network" -TestCase "Local Live Migration configuration check" -ExpectedResult "Live Migration configuration can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $switches = Get-VMSwitch -ErrorAction Stop | Select-Object Name, SwitchType, IovEnabled, IovSupport, IovSupportReasons, NetAdapterInterfaceDescription
    $sriovAdapters = if (Test-CommandExists -Name "Get-NetAdapterSriov") { Get-NetAdapterSriov -ErrorAction SilentlyContinue } else { $null }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Local SR-IOV check" `
        -ExpectedResult "SR-IOV state is documented on the local node." `
        -Status "ManualReview" `
        -Remark "Local vSwitches collected: $($switches.Name -join ', ')" `
        -Data @{ Switches = $switches; SriovAdapters = $sriovAdapters }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Local SR-IOV check" -ExpectedResult "SR-IOV can be checked on the local node." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $initiatorPorts = Get-InitiatorPort -ErrorAction SilentlyContinue
    $iscsiSessions = Get-IscsiSession -ErrorAction SilentlyContinue
    $disks = Get-Disk | Select-Object Number, FriendlyName, SerialNumber, BusType, OperationalStatus, HealthStatus, IsOffline, IsReadOnly
    $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue
    $mpioSetting = if (Test-CommandExists -Name "Get-MPIOSetting") { Get-MPIOSetting -ErrorAction SilentlyContinue } else { $null }
    $mpclaim = if (Test-Path "$env:SystemRoot\System32\mpclaim.exe") { & mpclaim.exe -s -d 2>$null } else { $null }

    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "Local SAN paths and MPIO check" `
        -ExpectedResult "SAN paths are available and redundant paths are documented on the local node." `
        -Status "ManualReview" `
        -Remark "Local SAN and MPIO data collected on $env:COMPUTERNAME." `
        -Data @{ InitiatorPorts = $initiatorPorts; IscsiSessions = $iscsiSessions; Disks = $disks; MpioFeature = $mpioFeature; MpioSetting = $mpioSetting; Mpclaim = $mpclaim }
}
catch {
    Add-TestResult -Area "SAN Storage" -TestCase "Local SAN paths and MPIO check" -ExpectedResult "SAN and MPIO state can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $csv = Get-ClusterSharedVolume -Cluster $ClusterAccessName -ErrorAction Stop
    $offlineCsv = $csv | Where-Object State -ne "Online"
    $status = if (($csv | Measure-Object).Count -gt 0 -and ($offlineCsv | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

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

try {
    $groups = Get-ClusterGroup -Cluster $ClusterAccessName -ErrorAction Stop
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

try {
    $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30
    $latest = $hotfixes | Select-Object -First 1
    Add-TestResult `
        -Area "Updates" `
        -TestCase "Local node updates check" `
        -ExpectedResult "Local node patch state is documented." `
        -Status "ManualReview" `
        -Remark "Latest installed update: $($latest.HotFixID) / $($latest.InstalledOn)" `
        -Data $hotfixes
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Local node updates check" -ExpectedResult "Installed updates can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if (Test-CommandExists -Name "Get-CauClusterRole") {
        $cauRole = Get-CauClusterRole -ClusterName $ClusterAccessName -ErrorAction SilentlyContinue
        Add-TestResult `
            -Area "Updates" `
            -TestCase "Cluster-Aware Updating check" `
            -ExpectedResult "CAU role and update method are documented." `
            -Status "ManualReview" `
            -Remark "CAU role collected locally. Review configuration." `
            -Data $cauRole
    }
    else {
        Add-TestResult -Area "Updates" -TestCase "Cluster-Aware Updating check" -ExpectedResult "CAU can be checked." -Status "Skipped" -Remark "CAU cmdlets are not available on this system."
    }
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Cluster-Aware Updating check" -ExpectedResult "CAU state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $smbServer = Get-SmbServerConfiguration -ErrorAction Stop
    $smbClient = Get-SmbClientConfiguration -ErrorAction Stop
    $ntlm = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
    $lsa = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

    Add-TestResult `
        -Area "Security" `
        -TestCase "Local SMB and NTLM configuration check" `
        -ExpectedResult "SMB and NTLM state are documented on the local node." `
        -Status "ManualReview" `
        -Remark "SMB1=$($smbServer.EnableSMB1Protocol); SMB2/3=$($smbServer.EnableSMB2Protocol); RestrictReceivingNTLMTraffic=$($ntlm.RestrictReceivingNTLMTraffic)" `
        -Data @{ SmbServer = $smbServer; SmbClient = $smbClient; NTLM = $ntlm; LSA = $lsa }
}
catch {
    Add-TestResult -Area "Security" -TestCase "Local SMB and NTLM configuration check" -ExpectedResult "SMB and NTLM settings can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $systemEvents = Get-RecentEventSummary -Hours 24 -LogNames @("System") -Levels @(1, 2, 3)
    $clusterEvents = Get-RecentEventSummary -Hours 24 -LogNames @("Microsoft-Windows-FailoverClustering/Operational") -Levels @(1, 2, 3)

    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Local cluster event logs check" `
        -ExpectedResult "No critical cluster or system errors are present on the local node." `
        -Status "ManualReview" `
        -Remark "Recent System and FailoverClustering events collected locally." `
        -Data @{ SystemEvents = $systemEvents; ClusterEvents = $clusterEvents }
}
catch {
    Add-TestResult -Area "Monitoring" -TestCase "Local cluster event logs check" -ExpectedResult "Cluster logs can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $quorum = Get-ClusterQuorum -Cluster $ClusterAccessName -ErrorAction Stop
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

try {
    $cluster = Get-Cluster -Name $ClusterAccessName -ErrorAction Stop
    $clusterProperties = $cluster | Get-Member -MemberType Properties | Select-Object -ExpandProperty Name
    $functionalLevel = if ($clusterProperties -contains "ClusterFunctionalLevel") { $cluster.ClusterFunctionalLevel } else { "PropertyNotAvailable" }
    $upgradeVersion = if ($clusterProperties -contains "ClusterUpgradeVersion") { $cluster.ClusterUpgradeVersion } else { "PropertyNotAvailable" }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Cluster functional level check" `
        -ExpectedResult "Cluster functional level is documented and appropriate for Server 2025." `
        -Status "ManualReview" `
        -Remark "ClusterFunctionalLevel=$functionalLevel; ClusterUpgradeVersion=$upgradeVersion" `
        -Data $cluster
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Cluster functional level check" -ExpectedResult "Cluster functional level can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $integration = Get-VM -ErrorAction Stop | ForEach-Object {
        Get-VMIntegrationService -VMName $_.Name -ErrorAction SilentlyContinue |
            Select-Object VMName, Name, Enabled, PrimaryStatusDescription, SecondaryStatusDescription
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local Hyper-V integration services check" `
        -ExpectedResult "Hyper-V integration services are current and healthy for VMs visible on this node." `
        -Status "ManualReview" `
        -Remark "Integration services collected locally for VMs visible on $env:COMPUTERNAME." `
        -Data $integration
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Local Hyper-V integration services check" -ExpectedResult "Integration services can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $deviceGuardStatus = $null
    $deviceGuardRemark = "DeviceGuard CIM query completed."

    try {
        $deviceGuardRaw = Get-CimInstance `
            -Namespace "root\Microsoft\Windows\DeviceGuard" `
            -ClassName Win32_DeviceGuard `
            -OperationTimeoutSec 15 `
            -ErrorAction Stop

        $deviceGuardStatus = $deviceGuardRaw | Select-Object `
            PSComputerName,
            SecurityServicesConfigured,
            SecurityServicesRunning,
            RequiredSecurityProperties,
            AvailableSecurityProperties,
            VirtualizationBasedSecurityStatus,
            CodeIntegrityPolicyEnforcementStatus,
            UsermodeCodeIntegrityPolicyEnforcementStatus,
            Version
    }
    catch {
        $deviceGuardRemark = "DeviceGuard CIM query failed or timed out. Registry values were collected as fallback."

        $deviceGuardStatus = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            QueryStatus  = "FailedOrTimedOut"
            Error        = $_.Exception.Message
        }
    }

    $cg = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $deviceGuardRegistry = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
    $hvci = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"

    $securitySummary = [pscustomobject]@{
        ComputerName                         = $env:COMPUTERNAME
        DeviceGuardCimStatus                 = $deviceGuardStatus
        CredentialGuard_LsaCfgFlags          = $cg.LsaCfgFlags
        DeviceGuard_EnableVBS                = $deviceGuardRegistry.EnableVirtualizationBasedSecurity
        DeviceGuard_RequirePlatformSecurity  = $deviceGuardRegistry.RequirePlatformSecurityFeatures
        HVCI_Enabled                         = $hvci.Enabled
        HVCI_WasEnabledBy                    = $hvci.WasEnabledBy
        HVCI_EnabledBootId                   = $hvci.EnabledBootId
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local VBS Credential Guard HVCI check" `
        -ExpectedResult "VBS, Credential Guard and HVCI state are documented on the local node." `
        -Status "ManualReview" `
        -Remark "$deviceGuardRemark LsaCfgFlags=$($cg.LsaCfgFlags); HVCI Enabled=$($hvci.Enabled)" `
        -Data $securitySummary
}
catch {
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local VBS Credential Guard HVCI check" `
        -ExpectedResult "Security feature state can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    if ([string]::IsNullOrWhiteSpace($WindowsAdminCenterHost)) {
        Add-TestResult -Area "Special Server 2025" -TestCase "Windows Admin Center connectivity check" -ExpectedResult "Windows Admin Center is reachable." -Status "Skipped" -Remark "No WAC host was provided."
    }
    else {
        $check = Test-TcpPort -ComputerName $WindowsAdminCenterHost -Port $WindowsAdminCenterPort
        $status = if ($check.TcpSucceeded) { "Successful" } else { "NotSuccessful" }
        Add-TestResult `
            -Area "Special Server 2025" `
            -TestCase "Windows Admin Center connectivity check" `
            -ExpectedResult "Windows Admin Center is reachable via HTTPS." `
            -Status $status `
            -Remark "WAC host=$WindowsAdminCenterHost; Port=$WindowsAdminCenterPort; HTTPS=$($check.TcpSucceeded)" `
            -Data $check
    }
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Windows Admin Center connectivity check" -ExpectedResult "WAC reachability can be tested." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $drivers = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object { $_.DeviceClass -in @("NET", "SCSIADAPTER", "HDC", "SYSTEM", "STORAGECONTROLLER") } |
        Select-Object PSComputerName, DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local firmware and driver inventory" `
        -ExpectedResult "NIC, HBA, RAID and storage related driver states are documented on the local node." `
        -Status "ManualReview" `
        -Remark "Driver entries collected locally: $(( $drivers | Measure-Object ).Count)" `
        -Data $drivers
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Local firmware and driver inventory" -ExpectedResult "Driver information can be queried locally." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun
