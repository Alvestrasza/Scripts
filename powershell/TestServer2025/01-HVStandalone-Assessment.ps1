#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Read-only assessment for a Windows Server 2025 standalone Hyper-V host.

.DESCRIPTION
Checks OS installation, Hyper-V role and services, management connectivity, virtual switches,
SR-IOV readiness, local storage, VM inventory, updates, SMB, NTLM policy state,
VBS / Credential Guard / HVCI, WAC reachability, event logs, and driver information.

.NOTES
File Name     : 01-HVStandalone-Assessment.ps1
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
    [string]$WindowsAdminCenterUrl = ""
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVStandalone-Assessment"

# Installation: Server 2025 installation check
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $status = if ($os.Caption -match "Windows Server 2025") { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Installation" `
        -TestCase "Server 2025 installation check" `
        -ExpectedResult "Host runs Windows Server 2025 and boots successfully." `
        -Status $status `
        -Remark "OS=$($os.Caption), Build=$($os.BuildNumber), LastBoot=$($os.LastBootUpTime)" `
        -Data $os
}
catch {
    Add-TestResult -Area "Installation" -TestCase "Server 2025 installation check" -ExpectedResult "OS information can be read." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Monitoring: Event logs after boot
try {
    $criticalEvents = Get-RecentEventSummary -Hours 24 -Levels @(1, 2)
    $status = if (($criticalEvents | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

    Add-TestResult `
        -Area "Monitoring" `
        -TestCase "Event logs check" `
        -ExpectedResult "No critical errors or unexpected errors in recent logs." `
        -Status $status `
        -Remark "Found $(( $criticalEvents | Measure-Object ).Count) critical/error events in the last 24 hours." `
        -Data $criticalEvents
}
catch {
    Add-TestResult -Area "Monitoring" -TestCase "Event logs check" -ExpectedResult "Event logs can be read." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Installation: Hyper-V role installed
try {
    $feature = Get-WindowsFeature -Name Hyper-V
    $services = Get-Service -Name vmms, vmcompute -ErrorAction SilentlyContinue

    $allServicesRunning = ($services | Where-Object Status -ne "Running" | Measure-Object).Count -eq 0
    $status = if ($feature.Installed -and $allServicesRunning) { "Successful" } else { "NotSuccessful" }

    Add-TestResult `
        -Area "Installation" `
        -TestCase "Hyper-V role installed" `
        -ExpectedResult "Hyper-V role is installed and Hyper-V services are running." `
        -Status $status `
        -Remark "Hyper-V installed=$($feature.Installed); Services=$($services | ForEach-Object { "$($_.Name):$($_.Status)" } -join ', ')" `
        -Data @{
            Feature = $feature
            Services = $services
        }
}
catch {
    Add-TestResult -Area "Installation" -TestCase "Hyper-V role installed" -ExpectedResult "Hyper-V role and services can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Network: Management network reachable
try {
    if ($ManagementTargets.Count -eq 0) {
        $gateways = Get-NetIPConfiguration |
            Where-Object { $_.IPv4DefaultGateway } |
            ForEach-Object { $_.IPv4DefaultGateway.NextHop } |
            Select-Object -Unique

        $ManagementTargets = @($gateways)
    }

    if ($ManagementTargets.Count -eq 0) {
        Add-TestResult `
            -Area "Network" `
            -TestCase "Management network reachable" `
            -ExpectedResult "Ping, RDP and management are possible." `
            -Status "ManualReview" `
            -Remark "No management targets were provided and no default gateway was detected."
    }
    else {
        $checks = foreach ($target in $ManagementTargets) {
            Test-TcpPort -ComputerName $target -Port 3389
            Test-TcpPort -ComputerName $target -Port 5985
            Test-TcpPort -ComputerName $target -Port 5986
        }

        $failed = $checks | Where-Object { -not $_.PingSucceeded -and -not $_.TcpSucceeded }
        $status = if (($failed | Measure-Object).Count -eq 0) { "Successful" } else { "ManualReview" }

        Add-TestResult `
            -Area "Network" `
            -TestCase "Management network reachable" `
            -ExpectedResult "Ping, RDP and PowerShell remoting are reachable where enabled." `
            -Status $status `
            -Remark "Checked targets: $($ManagementTargets -join ', ')" `
            -Data $checks
    }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Management network reachable" -ExpectedResult "Network reachability can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Network: Virtual switches
try {
    $switches = Get-VMSwitch
    $missingSwitches = @()

    foreach ($expected in $ExpectedSwitches) {
        if ($expected -notin $switches.Name) {
            $missingSwitches += $expected
        }
    }

    $status = if ($ExpectedSwitches.Count -gt 0 -and $missingSwitches.Count -gt 0) {
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

# Network: SR-IOV on second switch
try {
    if ([string]::IsNullOrWhiteSpace($SecondSwitchName)) {
        Add-TestResult `
            -Area "Network" `
            -TestCase "SR-IOV second switch check" `
            -ExpectedResult "SR-IOV is enabled and usable on the second switch." `
            -Status "Skipped" `
            -Remark "No second switch name was provided."
    }
    else {
        $switch = Get-VMSwitch -Name $SecondSwitchName -ErrorAction Stop
        $sriovAdapters = if (Test-CommandExists -Name "Get-NetAdapterSriov") {
            Get-NetAdapterSriov -ErrorAction SilentlyContinue
        }
        else {
            $null
        }

        $vmAdapter = $null
        if (-not [string]::IsNullOrWhiteSpace($TestVmName) -and (Get-VM -Name $TestVmName -ErrorAction SilentlyContinue)) {
            $vmAdapter = Get-VMNetworkAdapter -VMName $TestVmName
        }

        $status = if ($switch.IovEnabled -eq $true) { "Successful" } else { "NotSuccessful" }

        Add-TestResult `
            -Area "Network" `
            -TestCase "SR-IOV second switch check" `
            -ExpectedResult "Second vSwitch has SR-IOV enabled and VM adapter can use it." `
            -Status $status `
            -Remark "Switch=$SecondSwitchName; IovEnabled=$($switch.IovEnabled); IovSupport=$($switch.IovSupport)" `
            -Data @{
                Switch = $switch
                PhysicalAdapters = $sriovAdapters
                VmAdapter = $vmAdapter
            }
    }
}
catch {
    Add-TestResult -Area "Network" -TestCase "SR-IOV second switch check" -ExpectedResult "SR-IOV configuration can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Storage: Local disks and volumes
try {
    $disks = Get-Disk
    $volumes = Get-Volume | Where-Object DriveType -eq "Fixed"

    $badDisks = $disks | Where-Object { $_.OperationalStatus -notcontains "Online" -or $_.HealthStatus -ne "Healthy" }
    $badVolumes = $volumes | Where-Object { $_.HealthStatus -ne "Healthy" }

    $status = if (($badDisks | Measure-Object).Count -eq 0 -and ($badVolumes | Measure-Object).Count -eq 0) {
        "Successful"
    }
    else {
        "NotSuccessful"
    }

    Add-TestResult `
        -Area "Storage" `
        -TestCase "Local disks check" `
        -ExpectedResult "All local disks and volumes are online and healthy." `
        -Status $status `
        -Remark "Disks=$(( $disks | Measure-Object ).Count); Volumes=$(( $volumes | Measure-Object ).Count)" `
        -Data @{
            Disks = $disks
            Volumes = $volumes
        }
}
catch {
    Add-TestResult -Area "Storage" -TestCase "Local disks check" -ExpectedResult "Local disks can be checked." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# VM operation: VM inventory and integration services
try {
    $vms = Get-VM
    $integration = foreach ($vm in $vms) {
        Get-VMIntegrationService -VMName $vm.Name
    }

    Add-TestResult `
        -Area "VM Operation" `
        -TestCase "VM inventory and integration services" `
        -ExpectedResult "VMs are visible and integration services are available." `
        -Status "Successful" `
        -Remark "VM count=$(( $vms | Measure-Object ).Count)" `
        -Data @{
            VMs = $vms
            IntegrationServices = $integration
        }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "VM inventory and integration services" -ExpectedResult "VMs can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Updates: Host updates
try {
    $hotfixes = Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 30

    Add-TestResult `
        -Area "Updates" `
        -TestCase "Host updates check" `
        -ExpectedResult "Current patch state is documented." `
        -Status "ManualReview" `
        -Remark "Latest installed update: $($hotfixes[0].HotFixID) / $($hotfixes[0].InstalledOn)" `
        -Data $hotfixes
}
catch {
    Add-TestResult -Area "Updates" -TestCase "Host updates check" -ExpectedResult "Installed updates can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Security: SMB configuration
try {
    $smbServer = Get-SmbServerConfiguration
    $smbClient = Get-SmbClientConfiguration

    $status = if ($smbServer.EnableSMB1Protocol -eq $false -and $smbServer.EnableSMB2Protocol -eq $true) {
        "Successful"
    }
    else {
        "ManualReview"
    }

    Add-TestResult `
        -Area "Security" `
        -TestCase "SMB configuration check" `
        -ExpectedResult "SMB is active and functional; SMBv1 disabled; signing/encryption state documented." `
        -Status $status `
        -Remark "SMB1=$($smbServer.EnableSMB1Protocol); SMB2/3=$($smbServer.EnableSMB2Protocol); RequireSigning=$($smbServer.RequireSecuritySignature)" `
        -Data @{
            Server = $smbServer
            Client = $smbClient
        }
}
catch {
    Add-TestResult -Area "Security" -TestCase "SMB configuration check" -ExpectedResult "SMB configuration can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Security: NTLM policy state
try {
    $ntlmPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\MSV1_0"
    $lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

    $ntlm = if (Test-Path $ntlmPath) { Get-ItemProperty -Path $ntlmPath } else { $null }
    $lsa = Get-ItemProperty -Path $lsaPath

    Add-TestResult `
        -Area "Security" `
        -TestCase "NTLM restriction state check" `
        -ExpectedResult "NTLM policy state is documented before Kerberos-only validation." `
        -Status "ManualReview" `
        -Remark "RestrictReceivingNTLMTraffic=$($ntlm.RestrictReceivingNTLMTraffic); RestrictSendingNTLMTraffic=$($ntlm.RestrictSendingNTLMTraffic); LMCompatibilityLevel=$($lsa.LMCompatibilityLevel)" `
        -Data @{
            NTLM = $ntlm
            LSA = $lsa
        }
}
catch {
    Add-TestResult -Area "Security" -TestCase "NTLM restriction state check" -ExpectedResult "NTLM policy registry can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
}

# Special Server 2025: VBS / Credential Guard / HVCI
try {
    $deviceGuard = Get-CimInstance -Namespace "root\Microsoft\Windows\DeviceGuard" -ClassName Win32_DeviceGuard -ErrorAction SilentlyContinue
    $cgPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    $hvciPath = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"

    $cg = Get-ItemProperty -Path $cgPath -ErrorAction SilentlyContinue
    $hvci = Get-ItemProperty -Path $hvciPath -ErrorAction SilentlyContinue

    Add-TestResult `
        -Area "Security" `
        -TestCase "VBS Credential Guard HVCI check" `
        -ExpectedResult "VBS, Credential Guard and HVCI state are documented." `
        -Status "ManualReview" `
        -Remark "LsaCfgFlags=$($cg.LsaCfgFlags); HVCI Enabled=$($hvci.Enabled)" `
        -Data @{
            DeviceGuard = $deviceGuard
            CredentialGuardRegistry = $cg
            HvciRegistry = $hvci
        }
}
catch {
    Add-TestResult -Area "Security" -TestCase "VBS Credential Guard HVCI check" -ExpectedResult "Security feature state can be queried." -Status "NotSuccessful" -Remark $_.Exception.Message
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

# Firmware and driver documentation
try {
    $drivers = Get-CimInstance Win32_PnPSignedDriver |
        Where-Object {
            $_.DeviceClass -in @("NET", "SCSIADAPTER", "HDC", "SYSTEM", "STORAGECONTROLLER")
        } |
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