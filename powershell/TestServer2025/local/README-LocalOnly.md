# Server 2025 Hyper-V / Cluster Test Scripts - LocalOnly

Version: v0.1.0  
Created: 2026-06-25  
Last Modified: 2026-06-25  
Author: Nouramon Alvestrasza  
Organization: Alvestrasza Corporation

## Purpose

This package contains local-only PowerShell scripts for Windows Server 2025 Hyper-V standalone hosts and Hyper-V Failover Clusters with SAN storage.

The scripts do not use:

- Invoke-Command
- New-PSSession
- Enter-PSSession
- PowerShell remoting to cluster nodes

## Recommended execution order

### Standalone Hyper-V host

```powershell
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force
Get-ChildItem "D:\CustomerTests\Server2025\*.ps1" | Unblock-File

.\01-HVStandalone-Assessment-Local.ps1 -OutputRoot "D:\CustomerTests\Server2025\Logs"
```

Optional active VM tests:

```powershell
.\02-HVStandalone-ActiveTests-Local.ps1 `
  -OutputRoot "D:\CustomerTests\Server2025\Logs" `
  -TestVmName "HVST-TEST-VM01" `
  -SwitchName "vSwitch-VM" `
  -CreateTestVm `
  -StartTestVm `
  -TestLiveConfiguration
```

### Hyper-V cluster node

Run this on every cluster node locally:

```powershell
.\03-HVClusterSAN-Assessment-Local.ps1 `
  -OutputRoot "D:\CustomerTests\Server2025\Logs" `
  -ClusterName "HVCLUSTER01"
```

Optional cluster validation:

```powershell
.\03-HVClusterSAN-Assessment-Local.ps1 `
  -OutputRoot "D:\CustomerTests\Server2025\Logs" `
  -ClusterName "HVCLUSTER01" `
  -RunClusterValidation
```

Optional active HA test:

```powershell
.\04-HVClusterSAN-ActiveTests-Local.ps1 `
  -OutputRoot "D:\CustomerTests\Server2025\Logs" `
  -ClusterName "HVCLUSTER01" `
  -TestVmClusterRoleName "VM-HVCL-TEST01" `
  -TargetNode "HVNODE02" `
  -AllowLiveMigration
```

### Performance capture

```powershell
.\05-Performance-Capture-Local.ps1 `
  -OutputRoot "D:\CustomerTests\Server2025\Logs" `
  -SampleIntervalSeconds 5 `
  -MaxSamples 24
```

### Merge local results

After copying all result folders to a common location:

```powershell
.\06-Merge-LocalResults.ps1 `
  -ResultRoot "D:\CustomerTests\Server2025\Logs" `
  -OutputPath "D:\CustomerTests\Server2025\CombinedResults"
```
