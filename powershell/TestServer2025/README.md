# Hinweise

## Ausführungsbeispiele

### Allgemein

Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$OutputRootFolder = ".\"

### Standalone Host – nur Prüfung

.\01-HVStandalone-Assessment.ps1 `

-OutputRoot $OutputRootFolder `

-ManagementTargets @("192.168.10.1","HVHOST01") `

-ExpectedSwitches @("vSwitch-MGMT","vSwitch-VM","vSwitch-SRIOV") `

-SecondSwitchName "vSwitch-SRIOV" `

-TestVmName "HVST-TEST-VM01" `

-WindowsAdminCenterUrl "https://wac.customer.local"

### Standalone Host – aktive VM-Tests

.\02-HVStandalone-ActiveTests.ps1 `

-OutputRoot $OutputRootFolder `

-TestVmName "HVST-TEST-VM01" `

-SwitchName "vSwitch-VM" `

-CreateTestVm `

-StartTestVm `

-TestLiveConfiguration `

-RunExportBackupTest `

-RunRestoreImportTest

### Cluster/SAN – nur Prüfung

.\03-HVClusterSAN-Assessment.ps1 `

-OutputRoot $OutputRootFolder `

-ClusterName "HVCLUSTER01" `

-ExpectedNodes @("HVNODE01","HVNODE02") `

-RunClusterValidation `

-NodeFqdnSuffix "mgmt.customer.local" `

-WindowsAdminCenterUrl "https://wac.customer.local"


### Cluster/SAN – aktive HA-Tests

.\04-HVClusterSAN-ActiveTests.ps1 `

-OutputRoot $OutputRootFolder `

-ClusterName "HVCLUSTER01" `

-TestVmClusterRoleName "VM-HVCL-TEST01" `

-TargetNode "HVNODE02" `

-AllowLiveMigration

### Performance Capture

.\05-Performance-Capture.ps1 `

-OutputRoot "D:\CustomerTests\Server2025" `

-ComputerName @("HVNODE01","HVNODE02") `

-SampleIntervalSeconds 5 `

-MaxSamples 24

## Anmerkungen

| Testbereich                      |  Automatisierbarkeit | Hinweis                                                                                            |
| -------------------------------- | -------------------: | -------------------------------------------------------------------------------------------------- |
| Installation / Rollen / Services |             Sehr gut | Vollständig per PowerShell prüfbar                                                                 |
| Netzwerk / vSwitch / Management  |                  Gut | Zielsysteme und erwartete Switch-Namen müssen bekannt sein                                         |
| SR-IOV                           |               Mittel | vSwitch muss mit SR-IOV erstellt worden sein; nachträgliches Aktivieren ist nicht sauber generisch |
| VM-Betrieb                       |                  Gut | Test-VM kann erstellt, gestartet und exportiert werden                                             |
| Live-Konfiguration               |                  Gut | Dynamischer Speicher ist gut testbar                                                               |
| Performance                      |               Mittel | Aussagekräftige Lasttests brauchen DiskSpd / iperf3 oder Kundentools                               |
| SAN / MPIO                       |          Gut prüfbar | Pfadausfall selbst sollte manuell im Change-Fenster erfolgen                                       |
| HA / Live Migration              |                  Gut | Aktive Migration nur nach Freigabe                                                                 |
| Host-Ausfall                     |              Manuell | Nicht automatisieren; zu hohes Betriebsrisiko                                                      |
| NTLM deaktivieren                |             Kritisch | Erst auditieren, dann per GPO gezielt blockieren                                                   |
| Backup / Restore                 | Abhängig vom Produkt | Generisch ist nur Hyper-V Export/Import abbildbar                                                  |
