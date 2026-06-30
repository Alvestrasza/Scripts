<#
.SYNOPSIS
Shared helper functions for the Hyper-V cluster performance toolkit.

.DESCRIPTION
Provides configuration loading, directory handling, counter validation, snapshot export,
admin share path conversion, and safe command execution helpers used by the toolkit scripts.

.NOTES
File Name     : HVClusterPerf.Common.ps1
Version       : v0.1.1
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Shared helper functions for Hyper-V cluster performance data collection.
#>

Set-StrictMode -Version 2.0

function Get-HVToolkitRoot {
    return (Split-Path -Path $PSScriptRoot -Parent)
}

function Get-HVTimestamp {
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Get-HVPropertyValue {
    param(
        [Parameter(Mandatory = $true)] [object] $Object,
        [Parameter(Mandatory = $true)] [string] $Name,
        [object] $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    if ($Object.PSObject.Properties.Name -contains $Name) {
        $value = $Object.$Name
        if ($null -ne $value -and $value -ne '') {
            return $value
        }
    }

    return $Default
}

function Read-HVClusterPerfConfig {
    param(
        [Parameter(Mandatory = $false)] [string] $ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = Join-Path -Path (Get-HVToolkitRoot) -ChildPath 'config\HVClusterPerfConfig.json'
    }

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Configuration file not found: $ConfigPath"
    }

    return (Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}


function Resolve-HVToolkitRelativePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }

    return (Join-Path -Path (Get-HVToolkitRoot) -ChildPath $Path)
}

