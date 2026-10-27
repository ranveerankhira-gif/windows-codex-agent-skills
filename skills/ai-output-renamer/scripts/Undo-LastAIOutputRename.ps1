[CmdletBinding()]
param([string]$LibraryRoot = $env:AI_OUTPUT_LIBRARY_ROOT)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AIOutputCenter.Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { throw '请使用 -LibraryRoot 或 AI_OUTPUT_LIBRARY_ROOT 指定副本库。' }

$LibraryRoot = Resolve-AIOLibraryRoot -LibraryRoot $LibraryRoot
$systemDir = Join-Path $LibraryRoot '_系统与索引'
$historyDir = Join-Path $systemDir '重命名历史'
$markerPath = Join-Path $systemDir '.rename-in-progress.json'
if (Test-Path -LiteralPath $markerPath) { throw '检测到未完成的重命名事务，不能开始撤销。' }
$candidate = Get-ChildItem -LiteralPath $historyDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | ForEach-Object {
        Assert-AIOPathChainNotReparse -Path $_.FullName
        $data = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $data.UndoneAt) { [pscustomobject]@{ Path = $_.FullName; Data = $data } }
    } | Select-Object -First 1
if ($null -eq $candidate) { throw '没有可撤销的重命名事务。' }

$journal = $candidate.Data
$config = Get-AIOConfig -LibraryRoot $LibraryRoot
$records = Get-AIORecords -LibraryRoot $LibraryRoot -Config $config
$duplicateRecordHashes = @($records | Group-Object Hash | Where-Object Count -gt 1)
if ($duplicateRecordHashes.Count -gt 0) { throw '文件索引包含重复 SHA-256，拒绝选择其中任意一条。' }
$byHash = @{}; foreach ($record in $records) { $byHash[$record.Hash] = $record }
$transactionId = 'undo_' + $journal.TransactionId + '_' + (Get-Date).ToString('yyyyMMdd_HHmmss')
$stageRoot = Join-Path $systemDir '重命名暂存'
$stageDir = $null
$moves = New-Object System.Collections.Generic.List[object]
$mutex = New-Object System.Threading.Mutex($false, 'AIOutputCenterRefresh')
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { throw 'AI 输出中心正在刷新或重命名，请稍后重试。' }
    $stageDir = New-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -TransactionId $transactionId
    Write-AIOAtomicJson -Path $markerPath -Value ([pscustomobject]@{ TransactionId = $transactionId; StartedAt = (Get-Date).ToString('o'); StageDir = $stageDir })

    foreach ($item in @($journal.Items)) {
        $hash = [string]$item.Hash
        if (-not $byHash.ContainsKey($hash)) { throw "当前索引缺少待撤销记录：$hash" }
        $record = $byHash[$hash]
        $currentPath = [string]$record.LibraryPath
        $oldPath = [string]$item.OldState.LibraryPath
        if (-not (Test-AIOManagedPath -LibraryRoot $LibraryRoot -Path $currentPath -AllowQuarantine) -or
            -not (Test-AIOManagedPath -LibraryRoot $LibraryRoot -Path $oldPath -AllowQuarantine)) { throw '撤销路径不属于受管副本区域。' }
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { throw "当前副本不存在：$currentPath" }
        Assert-AIOPathChainNotReparse -Path $currentPath
        if ((Get-FileHash -LiteralPath $currentPath -Algorithm SHA256).Hash -ne $hash) { throw "当前副本哈希不一致：$currentPath" }
        if ($currentPath -ine $oldPath -and (Test-Path -LiteralPath $oldPath)) { throw "原路径已被占用：$oldPath" }
        $moves.Add([pscustomobject]@{
            Hash = $hash; Record = $record; CurrentPath = $currentPath; OldPath = $oldPath
            StagePath = (Join-Path $stageDir ($hash + [System.IO.Path]::GetExtension($currentPath)))
            OldState = $item.OldState; MovedToStage = $false; Restored = $false
        })
    }

    foreach ($move in $moves) {
        if ($move.CurrentPath -ine $move.OldPath) {
            Move-Item -LiteralPath $move.CurrentPath -Destination $move.StagePath
            $move.MovedToStage = $true
        }
    }
    foreach ($move in $moves) {
        if ($move.MovedToStage) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $move.OldPath) -Force | Out-Null
            Assert-AIOPathChainNotReparse -Path (Split-Path -Parent $move.OldPath)
            Move-Item -LiteralPath $move.StagePath -Destination $move.OldPath
            $move.Restored = $true
        }
        foreach ($property in $move.OldState.PSObject.Properties) { Set-AIOProperty $move.Record $property.Name $property.Value }
    }

    $restoredConfig = $journal.ConfigBefore
    $restoreConfigPath = Join-Path $systemDir '文件夹配置.json'
    $configExistedBefore = if ($journal.PSObject.Properties.Name -contains 'ConfigExistedBefore') { [bool]$journal.ConfigExistedBefore } else { $true }
    if ($configExistedBefore) { Write-AIOAtomicJson -Path $restoreConfigPath -Value $restoredConfig }
    elseif (Test-Path -LiteralPath $restoreConfigPath -PathType Leaf) { Remove-Item -LiteralPath $restoreConfigPath -Force }
    Save-AIOIndexes -LibraryRoot $LibraryRoot -Records $records
    [void](Remove-AIORecentShortcuts -LibraryRoot $LibraryRoot)
    Set-AIOProperty $journal 'UndoneAt' (Get-Date).ToString('o')
    Set-AIOProperty $journal 'UndoTransactionId' $transactionId
    Write-AIOAtomicJson -Path $candidate.Path -Value $journal
    Remove-AIOEmptyDirectories -LibraryRoot $LibraryRoot
    Remove-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -Path $stageDir
    Remove-Item -LiteralPath $markerPath -Force
    Write-Output ('已撤销事务 {0}，恢复 {1} 个文件。' -f $journal.TransactionId, $moves.Count)
}
catch {
    $originalError = $_
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($move in @($moves)) {
        try {
            if ($move.Restored -and (Test-Path -LiteralPath $move.OldPath) -and -not (Test-Path -LiteralPath $move.CurrentPath)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $move.CurrentPath) -Force | Out-Null
                Move-Item -LiteralPath $move.OldPath -Destination $move.CurrentPath
            }
            elseif ($move.MovedToStage -and (Test-Path -LiteralPath $move.StagePath) -and -not (Test-Path -LiteralPath $move.CurrentPath)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $move.CurrentPath) -Force | Out-Null
                Move-Item -LiteralPath $move.StagePath -Destination $move.CurrentPath
            }
        } catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    if ($rollbackErrors.Count -eq 0 -and $null -ne $stageDir -and (Test-Path -LiteralPath $stageDir)) {
        try { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -Path $stageDir }
        catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    if ($rollbackErrors.Count -eq 0) {
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
    }
    else {
        Write-Warning ('撤销操作的自动回滚不完整，已保留事务标记；错误：' + ($rollbackErrors -join ' | '))
    }
    throw $originalError
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
