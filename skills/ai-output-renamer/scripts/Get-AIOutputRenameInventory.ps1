[CmdletBinding()]
param([string]$LibraryRoot = $env:AI_OUTPUT_LIBRARY_ROOT, [string]$OutputPath, [switch]$All)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { throw '请使用 -LibraryRoot 或 AI_OUTPUT_LIBRARY_ROOT 指定副本库。' }
Import-Module (Join-Path $PSScriptRoot 'AIOutputCenter.Common.psm1') -Force
$LibraryRoot = Resolve-AIOLibraryRoot -LibraryRoot $LibraryRoot
$config = Get-AIOConfig -LibraryRoot $LibraryRoot
$records = Get-AIORecords -LibraryRoot $LibraryRoot -Config $config
$selected = if ($All) { @($records) } else { @($records | Where-Object { [int]$_.NamingRevision -lt [int]$config.NamingRevision }) }
$inventory = $selected | ForEach-Object {
    [pscustomobject]@{
        Hash = $_.Hash; CurrentFileName = $_.FileName; OriginalFileName = $_.OriginalFileName
        CurrentPath = $_.LibraryPath; TopicKey = $_.TopicKey; KindKey = $_.KindKey
        SourceApp = $_.SourceApp; SourcePaths = @($_.SourcePaths); SizeBytes = $_.SizeBytes
        SourceLastWrite = $_.SourceLastWrite; Quarantined = $_.Quarantined
    }
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-output-rename-inventory-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.json') }
$OutputPath = Get-AIONormalizedPath -Path $OutputPath
if (Test-AIOPathWithinRoot -Root $LibraryRoot -Path $OutputPath) { throw '清单输出不得写入副本库。' }
if (Test-Path -LiteralPath $OutputPath) { throw "清单输出已存在，拒绝覆盖：$OutputPath" }
foreach ($record in $records) {
    foreach ($sourcePath in @($record.SourcePaths)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$sourcePath) -and
            [string]::Equals((Get-AIONormalizedPath -Path ([string]$sourcePath)), $OutputPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw '清单输出不得覆盖索引中的源文件。'
        }
    }
}
Write-AIOAtomicJson -Path $OutputPath -Value @($inventory)
Write-Output $OutputPath
