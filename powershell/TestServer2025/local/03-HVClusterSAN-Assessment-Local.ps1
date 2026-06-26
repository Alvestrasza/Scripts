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

This corrected version avoids StrictMode false positives when optional values are missing or when result
sets are empty. It also reduces raw CIM/cluster objects before JSON export and uses a timeout for the
DeviceGuard CIM query.

.NOTES
File Name     : 03-HVClusterSAN-Assessment-Local.ps1
Version       : v0.1.1
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
    [switch]$SkipClusterValidation,
    [string]$WindowsAdminCenterHost = "",
    [int]$WindowsAdminCenterPort = 443,
    [int]$DeviceGuardTimeoutSec = 15,
    [int]$EventLogHours = 24
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

function ConvertTo-TextList {
    param(
        [object]$InputObject,
        [string]$PropertyName = ""
    )

    $values = @()

    foreach ($item in @($InputObject)) {
        if ($null -eq $item) {
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($PropertyName)) {
            $property = $item.PSObject.Properties[$PropertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                $values += [string]$property.Value
            }
        }
        else {
            $values += [string]$item
        }
    }

    return (@($values) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) -join ", "
}

function Get-ObjectPropertyValueSafe {
    param(
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$PropertyName,
        [object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }

    $property = $InputObject.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
        return $DefaultValue
    }

    if ($null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function ConvertTo-SafeClusterNodeObject {
    param([object]$Node)

    [pscustomobject]@{
        Name       = Get-ObjectPropertyValueSafe -InputObject $Node -PropertyName "Name" -DefaultValue "Unknown"
        State      = Get-ObjectPropertyValueSafe -InputObject $Node -PropertyName "State" -DefaultValue "Unknown"
        NodeWeight = Get-ObjectPropertyValueSafe -InputObject $Node -PropertyName "NodeWeight" -DefaultValue "NotAvailable"
        DynamicWeight = Get-ObjectPropertyValueSafe -InputObject $Node -PropertyName "DynamicWeight" -DefaultValue "NotAvailable"
    }
}

function ConvertTo-SafeClusterNetworkObject {
    param([object]$Network)

    [pscustomobject]@{
        Name        = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "Name" -DefaultValue "Unknown"
        Address     = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "Address" -DefaultValue "NotAvailable"
        AddressMask = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "AddressMask" -DefaultValue "NotAvailable"
        Role        = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "Role" -DefaultValue "NotAvailable"
        State       = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "State" -DefaultValue "Unknown"
        Metric      = Get-ObjectPropertyValueSafe -InputObject $Network -PropertyName "Metric" -DefaultValue "NotAvailable"
    }
}

function ConvertTo-SafeClusterInterfaceObject {
    param([object]$Interface)

    [pscustomobject]@{
        Name        = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "Name" -DefaultValue "Unknown"
        Node        = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "Node" -DefaultValue "NotAvailable"
        Network     = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "Network" -DefaultValue "NotAvailable"
        Adapter     = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "Adapter" -DefaultValue "NotAvailable"
        Address     = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "Address" -DefaultValue "NotAvailable"
        State       = Get-ObjectPropertyValueSafe -InputObject $Interface -PropertyName "State" -DefaultValue "Unknown"
    }
}

function ConvertTo-SafeClusterGroupObject {
    param([object]$Group)

    [pscustomobject]@{
        Name      = Get-ObjectPropertyValueSafe -InputObject $Group -PropertyName "Name" -DefaultValue "Unknown"
        GroupType = Get-ObjectPropertyValueSafe -InputObject $Group -PropertyName "GroupType" -DefaultValue "Unknown"
        State     = Get-ObjectPropertyValueSafe -InputObject $Group -PropertyName "State" -DefaultValue "Unknown"
        OwnerNode = Get-ObjectPropertyValueSafe -InputObject $Group -PropertyName "OwnerNode" -DefaultValue "NotAvailable"
    }
}

function ConvertTo-SafeCsvObject {
    param([object]$Csv)

    [pscustomobject]@{
        Name      = Get-ObjectPropertyValueSafe -InputObject $Csv -PropertyName "Name" -DefaultValue "Unknown"
        State     = Get-ObjectPropertyValueSafe -InputObject $Csv -PropertyName "State" -DefaultValue "Unknown"
        OwnerNode = Get-ObjectPropertyValueSafe -InputObject $Csv -PropertyName "OwnerNode" -DefaultValue "NotAvailable"
    }
}

function Get-DeviceGuardSummarySafe {
    param([int]$TimeoutSec = 15)

    try {
        $deviceGuardRaw = Get-CimInstance `
            -Namespace "root\Microsoft\Windows\DeviceGuard" `
            -ClassName Win32_DeviceGuard `
            -OperationTimeoutSec $TimeoutSec `
            -ErrorAction Stop

        return [pscustomobject]@{
            QueryStatus                                      = "Completed"
            PSComputerName                                   = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "PSComputerName" -DefaultValue $env:COMPUTERNAME
            SecurityServicesConfigured                       = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "SecurityServicesConfigured" -DefaultValue @()
            SecurityServicesRunning                          = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "SecurityServicesRunning" -DefaultValue @()
            RequiredSecurityProperties                       = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "RequiredSecurityProperties" -DefaultValue @()
            AvailableSecurityProperties                      = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "AvailableSecurityProperties" -DefaultValue @()
            VirtualizationBasedSecurityStatus                = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "VirtualizationBasedSecurityStatus" -DefaultValue "NotAvailable"
            CodeIntegrityPolicyEnforcementStatus             = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "CodeIntegrityPolicyEnforcementStatus" -DefaultValue "NotAvailable"
            UsermodeCodeIntegrityPolicyEnforcementStatus     = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "UsermodeCodeIntegrityPolicyEnforcementStatus" -DefaultValue "NotAvailable"
            Version                                          = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRaw -PropertyName "Version" -DefaultValue "NotAvailable"
        }
    }
    catch {
        return [pscustomobject]@{
            QueryStatus = "FailedOrTimedOut"
            ComputerName = $env:COMPUTERNAME
            TimeoutSec = $TimeoutSec
            Error = $_.Exception.Message
        }
    }
}

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVClusterSAN-Assessment-Local-$env:COMPUTERNAME"

try {
    Import-Module FailoverClusters -ErrorAction Stop
}
catch {
    Add-TestResult `
        -Area "Cluster" `
        -TestCase "FailoverClusters module import" `
        -ExpectedResult "FailoverClusters module is available." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message

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

    if ([string]$ClusterAccessName -in @("True", "False")) {
        throw "Invalid cluster name '$ClusterAccessName'. ClusterName and ClusterFqdn must be string parameters."
    }

    Write-Host "Cluster access name used by script: $ClusterAccessName" -ForegroundColor Cyan
}
catch {
    Add-TestResult `
        -Area "Cluster" `
        -TestCase "Resolve cluster access name" `
        -ExpectedResult "Cluster access name can be resolved." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message

    Complete-TestRun
    exit 1
}

$nodes = @()

try {
    if ($RunClusterValidation -and -not $SkipClusterValidation) {
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
            -Data ($validation | Out-String -Width 4096)
    }
    else {
        $validationRemark = if ($SkipClusterValidation) { "SkipClusterValidation was specified." } else { "RunClusterValidation was not specified." }
        Add-TestResult `
            -Area "Cluster" `
            -TestCase "Run cluster validation" `
            -ExpectedResult "Validation report has no critical errors." `
            -Status "Skipped" `
            -Remark $validationRemark
    }
}
catch {
    Add-TestResult `
        -Area "Cluster" `
        -TestCase "Run cluster validation" `
        -ExpectedResult "Validation report can be generated." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $nodes = @(Get-ClusterNode -Cluster $ClusterAccessName -ErrorAction Stop)
    $nodeData = @($nodes | ForEach-Object { ConvertTo-SafeClusterNodeObject -Node $_ })

    $actualNodeNames = @($nodes | ForEach-Object { [string]$_.Name })
    $missingNodes = @()

    foreach ($expected in @($ExpectedNodes)) {
        if (-not [string]::IsNullOrWhiteSpace($expected) -and $expected -notin $actualNodeNames) {
            $missingNodes += $expected
        }
    }

    $downNodes = @($nodeData | Where-Object { [string]$_.State -ne "Up" })
    $status = if ($downNodes.Count -eq 0 -and $missingNodes.Count -eq 0) { "Successful" } else { "NotSuccessful" }

    $nodesText = ConvertTo-TextList -InputObject $nodeData -PropertyName "Name"
    $downNodesText = ConvertTo-TextList -InputObject $downNodes -PropertyName "Name"
    $missingNodesText = ConvertTo-TextList -InputObject $missingNodes

    Add-TestResult `
        -Area "Cluster" `
        -TestCase "Cluster service check" `
        -ExpectedResult "All cluster nodes are online." `
        -Status $status `
        -Remark "Nodes=$nodesText; Down=$downNodesText; Missing=$missingNodesText" `
        -Data $nodeData
}
catch {
    Add-TestResult `
        -Area "Cluster" `
        -TestCase "Cluster service check" `
        -ExpectedResult "Cluster nodes can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $clusterNetworks = @(Get-ClusterNetwork -Cluster $ClusterAccessName -ErrorAction Stop)
    $clusterInterfaces = @(Get-ClusterNetworkInterface -Cluster $ClusterAccessName -ErrorAction Stop)

    $networkData = @($clusterNetworks | ForEach-Object { ConvertTo-SafeClusterNetworkObject -Network $_ })
    $interfaceData = @($clusterInterfaces | ForEach-Object { ConvertTo-SafeClusterInterfaceObject -Interface $_ })
    $downInterfaces = @($interfaceData | Where-Object { [string]$_.State -ne "Up" })

    $status = if ($downInterfaces.Count -eq 0) { "Successful" } else { "NotSuccessful" }

    $networksText = ConvertTo-TextList -InputObject $networkData -PropertyName "Name"
    $downInterfacesText = ConvertTo-TextList -InputObject $downInterfaces -PropertyName "Name"

    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster network and heartbeat check" `
        -ExpectedResult "Cluster networks and heartbeat interfaces are stable." `
        -Status $status `
        -Remark "Networks=$networksText; DownInterfaces=$downInterfacesText" `
        -Data @{ Networks = $networkData; Interfaces = $interfaceData }
}
catch {
    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster network and heartbeat check" `
        -ExpectedResult "Cluster networks can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $nodeNamesForPing = @($nodes | ForEach-Object { [string]$_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($nodeNamesForPing.Count -eq 0) {
        Add-TestResult `
            -Area "Network" `
            -TestCase "Cluster node ICMP reachability check" `
            -ExpectedResult "Cluster nodes are reachable by ICMP where allowed." `
            -Status "ManualReview" `
            -Remark "Cluster nodes were not available from the previous query; ICMP check skipped."
    }
    else {
        $nodePingChecks = @($nodeNamesForPing | ForEach-Object { Test-PingSafe -ComputerName $_ })
        $failed = @($nodePingChecks | Where-Object { -not $_.PingSucceeded })
        $status = if ($failed.Count -eq 0) { "Successful" } else { "ManualReview" }

        Add-TestResult `
            -Area "Network" `
            -TestCase "Cluster node ICMP reachability check" `
            -ExpectedResult "Cluster nodes are reachable by ICMP where allowed." `
            -Status $status `
            -Remark "ICMP check does not use PowerShell remoting. Failed=$(ConvertTo-TextList -InputObject $failed -PropertyName 'ComputerName')" `
            -Data $nodePingChecks
    }
}
catch {
    Add-TestResult `
        -Area "Network" `
        -TestCase "Cluster node ICMP reachability check" `
        -ExpectedResult "Cluster node reachability can be checked." `
        -Status "ManualReview" `
        -Remark $_.Exception.Message
}

try {
    $vmHost = Get-VMHost -ErrorAction Stop |
        Select-Object `
            @{Name = "ComputerName"; Expression = { $env:COMPUTERNAME }},
            VirtualMachineMigrationEnabled,
            VirtualMachineMigrationAuthenticationType,
            VirtualMachineMigrationPerformanceOption,
            MaximumVirtualMachineMigrations,
            MacAddressMinimum,
            MacAddressMaximum

    $liveMigrationEnabled = Get-ObjectPropertyValueSafe -InputObject $vmHost -PropertyName "VirtualMachineMigrationEnabled" -DefaultValue "Unknown"

    Add-TestResult `
        -Area "Network" `
        -TestCase "Local Live Migration configuration check" `
        -ExpectedResult "Live Migration is configured on the local node." `
        -Status "ManualReview" `
        -Remark "Local node=$env:COMPUTERNAME; LiveMigrationEnabled=$liveMigrationEnabled" `
        -Data $vmHost
}
catch {
    Add-TestResult `
        -Area "Network" `
        -TestCase "Local Live Migration configuration check" `
        -ExpectedResult "Live Migration configuration can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $switches = @(Get-VMSwitch -ErrorAction Stop |
        Select-Object Name, SwitchType, IovEnabled, IovSupport, IovSupportReasons, NetAdapterInterfaceDescription)

    $sriovAdapters = @()
    if (Test-CommandExists -Name "Get-NetAdapterSriov") {
        $sriovAdapters = @(Get-NetAdapterSriov -ErrorAction SilentlyContinue |
            Select-Object Name, InterfaceDescription, Enabled, SriovSupport, NumVFs, NumVFsInUse, IovQueuePairCount)
    }

    $switchNamesText = ConvertTo-TextList -InputObject $switches -PropertyName "Name"

    Add-TestResult `
        -Area "Network" `
        -TestCase "Local SR-IOV check" `
        -ExpectedResult "SR-IOV state is documented on the local node." `
        -Status "ManualReview" `
        -Remark "Local vSwitches collected: $switchNamesText" `
        -Data @{ Switches = $switches; SriovAdapters = $sriovAdapters }
}
catch {
    Add-TestResult `
        -Area "Network" `
        -TestCase "Local SR-IOV check" `
        -ExpectedResult "SR-IOV can be checked on the local node." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $initiatorPorts = @(Get-InitiatorPort -ErrorAction SilentlyContinue |
        Select-Object NodeAddress, PortAddress, ConnectionType)

    $iscsiSessions = @(Get-IscsiSession -ErrorAction SilentlyContinue |
        Select-Object InitiatorNodeAddress, InitiatorPortalAddress, TargetNodeAddress, TargetPortalAddress, IsConnected, SessionIdentifier)

    $disks = @(Get-Disk -ErrorAction Stop |
        Select-Object Number, FriendlyName, SerialNumber, BusType, OperationalStatus, HealthStatus, IsOffline, IsReadOnly)

    $mpioFeature = Get-WindowsFeature -Name Multipath-IO -ErrorAction SilentlyContinue |
        Select-Object Name, InstallState, Installed

    $mpioSetting = $null
    if (Test-CommandExists -Name "Get-MPIOSetting") {
        $mpioSetting = Get-MPIOSetting -ErrorAction SilentlyContinue |
            Select-Object PathVerificationState, PathVerificationPeriod, PDORemovePeriod, RetryCount, RetryInterval, UseCustomPathRecoveryTime, CustomPathRecoveryTime, DiskTimeoutValue
    }

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
    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "Local SAN paths and MPIO check" `
        -ExpectedResult "SAN and MPIO state can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $csv = @(Get-ClusterSharedVolume -Cluster $ClusterAccessName -ErrorAction Stop)
    $csvData = @($csv | ForEach-Object { ConvertTo-SafeCsvObject -Csv $_ })
    $offlineCsv = @($csvData | Where-Object { [string]$_.State -ne "Online" })

    $status = if ($csvData.Count -gt 0 -and $offlineCsv.Count -eq 0) { "Successful" } else { "NotSuccessful" }
    $offlineCsvText = ConvertTo-TextList -InputObject $offlineCsv -PropertyName "Name"

    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "CSV check" `
        -ExpectedResult "Cluster Shared Volumes are online and available." `
        -Status $status `
        -Remark "CSV count=$($csvData.Count); Offline=$offlineCsvText" `
        -Data $csvData
}
catch {
    Add-TestResult `
        -Area "SAN Storage" `
        -TestCase "CSV check" `
        -ExpectedResult "CSV state can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $groups = @(Get-ClusterGroup -Cluster $ClusterAccessName -ErrorAction Stop)
    $groupData = @($groups | ForEach-Object { ConvertTo-SafeClusterGroupObject -Group $_ })
    $vmGroups = @($groupData | Where-Object { [string]$_.GroupType -eq "VirtualMachine" })
    $failedVmGroups = @($vmGroups | Where-Object { [string]$_.State -ne "Online" })

    $status = if ($failedVmGroups.Count -eq 0) { "Successful" } else { "NotSuccessful" }
    $offlineVmText = ConvertTo-TextList -InputObject $failedVmGroups -PropertyName "Name"

    Add-TestResult `
        -Area "HA" `
        -TestCase "Cluster VM role check" `
        -ExpectedResult "Cluster VMs are online and highly available." `
        -Status $status `
        -Remark "Cluster VM roles=$($vmGroups.Count); Offline=$offlineVmText" `
        -Data $vmGroups
}
catch {
    Add-TestResult `
        -Area "HA" `
        -TestCase "Cluster VM role check" `
        -ExpectedResult "Cluster VM roles can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $hotfixes = @(Get-HotFix -ErrorAction Stop | Sort-Object InstalledOn -Descending | Select-Object -First 30)
    $latest = $hotfixes | Select-Object -First 1
    $latestHotfixId = Get-ObjectPropertyValueSafe -InputObject $latest -PropertyName "HotFixID" -DefaultValue "None"
    $latestInstalledOn = Get-ObjectPropertyValueSafe -InputObject $latest -PropertyName "InstalledOn" -DefaultValue "Unknown"

    Add-TestResult `
        -Area "Updates" `
        -TestCase "Local node updates check" `
        -ExpectedResult "Local node patch state is documented." `
        -Status "ManualReview" `
        -Remark "Latest installed update: $latestHotfixId / $latestInstalledOn" `
        -Data $hotfixes
}
catch {
    Add-TestResult `
        -Area "Updates" `
        -TestCase "Local node updates check" `
        -ExpectedResult "Installed updates can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    if (Test-CommandExists -Name "Get-CauClusterRole") {
        $cauRole = Get-CauClusterRole -ClusterName $ClusterAccessName -ErrorAction SilentlyContinue |
            Select-Object ClusterName, Name, GroupName, UpdatingRunStatus, MaxFailedNodes, RequireAllNodesOnline, CauPluginName

        Add-TestResult `
            -Area "Updates" `
            -TestCase "Cluster-Aware Updating check" `
            -ExpectedResult "CAU role and update method are documented." `
            -Status "ManualReview" `
            -Remark "CAU role collected locally. Review configuration." `
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
    Add-TestResult `
        -Area "Updates" `
        -TestCase "Cluster-Aware Updating check" `
        -ExpectedResult "CAU state can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $smbServer = Get-SmbServerConfiguration -ErrorAction Stop |
        Select-Object EnableSMB1Protocol, EnableSMB2Protocol, RequireSecuritySignature, EnableSecuritySignature, EncryptData, RejectUnencryptedAccess, EnableLeasing, EnableMultiChannel

    $smbClient = Get-SmbClientConfiguration -ErrorAction Stop |
        Select-Object EnableSecuritySignature, RequireSecuritySignature, EnableInsecureGuestLogons, EnableMultiChannel, ConnectionCountPerRssNetworkInterface

    $ntlm = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
    $lsa = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

    $restrictReceiving = Get-ObjectPropertyValueSafe -InputObject $ntlm -PropertyName "RestrictReceivingNTLMTraffic" -DefaultValue "NotConfigured"
    $restrictSending = Get-ObjectPropertyValueSafe -InputObject $ntlm -PropertyName "RestrictSendingNTLMTraffic" -DefaultValue "NotConfigured"
    $lmCompatibilityLevel = Get-ObjectPropertyValueSafe -InputObject $lsa -PropertyName "LMCompatibilityLevel" -DefaultValue "NotConfigured"

    $securitySummary = [pscustomobject]@{
        ComputerName                  = $env:COMPUTERNAME
        SMB1Enabled                   = Get-ObjectPropertyValueSafe -InputObject $smbServer -PropertyName "EnableSMB1Protocol" -DefaultValue "Unknown"
        SMB2AndSMB3Enabled            = Get-ObjectPropertyValueSafe -InputObject $smbServer -PropertyName "EnableSMB2Protocol" -DefaultValue "Unknown"
        SMBServerRequireSigning       = Get-ObjectPropertyValueSafe -InputObject $smbServer -PropertyName "RequireSecuritySignature" -DefaultValue "Unknown"
        SMBClientRequireSigning       = Get-ObjectPropertyValueSafe -InputObject $smbClient -PropertyName "RequireSecuritySignature" -DefaultValue "Unknown"
        RestrictReceivingNTLMTraffic  = $restrictReceiving
        RestrictSendingNTLMTraffic    = $restrictSending
        LMCompatibilityLevel          = $lmCompatibilityLevel
    }

    Add-TestResult `
        -Area "Security" `
        -TestCase "Local SMB and NTLM configuration check" `
        -ExpectedResult "SMB and NTLM state are documented on the local node." `
        -Status "ManualReview" `
        -Remark "SMB1=$($securitySummary.SMB1Enabled); SMB2/3=$($securitySummary.SMB2AndSMB3Enabled); RestrictReceivingNTLMTraffic=$restrictReceiving" `
        -Data @{ Summary = $securitySummary; SmbServer = $smbServer; SmbClient = $smbClient; NTLM = $ntlm; LSA = $lsa }
}
catch {
    Add-TestResult `
        -Area "Security" `
        -TestCase "Local SMB and NTLM configuration check" `
        -ExpectedResult "SMB and NTLM settings can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $systemEvents = @(Get-RecentEventSummary -Hours $EventLogHours -LogNames @("System") -Levels @(1, 2, 3))
    $clusterEvents = @(Get-RecentEventSummary -Hours $EventLogHours -LogNames @("Microsoft-Windows-FailoverClustering/Operational") -Levels @(1, 2, 3))

    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Local cluster event logs check" `
        -ExpectedResult "No critical cluster or system errors are present on the local node." `
        -Status "ManualReview" `
        -Remark "Recent System events=$($systemEvents.Count); FailoverClustering events=$($clusterEvents.Count); WindowHours=$EventLogHours" `
        -Data @{ SystemEvents = $systemEvents; ClusterEvents = $clusterEvents }
}
catch {
    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Local cluster event logs check" `
        -ExpectedResult "Cluster logs can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $quorum = Get-ClusterQuorum -Cluster $ClusterAccessName -ErrorAction Stop
    $quorumData = [pscustomobject]@{
        ClusterName    = $ClusterAccessName
        QuorumResource = Get-ObjectPropertyValueSafe -InputObject $quorum -PropertyName "QuorumResource" -DefaultValue "NotAvailable"
        QuorumType     = Get-ObjectPropertyValueSafe -InputObject $quorum -PropertyName "QuorumType" -DefaultValue "NotAvailable"
    }

    Add-TestResult `
        -Area "Disaster Recovery" `
        -TestCase "Cluster quorum check" `
        -ExpectedResult "Quorum is correctly configured." `
        -Status "ManualReview" `
        -Remark "QuorumResource=$($quorumData.QuorumResource); QuorumType=$($quorumData.QuorumType)" `
        -Data $quorumData
}
catch {
    Add-TestResult `
        -Area "Disaster Recovery" `
        -TestCase "Cluster quorum check" `
        -ExpectedResult "Quorum can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $cluster = Get-Cluster -Name $ClusterAccessName -ErrorAction Stop

    $clusterSummary = [pscustomobject]@{
        Name                    = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "Name" -DefaultValue $ClusterAccessName
        Domain                  = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "Domain" -DefaultValue "NotAvailable"
        ClusterFunctionalLevel  = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "ClusterFunctionalLevel" -DefaultValue "PropertyNotAvailable"
        ClusterUpgradeVersion   = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "ClusterUpgradeVersion" -DefaultValue "PropertyNotAvailable"
        DynamicQuorum           = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "DynamicQuorum" -DefaultValue "NotAvailable"
        SameSubnetDelay         = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "SameSubnetDelay" -DefaultValue "NotAvailable"
        SameSubnetThreshold     = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "SameSubnetThreshold" -DefaultValue "NotAvailable"
        CrossSubnetDelay        = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "CrossSubnetDelay" -DefaultValue "NotAvailable"
        CrossSubnetThreshold    = Get-ObjectPropertyValueSafe -InputObject $cluster -PropertyName "CrossSubnetThreshold" -DefaultValue "NotAvailable"
    }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Cluster functional level check" `
        -ExpectedResult "Cluster functional level is documented and appropriate for Server 2025." `
        -Status "ManualReview" `
        -Remark "ClusterFunctionalLevel=$($clusterSummary.ClusterFunctionalLevel); ClusterUpgradeVersion=$($clusterSummary.ClusterUpgradeVersion)" `
        -Data $clusterSummary
}
catch {
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Cluster functional level check" `
        -ExpectedResult "Cluster functional level can be queried." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $vms = @(Get-VM -ErrorAction Stop)
    $integration = @(
        foreach ($vm in $vms) {
            Get-VMIntegrationService -VMName $vm.Name -ErrorAction SilentlyContinue |
                Select-Object `
                    @{Name = "HostName"; Expression = { $env:COMPUTERNAME }},
                    VMName,
                    Name,
                    Enabled,
                    PrimaryStatusDescription,
                    SecondaryStatusDescription
        }
    )

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local Hyper-V integration services check" `
        -ExpectedResult "Hyper-V integration services are current and healthy for VMs visible on this node." `
        -Status "ManualReview" `
        -Remark "Integration services collected locally for VMs visible on $env:COMPUTERNAME. VM count=$($vms.Count)" `
        -Data $integration
}
catch {
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local Hyper-V integration services check" `
        -ExpectedResult "Integration services can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $deviceGuardStatus = Get-DeviceGuardSummarySafe -TimeoutSec $DeviceGuardTimeoutSec
    $cg = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $deviceGuardRegistry = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
    $hvci = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"

    $lsaCfgFlags = Get-ObjectPropertyValueSafe -InputObject $cg -PropertyName "LsaCfgFlags" -DefaultValue "NotConfigured"
    $enableVbs = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRegistry -PropertyName "EnableVirtualizationBasedSecurity" -DefaultValue "NotConfigured"
    $requirePlatformSecurity = Get-ObjectPropertyValueSafe -InputObject $deviceGuardRegistry -PropertyName "RequirePlatformSecurityFeatures" -DefaultValue "NotConfigured"
    $hvciEnabled = Get-ObjectPropertyValueSafe -InputObject $hvci -PropertyName "Enabled" -DefaultValue "NotConfigured"
    $hvciWasEnabledBy = Get-ObjectPropertyValueSafe -InputObject $hvci -PropertyName "WasEnabledBy" -DefaultValue "NotConfigured"
    $hvciEnabledBootId = Get-ObjectPropertyValueSafe -InputObject $hvci -PropertyName "EnabledBootId" -DefaultValue "NotConfigured"

    $securityFeatureSummary = [pscustomobject]@{
        ComputerName                        = $env:COMPUTERNAME
        DeviceGuardCimStatus                = $deviceGuardStatus
        CredentialGuard_LsaCfgFlags         = $lsaCfgFlags
        DeviceGuard_EnableVBS               = $enableVbs
        DeviceGuard_RequirePlatformSecurity = $requirePlatformSecurity
        HVCI_Enabled                        = $hvciEnabled
        HVCI_WasEnabledBy                   = $hvciWasEnabledBy
        HVCI_EnabledBootId                  = $hvciEnabledBootId
    }

    $deviceGuardQueryStatus = Get-ObjectPropertyValueSafe -InputObject $deviceGuardStatus -PropertyName "QueryStatus" -DefaultValue "Unknown"
    $remarkPrefix = if ($deviceGuardQueryStatus -eq "Completed") { "DeviceGuard CIM query completed." } else { "DeviceGuard CIM query failed or timed out; registry fallback collected." }

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local VBS Credential Guard HVCI check" `
        -ExpectedResult "VBS, Credential Guard and HVCI state are documented on the local node." `
        -Status "ManualReview" `
        -Remark "$remarkPrefix LsaCfgFlags=$lsaCfgFlags; HVCI Enabled=$hvciEnabled" `
        -Data $securityFeatureSummary
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
        Add-TestResult `
            -Area "Special Server 2025" `
            -TestCase "Windows Admin Center connectivity check" `
            -ExpectedResult "Windows Admin Center is reachable." `
            -Status "Skipped" `
            -Remark "No WAC host was provided."
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
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Windows Admin Center connectivity check" `
        -ExpectedResult "WAC reachability can be tested." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

try {
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 30 -ErrorAction Stop |
        Where-Object { $_.DeviceClass -in @("NET", "SCSIADAPTER", "HDC", "SYSTEM", "STORAGECONTROLLER") } |
        Select-Object PSComputerName, DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName)

    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local firmware and driver inventory" `
        -ExpectedResult "NIC, HBA, RAID and storage related driver states are documented on the local node." `
        -Status "ManualReview" `
        -Remark "Driver entries collected locally: $($drivers.Count)" `
        -Data $drivers
}
catch {
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Local firmware and driver inventory" `
        -ExpectedResult "Driver information can be queried locally." `
        -Status "NotSuccessful" `
        -Remark $_.Exception.Message
}

Complete-TestRun