function New-HVDirectory {
    param(
        [Parameter(Mandatory = $true)] [string] $Path
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    return (Resolve-Path -Path $Path).Path
}

function Get-HVSafeFileName {
    param(
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $result = $Name
    foreach ($char in $invalidChars) {
        $result = $result.Replace($char, '_')
    }
    $result = $result.Replace('/', '_').Replace('\', '_').Replace(':', '_')
    return $result
}

function ConvertTo-HVAdminSharePath {
    param(
        [Parameter(Mandatory = $true)] [string] $ComputerName,
        [Parameter(Mandatory = $true)] [string] $LocalPath
    )

    if ($LocalPath -notmatch '^[A-Za-z]:\\') {
        throw "Only local drive paths can be converted to admin shares. Path: $LocalPath"
    }

    $drive = $LocalPath.Substring(0, 1)
    $rest = $LocalPath.Substring(2).TrimStart('\')
    return "\\$ComputerName\$drive`$\$rest"
}

function Resolve-HVClusterPerfNodes {
    param(
        [Parameter(Mandatory = $false)] [object] $Config,
        [Parameter(Mandatory = $false)] [string[]] $ComputerName,
        [Parameter(Mandatory = $false)] [string] $ClusterName
    )

    if ($ComputerName -and $ComputerName.Count -gt 0) {
        return @($ComputerName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $configuredNodes = Get-HVPropertyValue -Object $Config -Name 'ClusterNodes' -Default @()
    if ($configuredNodes -and $configuredNodes.Count -gt 0) {
        return @($configuredNodes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    if (Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
                return @((Get-ClusterNode -Cluster $ClusterName -ErrorAction Stop).Name | Select-Object -Unique)
            }

            return @((Get-ClusterNode -ErrorAction Stop).Name | Select-Object -Unique)
        }
        catch {
            Write-Warning "Cluster nodes could not be resolved through Failover Clustering cmdlets. Falling back to local computer. $($_.Exception.Message)"
        }
    }

    return @($env:COMPUTERNAME)
}

function Read-HVCounterFile {
    param(
        [Parameter(Mandatory = $true)] [string] $CounterFile
    )

    if (-not (Test-Path -Path $CounterFile)) {
        throw "Counter file not found: $CounterFile"
    }

    $counters = Get-Content -Path $CounterFile -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and -not $_.StartsWith('#')
    }

    if (-not $counters -or $counters.Count -eq 0) {
        throw "Counter file does not contain usable counter paths: $CounterFile"
    }

    return @($counters)
}

function Test-HVCounterList {
    param(
        [Parameter(Mandatory = $true)] [string[]] $Counters,
        [Parameter(Mandatory = $true)] [string] $OutputDirectory
    )

    New-HVDirectory -Path $OutputDirectory | Out-Null

    $valid = New-Object System.Collections.Generic.List[string]
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($counter in $Counters) {
        $status = 'Valid'
        $message = ''

        try {
            Get-Counter -Counter $counter -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop | Out-Null
            $valid.Add($counter)
        }
        catch {
            $status = 'MissingOrFailed'
            $message = $_.Exception.Message
        }

        $results.Add([pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Counter      = $counter
            Status       = $status
            Message      = $message
        })
    }

    $timestamp = Get-HVTimestamp
    $resultCsv = Join-Path -Path $OutputDirectory -ChildPath "CounterValidation-$env:COMPUTERNAME-$timestamp.csv"
    $validFile = Join-Path -Path $OutputDirectory -ChildPath "ValidCounters-$env:COMPUTERNAME.txt"
    $missingCsv = Join-Path -Path $OutputDirectory -ChildPath "MissingCounters-$env:COMPUTERNAME-$timestamp.csv"

    $results | Export-Csv -Path $resultCsv -NoTypeInformation -Encoding UTF8
    $valid | Set-Content -Path $validFile -Encoding UTF8
    $results | Where-Object { $_.Status -ne 'Valid' } | Export-Csv -Path $missingCsv -NoTypeInformation -Encoding UTF8

    return [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        ValidCount   = $valid.Count
        TotalCount   = $Counters.Count
        ValidFile    = $validFile
        ResultCsv    = $resultCsv
        MissingCsv   = $missingCsv
    }
}

function Invoke-HVExternalCommand {
    param(
        [Parameter(Mandatory = $true)] [string] $FilePath,
        [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        [Parameter(Mandatory = $false)] [string] $OutputFile
    )

    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE

    if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
        $output | Out-File -FilePath $OutputFile -Encoding UTF8 -Force
    }

    return [pscustomobject]@{
        FilePath     = $FilePath
        Arguments    = ($ArgumentList -join ' ')
        ExitCode     = $exitCode
        Output       = ($output -join [Environment]::NewLine)
    }
}

function Export-HVObjectSafe {
    param(
        [Parameter(Mandatory = $true)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $false)] [string] $Description = 'Command output',
        [Parameter(Mandatory = $false)] [switch] $AsText
    )

    try {
        $data = & $ScriptBlock
        if ($AsText) {
            $data | Out-File -FilePath $Path -Encoding UTF8 -Force
        }
        else {
            $data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Force
        }
    }
    catch {
        $errorPath = "$Path.error.txt"
        "Failed to export $Description. Error: $($_.Exception.Message)" | Out-File -FilePath $errorPath -Encoding UTF8 -Force
    }
}

function Export-HVCommandTextSafe {
    param(
        [Parameter(Mandatory = $true)] [string] $CommandLine,
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $false)] [string] $Description = 'Command output'
    )

    try {
        cmd.exe /c $CommandLine 2>&1 | Out-File -FilePath $Path -Encoding UTF8 -Force
    }
    catch {
        "Failed to export $Description. Error: $($_.Exception.Message)" | Out-File -FilePath "$Path.error.txt" -Encoding UTF8 -Force
    }
}

function Export-HVClusterPerfSnapshot {
    param(
        [Parameter(Mandatory = $true)] [string] $OutputDirectory
    )

    New-HVDirectory -Path $OutputDirectory | Out-Null

    Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ComputerInfo.csv') -Description 'computer information' -ScriptBlock { Get-ComputerInfo }
    Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Services-HyperV-Cluster-Storage.csv') -Description 'service status' -ScriptBlock { Get-Service | Where-Object { $_.Name -match '^(vmms|clussvc|mpio|msiscsi|stor)' -or $_.DisplayName -match 'Hyper-V|Cluster|MPIO|iSCSI|Storage' } }
    Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Processes-TopCpu.csv') -Description 'top CPU processes' -ScriptBlock { Get-Process | Sort-Object CPU -Descending | Select-Object -First 50 Name, Id, CPU, WorkingSet64, Handles, Path }
    Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Processes-TopMemory.csv') -Description 'top memory processes' -ScriptBlock { Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 50 Name, Id, CPU, WorkingSet64, Handles, Path }

    if (Get-Command -Name Get-ClusterNode -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ClusterNodes.csv') -Description 'cluster nodes' -ScriptBlock { Get-ClusterNode | Select-Object Name, State, DrainStatus, DynamicWeight, NodeWeight }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ClusterGroups.csv') -Description 'cluster groups' -ScriptBlock { Get-ClusterGroup | Sort-Object OwnerNode, Name | Select-Object Name, OwnerNode, State, GroupType, Priority }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ClusterSharedVolumes.csv') -Description 'cluster shared volumes' -ScriptBlock { Get-ClusterSharedVolume | Select-Object Name, State, OwnerNode }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ClusterNetworks.csv') -Description 'cluster networks' -ScriptBlock { Get-ClusterNetwork | Select-Object Name, Role, Metric, State, Address, AddressMask }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'ClusterResources.csv') -Description 'cluster resources' -ScriptBlock { Get-ClusterResource | Select-Object Name, ResourceType, State, OwnerGroup, OwnerNode }
    }

    if (Get-Command -Name Get-VMHost -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMHost.csv') -Description 'Hyper-V host settings' -ScriptBlock { Get-VMHost | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMs.csv') -Description 'Hyper-V VMs' -ScriptBlock { Get-VM | Sort-Object ComputerName, Name | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime, Status, Version, Generation, ProcessorCount, ComputerName, Path, ConfigurationLocation, SnapshotFileLocation }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMProcessors.csv') -Description 'Hyper-V VM processors' -ScriptBlock { Get-VMProcessor -VMName * | Select-Object VMName, Count, CompatibilityForMigrationEnabled, CompatibilityForOlderOperatingSystemsEnabled, HwThreadCountPerCore, Maximum, Reserve, RelativeWeight }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMMemory.csv') -Description 'Hyper-V VM memory' -ScriptBlock { Get-VMMemory -VMName * | Select-Object VMName, DynamicMemoryEnabled, Startup, Minimum, Maximum, Buffer, Priority }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMHardDiskDrives.csv') -Description 'Hyper-V VM hard disk drives' -ScriptBlock { Get-VMHardDiskDrive -VMName * | Select-Object VMName, ControllerType, ControllerNumber, ControllerLocation, Path, DiskNumber, MaximumIOPS, MinimumIOPS, QoSPolicyID }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMNetworkAdapters.csv') -Description 'Hyper-V VM network adapters' -ScriptBlock { Get-VMNetworkAdapter -VMName * | Select-Object VMName, Name, SwitchName, Status, MacAddress, IsManagementOs, IovWeight, IovQueuePairsRequested, IovQueuePairsAssigned, IovUsage, VmqWeight, VrssEnabled, DeviceNaming }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'HyperV-VMSwitches.csv') -Description 'Hyper-V virtual switches' -ScriptBlock { Get-VMSwitch | Select-Object Name, SwitchType, NetAdapterInterfaceDescription, AllowManagementOS, EmbeddedTeamingEnabled, IovEnabled, IovSupport, IovVirtualFunctionsInUse, IovQueuePairsInUse }
    }

    if (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Network-NetAdapters.csv') -Description 'network adapters' -ScriptBlock { Get-NetAdapter | Select-Object Name, InterfaceDescription, Status, LinkSpeed, MacAddress, DriverInformation, DriverFileName, DriverVersion, DriverDate, NdisVersion, VlanID }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Network-NetAdapterStatistics.csv') -Description 'network adapter statistics' -ScriptBlock { Get-NetAdapterStatistics | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Network-NetIPConfiguration.csv') -Description 'IP configuration' -ScriptBlock { Get-NetIPConfiguration | Select-Object InterfaceAlias, InterfaceDescription, IPv4Address, IPv6Address, IPv4DefaultGateway, IPv6DefaultGateway, DNSServer }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Network-NetAdapterRss.csv') -Description 'network adapter RSS settings' -ScriptBlock { Get-NetAdapterRss | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Network-NetAdapterVmq.csv') -Description 'network adapter VMQ settings' -ScriptBlock { Get-NetAdapterVmq | Select-Object * }
    }

    if (Get-Command -Name Get-MPIOSetting -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-MPIOSettings.csv') -Description 'MPIO settings' -ScriptBlock { Get-MPIOSetting | Select-Object * }
    }

    if (Get-Command -Name Get-IscsiSession -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-IscsiSessions.csv') -Description 'iSCSI sessions' -ScriptBlock { Get-IscsiSession | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-IscsiConnections.csv') -Description 'iSCSI connections' -ScriptBlock { Get-IscsiConnection | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-InitiatorPorts.csv') -Description 'initiator ports' -ScriptBlock { Get-InitiatorPort | Select-Object * }
    }

    if (Get-Command -Name Get-Disk -ErrorAction SilentlyContinue) {
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-Disks.csv') -Description 'disks' -ScriptBlock { Get-Disk | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-Volumes.csv') -Description 'volumes' -ScriptBlock { Get-Volume | Select-Object * }
        Export-HVObjectSafe -Path (Join-Path $OutputDirectory 'Storage-PhysicalDisks.csv') -Description 'physical disks' -ScriptBlock { Get-PhysicalDisk | Select-Object * }
    }

    Export-HVCommandTextSafe -CommandLine 'ipconfig /all' -Path (Join-Path $OutputDirectory 'ipconfig-all.txt') -Description 'ipconfig'
    Export-HVCommandTextSafe -CommandLine 'route print' -Path (Join-Path $OutputDirectory 'route-print.txt') -Description 'routing table'
    Export-HVCommandTextSafe -CommandLine 'netstat -ano' -Path (Join-Path $OutputDirectory 'netstat-ano.txt') -Description 'netstat'
    Export-HVCommandTextSafe -CommandLine 'mpclaim -s -d' -Path (Join-Path $OutputDirectory 'mpclaim-s-d.txt') -Description 'mpclaim disk view'
    Export-HVCommandTextSafe -CommandLine 'mpclaim -s -m' -Path (Join-Path $OutputDirectory 'mpclaim-s-m.txt') -Description 'mpclaim MPIO view'
    Export-HVCommandTextSafe -CommandLine 'systeminfo' -Path (Join-Path $OutputDirectory 'systeminfo.txt') -Description 'systeminfo'
}

