<!--
File Name     : README_DE.md
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Description   : German usage guide for the Hyper-V cluster performance toolkit.
-->

# HVClusterPerfToolkit

PowerShell-Toolkit zur Performanceanalyse eines Windows Server 2019 Hyper-V SAN Failover Clusters.

## Ziel

Das Toolkit sammelt clusterweit Performance- und Evidenzdaten für Analysen bei:

- Cluster-Patching
- Cluster-Aware Updating
- Host Drain / Resume
- Live Migration
- CSV-/SAN-Latenzen
- Netzwerkengpässen
- VM-Performanceproblemen
- Host-Überlastung durch temporäre Lastverdichtung

## Inhalt

```text
HVClusterPerfToolkit
├─ config
│  └─ HVClusterPerfConfig.json
├─ counters
│  └─ HostCounters-English.txt
├─ scripts
│  ├─ HVClusterPerf.Common.ps1
│  ├─ Test-HVClusterPerfCounters.ps1
│  ├─ Initialize-HVClusterPerfCollector.ps1
│  ├─ Start-HVClusterPerfCollector.ps1
│  ├─ Stop-HVClusterPerfCollector.ps1
│  ├─ Export-HVClusterPerfEvidence.ps1
│  └─ Invoke-HVClusterPerfWorkflow.ps1
└─ docs
   └─ QuickReference-DE.md
```

## Voraussetzungen

- Windows Server 2019 auf den Hyper-V Hosts
- Hyper-V Rolle installiert
- Failover-Clustering-Modul auf Clusterknoten oder Managementhost
- PowerShell Remoting aktiviert, wenn clusterweit gesteuert werden soll
- administrative Rechte auf allen Zielhosts
- Admin Shares erreichbar, z. B. `\\HOST\D$`
- ausreichend freier Speicher auf `D:\PerfLogs\HVClusterPerf`

> Hinweis: Die Skripte verwenden bewusst `D:\PerfLogs\HVClusterPerf` als Standardpfad, damit keine großen BLG- und Exportdateien auf `C:` landen.

## 1. Konfiguration anpassen

Datei:

```powershell
.\config\HVClusterPerfConfig.json
```

Wichtige Werte:

```json
"RootPath": "D:\\PerfLogs\\HVClusterPerf",
"SampleInterval": "00:00:15",
"MaxFileSizeMB": 4096,
"EventLookbackHours": 12,
"ClusterNodes": []
```

`ClusterNodes` kann leer bleiben, wenn das Skript die Knoten über `Get-ClusterNode` ermitteln kann.

Optional können die Knoten fest eingetragen werden:

```json
"ClusterNodes": [
  "HVNODE01",
  "HVNODE02",
  "HVNODE03",
  "HVNODE04",
  "HVNODE05",
  "HVNODE06",
  "HVNODE07",
  "HVNODE08"
]
```

## 2. Counter lokal testen

Auf einem Host:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
.\scripts\Test-HVClusterPerfCounters.ps1
```

Wichtig bei deutschen Windows-Installationen:
Performance Counter können lokalisiert sein. Wenn viele Counter als fehlend gemeldet werden, muss die Counterliste lokalisiert oder mit `Get-Counter -ListSet *` / `typeperf -qx` geprüft werden.

## 3. Collector clusterweit initialisieren

Vom Managementhost oder einem Clusterknoten:

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Initialize `
  -ClusterName "CLUSTERNAME" `
  -ForceRecreate
```

Alternativ mit expliziter Hostliste:

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Initialize `
  -ComputerName HVNODE01,HVNODE02,HVNODE03,HVNODE04,HVNODE05,HVNODE06,HVNODE07,HVNODE08 `
  -ForceRecreate
```

## 4. Messung vor dem Patchfenster starten

Empfehlung: 30–60 Minuten vor Beginn starten.

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Start `
  -ClusterName "CLUSTERNAME"
```

## 5. Status prüfen

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Status `
  -ClusterName "CLUSTERNAME"
```

## 6. Messung stoppen und Daten exportieren

Empfehlung: 60–120 Minuten nach Ende des Patchfensters stoppen.

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action StopAndExport `
  -ClusterName "CLUSTERNAME" `
  -RunId "PatchWindow-20260630" `
  -CollectExports
