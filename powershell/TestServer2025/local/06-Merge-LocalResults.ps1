#requires -Version 5.1

<#
.SYNOPSIS
Merges local-only test result files into combined CSV and JSON reports.

.DESCRIPTION
Searches a result root folder recursively for test-results.csv files created by the local-only test scripts,
imports them, and creates combined CSV and JSON reports. This script does not use PowerShell remoting.

.NOTES
File Name     : 06-Merge-LocalResults.ps1
Version       : v0.1.0
Created       : 2026-06-25
Last Modified : 2026-06-25
Author        : Nouramon Alvestrasza
Organization  : Alvestrasza Corporation
#>

param(
    [string]$ResultRoot = "D:\CustomerTests\Server2025",
    [string]$OutputPath = "D:\CustomerTests\Server2025\CombinedResults"
)

Set-StrictMode -Version Latest

New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$csvOut = Join-Path $OutputPath "combined-test-results-$timestamp.csv"
$jsonOut = Join-Path $OutputPath "combined-test-results-$timestamp.json"

$resultFiles = Get-ChildItem -Path $ResultRoot -Recurse -Filter "test-results.csv" -ErrorAction Stop

if (($resultFiles | Measure-Object).Count -eq 0) {
    throw "No test-results.csv files were found under $ResultRoot."
}

$combined = foreach ($file in $resultFiles) {
    Import-Csv -Path $file.FullName | ForEach-Object {
        $_ | Add-Member -NotePropertyName SourceFile -NotePropertyValue $file.FullName -Force
        $_ | Add-Member -NotePropertyName SourceFolder -NotePropertyValue $file.DirectoryName -Force
        $_
    }
}

$combined | Sort-Object ComputerName, Timestamp, Area, TestCase | Export-Csv -Path $csvOut -NoTypeInformation -Encoding UTF8
$combined | Sort-Object ComputerName, Timestamp, Area, TestCase | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonOut -Encoding UTF8

Write-Host "Combined CSV : $csvOut" -ForegroundColor Cyan
Write-Host "Combined JSON: $jsonOut" -ForegroundColor Cyan