function Export-HVEventLogs {
    param(
        [Parameter(Mandatory = $true)] [string] $OutputDirectory,
        [Parameter(Mandatory = $true)] [string[]] $LogNames,
        [Parameter(Mandatory = $true)] [int] $LookbackHours
    )

    New-HVDirectory -Path $OutputDirectory | Out-Null
    $milliseconds = [int64]$LookbackHours * 60 * 60 * 1000

    foreach ($logName in $LogNames) {
        $safeName = Get-HVSafeFileName -Name $logName
        $evtxPath = Join-Path -Path $OutputDirectory -ChildPath "$safeName.evtx"
        $csvPath = Join-Path -Path $OutputDirectory -ChildPath "$safeName.csv"
        $query = "*[System[TimeCreated[timediff(@SystemTime) <= $milliseconds]]]"

        try {
            $null = wevtutil.exe epl $logName $evtxPath "/q:$query" /ow:true 2>&1
            Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = (Get-Date).AddHours(-1 * $LookbackHours) } -ErrorAction Stop |
                Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, MachineName, Message |
                Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8 -Force
        }
        catch {
            "Failed to export event log '$logName'. Error: $($_.Exception.Message)" |
                Out-File -FilePath (Join-Path -Path $OutputDirectory -ChildPath "$safeName.error.txt") -Encoding UTF8 -Force
        }
    }
}
