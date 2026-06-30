<#
.SYNOPSIS
Creates a localized performance counter file from an English source counter file.

.DESCRIPTION
Reads English performance counter paths and resolves the object and counter names through the
Windows Perflib registry mapping. This allows the toolkit to create a German or otherwise localized
counter file on the target host without manually translating every counter name.

Run this script on a target server that has the relevant roles installed, for example a German
Windows Server 2019 Hyper-V host. Hyper-V-specific counter sets are only available when the
Hyper-V role and related services are present.

.NOTES
File Name     : Convert-HVClusterPerfCountersToLocalized.ps1
Version       : v0.1.0
Created       : 2026-06-30
Last Modified : 2026-06-30
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
Purpose       : Generate localized Windows performance counter files for the Hyper-V cluster toolkit.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string] $SourceCounterFile,

    [Parameter(Mandatory = $false)]
    [string] $OutputCounterFile,

    [Parameter(Mandatory = $false)]
    [string] $LanguageId = '007',

    [Parameter(Mandatory = $false)]
    [switch] $Validate,

    [Parameter(Mandatory = $false)]
    [switch] $KeepUnresolved
)

Set-StrictMode -Version 2.0

$toolkitRoot = Split-Path -Path $PSScriptRoot -Parent

if ([string]::IsNullOrWhiteSpace($SourceCounterFile)) {
    $SourceCounterFile = Join-Path -Path $toolkitRoot -ChildPath 'counters\HostCounters-English.txt'
}

if ([string]::IsNullOrWhiteSpace($OutputCounterFile)) {
    $OutputCounterFile = Join-Path -Path $toolkitRoot -ChildPath 'counters\HostCounters-Localized.txt'
}

function New-CounterNameToIdMap {
    param(
        [Parameter(Mandatory = $true)] [string[]] $RawCounterData
    )

    $map = @{}
    for ($index = 0; $index -lt ($RawCounterData.Count - 1); $index += 2) {
        $id = $RawCounterData[$index]
        $name = $RawCounterData[$index + 1]

        if ($id -match '^\d+$' -and -not [string]::IsNullOrWhiteSpace($name)) {
            if (-not $map.ContainsKey($name)) {
                $map[$name] = [int]$id
            }
        }
    }

    return $map
}

function New-CounterIdToNameMap {
    param(
        [Parameter(Mandatory = $true)] [string[]] $RawCounterData
    )

    $map = @{}
    for ($index = 0; $index -lt ($RawCounterData.Count - 1); $index += 2) {
        $id = $RawCounterData[$index]
        $name = $RawCounterData[$index + 1]

        if ($id -match '^\d+$' -and -not [string]::IsNullOrWhiteSpace($name)) {
            $map[[int]$id] = $name
        }
    }

    return $map
}

function Resolve-LocalizedPerfName {
    param(
        [Parameter(Mandatory = $true)] [string] $EnglishName,
        [Parameter(Mandatory = $true)] [hashtable] $EnglishNameToId,
        [Parameter(Mandatory = $true)] [hashtable] $LocalizedIdToName
    )

    if (-not $EnglishNameToId.ContainsKey($EnglishName)) {
        return $null
    }

    $id = $EnglishNameToId[$EnglishName]
    if (-not $LocalizedIdToName.ContainsKey($id)) {
        return $null
    }

    return $LocalizedIdToName[$id]
}

function ConvertTo-LocalizedCounterPath {
    param(
        [Parameter(Mandatory = $true)] [string] $CounterPath,
        [Parameter(Mandatory = $true)] [hashtable] $EnglishNameToId,
        [Parameter(Mandatory = $true)] [hashtable] $LocalizedIdToName
    )

    $trimmed = $CounterPath.Trim()
    $match = [regex]::Match($trimmed, '^\\(?<object>[^\\\(]+)(?<instance>\([^\\]+\))?\\(?<counter>.+)$')

    if (-not $match.Success) {
        return [pscustomobject]@{
            SourcePath    = $CounterPath
            LocalizedPath = $null
            Status        = 'ParseFailed'
            Message       = 'Counter path format was not recognized.'
        }
    }

    $englishObject = $match.Groups['object'].Value
    $instance = $match.Groups['instance'].Value
    $englishCounter = $match.Groups['counter'].Value

    $localizedObject = Resolve-LocalizedPerfName -EnglishName $englishObject -EnglishNameToId $EnglishNameToId -LocalizedIdToName $LocalizedIdToName
    $localizedCounter = Resolve-LocalizedPerfName -EnglishName $englishCounter -EnglishNameToId $EnglishNameToId -LocalizedIdToName $LocalizedIdToName

    $missing = @()
    if ([string]::IsNullOrWhiteSpace($localizedObject)) { $missing += "object '$englishObject'" }
    if ([string]::IsNullOrWhiteSpace($localizedCounter)) { $missing += "counter '$englishCounter'" }

    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            SourcePath    = $CounterPath
            LocalizedPath = $null
            Status        = 'Unresolved'
            Message       = "Could not resolve $($missing -join ', ')."
        }
    }

    return [pscustomobject]@{
        SourcePath    = $CounterPath
        LocalizedPath = "\$localizedObject$instance\$localizedCounter"
        Status        = 'Resolved'
        Message       = ''
    }
}

