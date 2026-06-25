#requires -Version 5.1
#requires -RunAsAdministrator

<#
.SYNOPSIS
Local-only active functional tests for a Windows Server 2025 standalone Hyper-V host.

.DESCRIPTION
Optionally creates and starts a local test VM, restarts the test VM, changes dynamic memory configuration,
enables SR-IOV weight for a VM adapter, and optionally performs export/import based backup and restore tests.
This script does not use PowerShell remoting.

.NOTES
File Name     : 02-HVStandalone-ActiveTests-Local.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$OutputRoot = "D:\CustomerTests\Server2025",
    [string]$TestVmName = "HVST-TEST-VM01",
    [string]$SwitchName = "",
    [string]$VmPath = "D:\Hyper-V\TestVMs",
    [UInt64]$StartupMemoryBytes = 2GB,
    [UInt64]$MinimumMemoryBytes = 1GB,
    [UInt64]$MaximumMemoryBytes = 4GB,
    [int]$VhdSizeGB = 40,

    [switch]$CreateTestVm,
    [switch]$StartTestVm,
    [switch]$RestartTestVm,
    [switch]$TestLiveConfiguration,
    [switch]$EnableSriovForVm,
    [switch]$RunExportBackupTest,
    [switch]$RunRestoreImportTest,

    [string]$BackupPath = "D:\CustomerTests\Server2025\VMBackup",
    [string]$RestorePath = "D:\CustomerTests\Server2025\VMRestore"
)

. "$PSScriptRoot\00-Common-TestHelpers.ps1"

Initialize-TestRun -OutputRoot $OutputRoot -RunName "HVStandalone-ActiveTests-Local"