```

Mit `-CollectExports` werden die erzeugten ZIP-Dateien vom jeweiligen Host in den lokalen Ordner `CollectedExports` kopiert.

## 7. Exportinhalt pro Host

Jedes Host-ZIP enthält unter anderem:

- BLG Performance Logs
- System und Application Eventlogs
- FailoverClustering Operational Log
- Hyper-V VMMS / Worker / Hypervisor Logs
- Cluster Node Status
- Cluster Groups / VM-Verteilung
- CSV Status und OwnerNode
- Cluster Networks und Metrics
- VM-Konfigurationen
- VM vCPU / RAM / VHDX / vNIC Daten
- VMSwitch-Informationen
- NetAdapter- und NetAdapterStatistics-Daten
- VMQ / RSS Informationen
- MPIO / iSCSI / Disk / Volume Informationen
- `ipconfig /all`
- `route print`
- `netstat -ano`
- `mpclaim -s -d`
- `mpclaim -s -m`
- `systeminfo`

## 8. Empfohlener Ablauf für das Kundenproblem

1. Toolkit auf Managementhost entpacken.
2. `HVClusterPerfConfig.json` anpassen.
3. Counter auf einem Host testen.
4. Collector clusterweit initialisieren.
5. Messung 30–60 Minuten vor Patchbeginn starten.
6. Während Patchen Drain, Live Migration, Reboot und Resume-Zeitpunkte notieren.
7. Messung 60–120 Minuten nach Patchende stoppen.
8. Evidenzdaten exportieren.
9. BLG-Dateien mit Patch-Zeitpunkten, CSV-Besitz, VM-Verteilung, SAN- und Switchdaten korrelieren.

## 9. Typische Auswertungsschwerpunkte

- CPU-Auslastung auf verbleibenden Hosts während Drain
- RAM-Druck durch temporäre VM-Verdichtung
- Disk Write Latency während Live Migration / Patchinstallation
- TCP Retransmits während Live Migration
- NIC-Auslastung Live-Migration-Netzwerk
- CSV Redirected I/O
- SAN LUN Latency und Queue Full Events
- MPIO Path Changes
- Hyper-V VMMS / Worker Events
- FailoverClustering Warnings

## 10. Wichtige Hinweise

- Das Toolkit löscht keine VMs, Clusterrollen oder Logs.
- `-ForceRecreate` löscht nur den vorhandenen logman Collector mit gleichem Namen und erstellt ihn neu.
- BLG-Dateien können groß werden. Der Standard verwendet `bincirc` mit maximal 4096 MB pro Host.
- Für akute Incidents kann das Sample-Intervall in der Config reduziert werden, z. B. auf `00:00:05`.
- Eventlogs werden standardmäßig nur für die letzten 12 Stunden exportiert.


## Deutsche Performance Counter

Ab v0.1.1 liegt zusätzlich eine vorbereitete deutsche Counter-Datei bei:

```powershell
.\scripts\Test-HVClusterPerfCounters.ps1 -CounterFile .\counters\HostCounters-German.txt
```

Collector lokal mit deutscher Counter-Datei initialisieren:

```powershell
.\scripts\Initialize-HVClusterPerfCollector.ps1 `
  -CounterFile .\counters\HostCounters-German.txt `
  -ForceRecreate
```

Clusterweit über den Workflow:

```powershell
.\scripts\Invoke-HVClusterPerfWorkflow.ps1 `
  -Action Initialize `
  -ClusterName "CLUSTERNAME" `
  -CounterFile "counters\HostCounters-German.txt" `
  -ForceRecreate
```

Falls auf einem deutschen Host mehrere Counter fehlen, sollte die exakte lokale Datei direkt auf dem Zielhost generiert werden:

```powershell
.\scripts\Convert-HVClusterPerfCountersToLocalized.ps1 `
  -SourceCounterFile .\counters\HostCounters-English.txt `
  -OutputCounterFile .\counters\HostCounters-German-Generated.txt `
  -LanguageId 007 `
  -Validate
```

Für Deutsch ist der Windows-Perflib-Sprachcode normalerweise `007`. Das generierte `.Valid.txt` kann anschließend als Counter-Datei für `Initialize-HVClusterPerfCollector.ps1` verwendet werden.