if (-not (Test-Path -Path $SourceCounterFile)) {
    throw "Source counter file not found: $SourceCounterFile"
}

$perflibRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib'
$englishPerflibPath = Join-Path -Path $perflibRoot -ChildPath '009'
$localizedPerflibPath = Join-Path -Path $perflibRoot -ChildPath $LanguageId

if (-not (Test-Path -Path $englishPerflibPath)) {
    throw "English Perflib registry path not found: $englishPerflibPath"
}

if (-not (Test-Path -Path $localizedPerflibPath)) {
    throw "Localized Perflib registry path not found: $localizedPerflibPath. For German systems this is usually 007."
}

$englishRaw = (Get-ItemProperty -Path $englishPerflibPath -Name Counter -ErrorAction Stop).Counter
$localizedRaw = (Get-ItemProperty -Path $localizedPerflibPath -Name Counter -ErrorAction Stop).Counter

$englishNameToId = New-CounterNameToIdMap -RawCounterData $englishRaw
$localizedIdToName = New-CounterIdToNameMap -RawCounterData $localizedRaw

$sourceLines = Get-Content -Path $SourceCounterFile -Encoding UTF8
$counterLines = $sourceLines | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }

$results = New-Object System.Collections.Generic.List[object]
$outputCounters = New-Object System.Collections.Generic.List[string]

foreach ($counterPath in $counterLines) {
    $result = ConvertTo-LocalizedCounterPath -CounterPath $counterPath -EnglishNameToId $englishNameToId -LocalizedIdToName $localizedIdToName
    $results.Add($result)

    if ($result.Status -eq 'Resolved') {
        $outputCounters.Add($result.LocalizedPath)
    }
    elseif ($KeepUnresolved) {
        $outputCounters.Add($counterPath)
    }
}

$outputDirectory = Split-Path -Path $OutputCounterFile -Parent
if (-not (Test-Path -Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$header = @(
    '# File Name     : ' + (Split-Path -Path $OutputCounterFile -Leaf),
    '# Version       : v0.1.0',
    '# Created       : 2026-06-30',
    '# Last Modified : 2026-06-30',
    '# Author        : Nouramon Alvestrasza',
    '# Organization  : Alvestrasza Corporation',
    '# Description   : Localized Hyper-V host performance counter list generated from HostCounters-English.txt.',
    '#',
    '# Generated On  : ' + $env:COMPUTERNAME,
    '# LanguageId    : ' + $LanguageId,
    '# Source File   : ' + $SourceCounterFile,
    ''
)

$header + $outputCounters | Set-Content -Path $OutputCounterFile -Encoding UTF8 -Force

$reportPath = [System.IO.Path]::ChangeExtension($OutputCounterFile, '.LocalizationReport.csv')
$results | Export-Csv -Path $reportPath -NoTypeInformation -Encoding UTF8 -Force

$validPath = $null
$invalidPath = $null
$validCount = $null
$invalidCount = $null

if ($Validate) {
    $valid = New-Object System.Collections.Generic.List[string]
    $invalid = New-Object System.Collections.Generic.List[object]

    foreach ($counter in $outputCounters) {
        try {
            Get-Counter -Counter $counter -SampleInterval 1 -MaxSamples 1 -ErrorAction Stop | Out-Null
            $valid.Add($counter)
        }
        catch {
            $invalid.Add([pscustomobject]@{
                Counter = $counter
                Error   = $_.Exception.Message
            })
        }
    }

    $validPath = [System.IO.Path]::ChangeExtension($OutputCounterFile, '.Valid.txt')
    $invalidPath = [System.IO.Path]::ChangeExtension($OutputCounterFile, '.Invalid.csv')

    $valid | Set-Content -Path $validPath -Encoding UTF8 -Force
    $invalid | Export-Csv -Path $invalidPath -NoTypeInformation -Encoding UTF8 -Force

    $validCount = $valid.Count
    $invalidCount = $invalid.Count
}

return [pscustomobject]@{
    ComputerName       = $env:COMPUTERNAME
    SourceCounterFile  = $SourceCounterFile
    OutputCounterFile  = $OutputCounterFile
    LanguageId         = $LanguageId
    ResolvedCount      = (@($results | Where-Object { $_.Status -eq 'Resolved' })).Count
    UnresolvedCount    = (@($results | Where-Object { $_.Status -ne 'Resolved' })).Count
    ReportPath         = $reportPath
    ValidationEnabled  = [bool]$Validate
    ValidCounterFile   = $validPath
    InvalidCounterFile = $invalidPath
    ValidCount         = $validCount
    InvalidCount       = $invalidCount
}