try {
    if ($CreateTestVm) {
        if ([string]::IsNullOrWhiteSpace($SwitchName)) {
            throw "SwitchName must be provided when CreateTestVm is used."
        }

        $vmRoot = Join-Path $VmPath $TestVmName
        $vhdPath = Join-Path $vmRoot "Virtual Hard Disks\$TestVmName.vhdx"
        New-Item -Path (Split-Path $vhdPath) -ItemType Directory -Force | Out-Null

        if (-not (Test-Path $vhdPath)) {
            New-VHD -Path $vhdPath -SizeBytes ($VhdSizeGB * 1GB) -Dynamic -ErrorAction Stop | Out-Null
        }

        if (-not (Get-VM -Name $TestVmName -ErrorAction SilentlyContinue)) {
            New-VM `
                -Name $TestVmName `
                -Generation 2 `
                -MemoryStartupBytes $StartupMemoryBytes `
                -VHDPath $vhdPath `
                -SwitchName $SwitchName `
                -Path $VmPath `
                -ErrorAction Stop | Out-Null

            Set-VMMemory `
                -VMName $TestVmName `
                -DynamicMemoryEnabled $true `
                -MinimumBytes $MinimumMemoryBytes `
                -StartupBytes $StartupMemoryBytes `
                -MaximumBytes $MaximumMemoryBytes `
                -ErrorAction Stop
        }

        $vm = Get-VM -Name $TestVmName -ErrorAction Stop
        Add-TestResult `
            -Area "VM Operation" `
            -TestCase "Create VM" `
            -ExpectedResult "Test VM is created successfully." `
            -Status "Successful" `
            -Remark "VM=$TestVmName; Path=$vmRoot; VHD=$vhdPath" `
            -Data $vm
    }
    else {
        Add-TestResult -Area "VM Operation" -TestCase "Create VM" -ExpectedResult "Test VM can be created." -Status "Skipped" -Remark "CreateTestVm was not specified."
    }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "Create VM" -ExpectedResult "Test VM is created successfully." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($StartTestVm) {
        Start-VM -Name $TestVmName -ErrorAction Stop
        Start-Sleep -Seconds 5
        $vm = Get-VM -Name $TestVmName -ErrorAction Stop
        $status = if ($vm.State -eq "Running") { "Successful" } else { "NotSuccessful" }

        Add-TestResult `
            -Area "VM Operation" `
            -TestCase "Start VM" `
            -ExpectedResult "VM starts without Hyper-V errors." `
            -Status $status `
            -Remark "VM=$TestVmName; State=$($vm.State)" `
            -Data $vm
    }
    else {
        Add-TestResult -Area "VM Operation" -TestCase "Start VM" -ExpectedResult "VM starts successfully." -Status "Skipped" -Remark "StartTestVm was not specified."
    }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "Start VM" -ExpectedResult "VM starts without Hyper-V errors." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($RestartTestVm) {
        Restart-VM -Name $TestVmName -Force -ErrorAction Stop
        Start-Sleep -Seconds 10
        $vm = Get-VM -Name $TestVmName -ErrorAction Stop
        $status = if ($vm.State -eq "Running") { "Successful" } else { "NotSuccessful" }

        Add-TestResult `
            -Area "VM Operation" `
            -TestCase "VM restart" `
            -ExpectedResult "VM restarts successfully." `
            -Status $status `
            -Remark "VM=$TestVmName; State=$($vm.State)" `
            -Data $vm
    }
    else {
        Add-TestResult -Area "VM Operation" -TestCase "VM restart" -ExpectedResult "VM restarts successfully." -Status "Skipped" -Remark "RestartTestVm was not specified."
    }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "VM restart" -ExpectedResult "VM restarts successfully." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($TestLiveConfiguration) {
        Set-VMMemory `
            -VMName $TestVmName `
            -DynamicMemoryEnabled $true `
            -MinimumBytes $MinimumMemoryBytes `
            -StartupBytes $StartupMemoryBytes `
            -MaximumBytes $MaximumMemoryBytes `
            -ErrorAction Stop

        $memory = Get-VMMemory -VMName $TestVmName -ErrorAction Stop
        Add-TestResult `
            -Area "VM Operation" `
            -TestCase "Live configuration test" `
            -ExpectedResult "Resource changes are possible while the VM is configured for dynamic memory." `
            -Status "Successful" `
            -Remark "DynamicMemory=$($memory.DynamicMemoryEnabled); Min=$($memory.Minimum); Startup=$($memory.Startup); Max=$($memory.Maximum)" `
            -Data $memory
    }
    else {
        Add-TestResult -Area "VM Operation" -TestCase "Live configuration test" -ExpectedResult "Live resource changes are possible." -Status "Skipped" -Remark "TestLiveConfiguration was not specified."
    }
}
catch {
    Add-TestResult -Area "VM Operation" -TestCase "Live configuration test" -ExpectedResult "Live resource changes are possible." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($EnableSriovForVm) {
        Set-VMNetworkAdapter -VMName $TestVmName -IovWeight 100 -ErrorAction Stop
        $adapter = Get-VMNetworkAdapter -VMName $TestVmName -ErrorAction Stop
        Add-TestResult `
            -Area "Network" `
            -TestCase "Enable SR-IOV for VM adapter" `
            -ExpectedResult "VM adapter is configured to use SR-IOV when the vSwitch supports it." `
            -Status "ManualReview" `
            -Remark "IovWeight=$($adapter.IovWeight); SwitchName=$($adapter.SwitchName)" `
            -Data $adapter
    }
    else {
        Add-TestResult -Area "Network" -TestCase "Enable SR-IOV for VM adapter" -ExpectedResult "VM receives SR-IOV support." -Status "Skipped" -Remark "EnableSriovForVm was not specified."
    }
}
catch {
    Add-TestResult -Area "Network" -TestCase "Enable SR-IOV for VM adapter" -ExpectedResult "VM receives SR-IOV support." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($RunExportBackupTest) {
        New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
        Export-VM -Name $TestVmName -Path $BackupPath -ErrorAction Stop
        Add-TestResult `
            -Area "Backup" `
            -TestCase "Export VM backup test" `
            -ExpectedResult "VM export completes successfully." `
            -Status "Successful" `
            -Remark "VM=$TestVmName; BackupPath=$BackupPath"
    }
    else {
        Add-TestResult -Area "Backup" -TestCase "Export VM backup test" -ExpectedResult "VM backup completes successfully." -Status "Skipped" -Remark "RunExportBackupTest was not specified."
    }
}
catch {
    Add-TestResult -Area "Backup" -TestCase "Export VM backup test" -ExpectedResult "VM export completes successfully." -Status "NotSuccessful" -Remark $_.Exception.Message
}

try {
    if ($RunRestoreImportTest) {
        $exportedVmcx = Get-ChildItem -Path $BackupPath -Recurse -Filter "*.vmcx" | Select-Object -First 1
        if (-not $exportedVmcx) {
            throw "No exported VMCX file was found under $BackupPath."
        }

        $restoreVmPath = Join-Path $RestorePath "Virtual Machines"
        $restoreVhdPath = Join-Path $RestorePath "Virtual Hard Disks"
        New-Item -Path $restoreVmPath -ItemType Directory -Force | Out-Null
        New-Item -Path $restoreVhdPath -ItemType Directory -Force | Out-Null

        $importedVm = Import-VM `
            -Path $exportedVmcx.FullName `
            -Copy `
            -GenerateNewId `
            -VirtualMachinePath $restoreVmPath `
            -VhdDestinationPath $restoreVhdPath `
            -ErrorAction Stop

        $restoreName = "$TestVmName-RESTORE-TEST"
        Rename-VM -VM $importedVm -NewName $restoreName -ErrorAction SilentlyContinue

        Add-TestResult `
            -Area "Backup" `
            -TestCase "Restore import test" `
            -ExpectedResult "VM can be restored by importing an exported copy." `
            -Status "Successful" `
            -Remark "Imported VM as $restoreName; RestorePath=$RestorePath" `
            -Data $importedVm
    }
    else {
        Add-TestResult -Area "Backup" -TestCase "Restore import test" -ExpectedResult "VM restore completes successfully." -Status "Skipped" -Remark "RunRestoreImportTest was not specified."
    }
}
catch {
    Add-TestResult -Area "Backup" -TestCase "Restore import test" -ExpectedResult "VM restore completes successfully." -Status "NotSuccessful" -Remark $_.Exception.Message
}

Complete-TestRun
