<!--
File Name     : QuickReference-DE.md
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Description   : Quick reference for Hyper-V cluster performance collection commands.
-->

# Quick Reference – HVClusterPerfToolkit

## Vorbereitung

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
```

## Counter lokal testen

```powershell
.\scripts\Test-HVClusterPerfCounters.ps1
```

## Clusterweit initialisieren

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Initialize `
  -ClusterName "CLUSTERNAME" `
  -ForceRecreate
```

## Messung starten

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Start `
  -ClusterName "CLUSTERNAME"
```

## Status prüfen

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Status `
  -ClusterName "CLUSTERNAME"
```

## Messung stoppen und exportieren

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action StopAndExport `
  -ClusterName "CLUSTERNAME" `
  -RunId "PatchWindow-YYYYMMDD" `
  -CollectExports
```

## Nur exportieren

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Export `
  -ClusterName "CLUSTERNAME" `
  -RunId "PatchWindow-YYYYMMDD" `
  -CollectExports
```

## Lokaler Betrieb auf einem Host

```powershell
.\scripts\Initialize-HVClusterPerfCollector.ps1 -ForceRecreate
.\scripts\Start-HVClusterPerfCollector.ps1
.\scripts\Stop-HVClusterPerfCollector.ps1
.\scripts\Export-HVClusterPerfEvidence.ps1 -RunId "LocalTest-YYYYMMDD"
```

## Wichtig für Patchfenster

Zeitpunkte notieren:

- Messung Start
- Drain Start je Host
- Live Migration Start/Ende je Host
- Patchinstallation Start/Ende je Host
- Reboot je Host
- Resume je Host
- Messung Ende

Diese Zeitpunkte sind später entscheidend für die Auswertung der BLG-Dateien.


## Deutsche Counter-Datei

```powershell
.\scripts\Test-HVClusterPerfCounters.ps1 -CounterFile .\counters\HostCounters-German.txt
```

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Initialize `
  -ClusterName "CLUSTERNAME" `
  -CounterFile "counters\HostCounters-German.txt" `
  -ForceRecreate
```

Exakte lokale Übersetzung auf einem deutschen Zielhost erzeugen:

```powershell
.\scripts\Convert-HVClusterPerfCountersToLocalized.ps1 `
  -SourceCounterFile .\counters\HostCounters-English.txt `
  -OutputCounterFile .\counters\HostCounters-German-Generated.txt `
  -LanguageId 007 `
  -Validate
```
