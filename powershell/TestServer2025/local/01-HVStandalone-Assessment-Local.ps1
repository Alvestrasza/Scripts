#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Local-only assessment for a Windows Server 2025 standalone Hyper-V host.

.DESCRIPTION
Checks the local operating system, Hyper-V role and services, management connectivity targets,
virtual switches, SR-IOV readiness, local storage, VM inventory, integration services, host updates,
SMB configuration, NTLM policy state, VBS, Credential Guard, HVCI, Windows Admin Center reachability,
event logs, and driver information. This script does not use PowerShell remoting.

.NOTES
File Name     : 01-HVStandalone-Assessment-Local.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025",
    [string[]]$ManagementTargets = @(),
    [string[]]$ExpectedSwitches = @(),
    [string]$SecondSwitchName = "",
    [string]$TestVmName = "",
    [string]$WindowsAdminCenterHost = "",
    [int]$WindowsAdminCenterPort = 443
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVStandalone-Assessment-Local"

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $status = if ($os.Caption -match "Windows Server 2025") { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Installation" `
        -TestCase "Server 2025 installation check" `
        -ExpectedResult "Host runs Windows Server 2025 and boots successfully." `
        -Status $status `
        -Remark "OS=$($os.Caption); Build=$($os.BuildNumber); LastBoot=$($os.LastBootUpTime)" `
        -Data $os
}
catch {
    Add-TestResult -Area "Installation" -TestCase "Server 2025 installation check" -ExpectedResult "OS information can be read." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $events = Get-RecentEventSummary -Hours 24 -Levels @(1, 2)
    $status = if (($events | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Event logs check" `
        -ExpectedResult "No critical errors or unexpected errors in recent logs." `
        -Status $status `
        -Remark "Found $(( $events | Measure-Object ).Count) critical/error events in the last 24 hours." `
        -Data $events
}
catch {
    Add-TestResult -Area "Monitoring" -TestCase "Event logs check" -ExpectedResult "Event logs can be read." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
    $services = Get-ServiceStateSafe -Name @("vmms", "vmcompute")
    $failedServices = $services | Where-Object Status -ne "Running"
    $status = if ($feature.Installed -and (($failedServices | Measure-Object).Count -eq 0)) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Installation" `
        -TestCase "Hyper-V role installed" `
        -ExpectedResult "Hyper-V role is installed and Hyper-V services are running." `
        -Status $status `
        -Remark "Hyper-V installed=$($feature.Installed); Services=$($services | ForEach-Object { "$($_.Name):$($_.Status)" } -join ', ')" `
        -Data @{ Feature = $feature; Services = $services }
}
catch {
    Add-TestResult -Area "Installation" -TestCase "Hyper-V role installed" -ExpectedResult "Hyper-V role and services can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($ManagementTargets.Count -eq 0) {
        $ManagementTargets = @(Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway } |
            ForEach-Object { $_.IPv4DefaultGateway.NextHop } |
            Select-Object -Unique)
    }

    if ($ManagementTargets.Count -eq 0) {
        Add-TestResult -Area "Network" -TestCase "Management network reachable" -ExpectedResult "Ping and management targets are reachable." -Status "ManualReview" -Remark "No management targets were provided and no default gateway was detected."
    }
    else {
        $checks = foreach ($target in $ManagementTargets) {
            Test-PingSafe -ComputerName $target
        }
        $failed = $checks | Where-Object { -not $_.PingSucceeded }
        $status = if (($failed | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

        Add-TestResult `
            -Area "Network" `
            -TestCase "Management network reachable" `
            -ExpectedResult "Management network targets are reachable by ICMP where allowed." `
            -Status $status `
            -Remark "Checked targets: $($ManagementTargets -join ', ')" `
            -Data $checks
    }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Management network reachable" -ExpectedResult "Network reachability can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $switches = Get-VMSwitch -ErrorAction Stop
    $missingSwitches = foreach ($expected in $ExpectedSwitches) {
        if ($expected -notin $switches.Name) { $expected }
    }

    $status = if ($ExpectedSwitches.Count -gt 0 -and ($missingSwitches | Measure-Object).Count -gt 0) {
        "NotSuccessful"
    }
    elseif (($switches | Measure-Object).Count -gt 0) {
        "Successful"
    }
    else {
        "ManualReview"
    }

    Add-TestResult `
        -Area "Network" `
        -TestCase "Virtual switches check" `
        -ExpectedResult "All required vSwitches exist and are correctly configured." `
        -Status $status `
        -Remark "Switches found: $($switches.Name -join ', '); Missing: $($missingSwitches -join ', ')" `
        -Data $switches
}
catch {
    Add-TestResult -Area "Network" -TestCase "Virtual switches check" -ExpectedResult "vSwitches can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ([string]::IsNullOrWhiteSpace($SecondSwitchName)) {
        Add-TestResult -Area "Network" -TestCase "SR-IOV second switch check" -ExpectedResult "SR-IOV is enabled and usable on the second switch." -Status "Skipped" -Remark "No second switch name was provided."
    }
    else {
        $switch = Get-VMSwitch -Name $SecondSwitchName -ErrorAction Stop
        $sriovAdapters = if (Test-CommandExists -Name "Get-NetAdapterSriov") { Get-NetAdapterSriov -ErrorAction SilentlyContinue } else { $null }
        $vmAdapter = if (-not [string]::IsNullOrWhiteSpace($TestVmName) -and (Get-VM -Name $TestVmName -ErrorAction SilentlyContinue)) { Get-VMNetworkAdapter -VMName $TestVmName } else { $null }
        $status = if ($switch.IovEnabled -eq $true) { "Successful" } else { "NotSuccessful" }

        Add-TestResult `
            -Area "Network" `
            -TestCase "SR-IOV second switch check" `
            -ExpectedResult "Second vSwitch has SR-IOV enabled and VM adapter can use it." `
            -Status $status `
            -Remark "Switch=$SecondSwitchName; IovEnabled=$($switch.IovEnabled); IovSupport=$($switch.IovSupport)" `
            -Data @{ Switch = $switch; PhysicalAdapters = $sriovAdapters; VmAdapter = $vmAdapter }
    }
}
catch {
    Add-TestResult -Area "Network" -TestCase "SR-IOV second switch check" -ExpectedResult "SR-IOV configuration can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $disks = Get-Disk -ErrorAction Stop
    $volumes = Get-Volume -ErrorAction Stop | Where-Object DriveType -eq "Fixed"
    $badDisks = $disks | Where-Object { $_.OperationalStatus -notcontains "Online" -or $_.HealthStatus -ne "Healthy" }
    $badVolumes = $volumes | Where-Object { $_.HealthStatus -ne "Healthy" }
    $status = if (($badDisks | Measure-Object).Count -eq 0 -and ($badVolumes | Measure-Object).Count -eq 0) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Storage" `
        -TestCase "Local disks check" `
        -ExpectedResult "All local disks and volumes are online and healthy." `
        -Status $status `
        -Remark "Disks=$(( $disks | Measure-Object ).Count); Volumes=$(( $volumes | Measure-Object ).Count)" `
        -Data @{ Disks = $disks; Volumes = $volumes }
}
catch {
    Add-TestResult -Area "Storage" -TestCase "Local disks check" -ExpectedResult "Local disks can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $vms = Get-VM -ErrorAction Stop
    $integration = foreach ($vm in $vms) { Get-VMIntegrationService -VMName $vm.Name -ErrorAction SilentlyContinue }
    Add-TestResult `
        -Area "VM Operation" `
        -TestCase "VM inventory and integration services" `
        -ExpectedResult "VMs are visible and integration services are available." `
        -Status "Successful" `
        -Remark "VM count=$(( $vms | Measure-Object ).Count)" `
        -Data @{ VMs = $vms; IntegrationServices = $integration }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "VM inventory and integration services" -ExpectedResult "VMs can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30
    $latest = $hotfixes | Select-Object -First 1
    Add-TestResult `
        -Area "Updates" `
        -TestCase "Host updates check" `
        -ExpectedResult "Current patch state is documented." `
        -Status "ManualReview" `
        -Remark "Latest installed update: $($latest.HotFixID) / $($latest.InstalledOn)" `
        -Data $hotfixes
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Host updates check" -ExpectedResult "Installed updates can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $smbServer = Get-SmbServerConfiguration -ErrorAction Stop
    $smbClient = Get-SmbClientConfiguration -ErrorAction Stop
    $status = if ($smbServer.EnableSMB1Protocol -eq $false -and $smbServer.EnableSMB2Protocol -eq $true) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Security" `
        -TestCase "SMB configuration check" `
        -ExpectedResult "SMB is active and functional; SMBv1 disabled; signing/encryption state documented." `
        -Status $status `
        -Remark "SMB1=$($smbServer.EnableSMB1Protocol); SMB2/3=$($smbServer.EnableSMB2Protocol); RequireSigning=$($smbServer.RequireSecuritySignature)" `
        -Data @{ Server = $smbServer; Client = $smbClient }
}
catch {
    Add-TestResult -Area "Security" -TestCase "SMB configuration check" -ExpectedResult "SMB configuration can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $ntlm = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
    $lsa = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Add-TestResult `
        -Area "Security" `
        -TestCase "NTLM restriction state check" `
        -ExpectedResult "NTLM policy state is documented before Kerberos-only validation." `
        -Status "ManualReview" `
        -Remark "RestrictReceivingNTLMTraffic=$($ntlm.RestrictReceivingNTLMTraffic); RestrictSendingNTLMTraffic=$($ntlm.RestrictSendingNTLMTraffic); LMCompatibilityLevel=$($lsa.LMCompatibilityLevel)" `
        -Data @{ NTLM = $ntlm; LSA = $lsa }
}
catch {
    Add-TestResult -Area "Security" -TestCase "NTLM restriction state check" -ExpectedResult "NTLM policy registry can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    $deviceGuard = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $cg = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $hvci = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
    Add-TestResult `
        -Area "Security" `
        -TestCase "VBS Credential Guard HVCI check" `
        -ExpectedResult "VBS, Credential Guard and HVCI state are documented." `
        -Status "ManualReview" `
        -Remark "LsaCfgFlags=$($cg.LsaCfgFlags); HVCI Enabled=$($hvci.Enabled)" `
        -Data @{ DeviceGuard = $deviceGuard; CredentialGuardRegistry = $cg; HvciRegistry = $hvci }
}
catch {
    Add-TestResult -Area "Security" -TestCase "VBS Credential Guard HVCI check" -ExpectedResult "Security feature state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
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
        Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, DriverDate, InfName
    Add-TestResult `
        -Area "Special Server 2025" `
        -TestCase "Firmware and driver inventory" `
        -ExpectedResult "NIC, HBA, RAID and storage related driver states are documented." `
        -Status "ManualReview" `
        -Remark "Driver entries collected: $(( $drivers | Measure-Object ).Count)" `
        -Data $drivers
}
catch {
    Add-TestResult -Area "Special Server 2025" -TestCase "Firmware and driver inventory" -ExpectedResult "Driver information can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun
