[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanPath,
    [string]$LibraryRoot = $env:AI_OUTPUT_LIBRARY_ROOT
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AIOutputCenter.Common.psm1') -Force
if ([string]::IsNullOrWhiteSpace($LibraryRoot)) { throw '请使用 -LibraryRoot 或 AI_OUTPUT_LIBRARY_ROOT 指定副本库。' }

function Get-PlanValue {
    param($Object, [string]$Name, $Default)
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $Default
}

function Get-SafeTarget {
    param(
        [string]$Directory, [string]$FileName, [string]$Hash, [string]$OldPath,
        [System.Collections.Generic.HashSet[string]]$ReservedPaths
    )
    $candidate = Join-Path $Directory $FileName
    $ext = [System.IO.Path]::GetExtension($FileName)
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $attempt = 0
    while ($true) {
        $reserved = $null -ne $ReservedPaths -and $ReservedPaths.Contains($candidate)
        if (($candidate -ieq $OldPath -or -not (Test-Path -LiteralPath $candidate)) -and -not $reserved) {
            if ($null -ne $ReservedPaths) { [void]$ReservedPaths.Add($candidate) }
            return $candidate
        }
        $attempt++
        $suffix = if ($attempt -eq 1) { $Hash.Substring(0,8) } else { $Hash.Substring(0,8) + '-' + $attempt }
        $candidate = Join-Path $Directory ($stem + '（' + $suffix + '）' + $ext)
    }
}

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { throw "找不到命名计划：$PlanPath" }
$LibraryRoot = Resolve-AIOLibraryRoot -LibraryRoot $LibraryRoot
$systemDir = Join-Path $LibraryRoot '_系统与索引'
$manifestPath = Join-Path $systemDir '文件索引.json'
$configPath = Join-Path $systemDir '文件夹配置.json'
$markerPath = Join-Path $systemDir '.rename-in-progress.json'
if (Test-Path -LiteralPath $markerPath) { throw '检测到未完成的重命名事务。请先恢复或检查系统目录，刷新器不会在此状态下运行。' }

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int](Get-PlanValue $plan 'schemaVersion' 0) -ne 1) { throw '不支持的命名计划版本。' }
$items = @($plan.items)
if ($items.Count -eq 0) { Write-Output '没有需要处理的文件。'; exit 0 }
$namingRevision = [int](Get-PlanValue $plan 'namingRevision' 1)
$hashGroups = @($items | Group-Object hash | Where-Object Count -gt 1)
if ($hashGroups.Count -gt 0) { throw '命名计划包含重复哈希。' }

$mutex = New-Object System.Threading.Mutex($false, 'AIOutputCenterRefresh')
$hasMutex = $false
$moves = New-Object System.Collections.Generic.List[object]
$transactionId = (Get-Date).ToString('yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0,8)
$stageRoot = Join-Path $systemDir '重命名暂存'
$stageDir = $null
$backupDir = Join-Path $systemDir ('重命名备份\' + $transactionId)
$historyDir = Join-Path $systemDir '重命名历史'
$historyPath = Join-Path $historyDir ($transactionId + '.json')

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { throw 'AI 输出中心正在刷新或重命名，请稍后重试。' }

    $stageDir = New-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -TransactionId $transactionId
    foreach ($dir in @($backupDir, $historyDir, (Join-Path $systemDir '隔离区'))) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    foreach ($path in @($manifestPath, $configPath, (Join-Path $systemDir '文件索引.csv'))) {
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backupDir -Force }
    }

    $configExistedBefore = Test-Path -LiteralPath $configPath -PathType Leaf
    $config = Get-AIOConfig -LibraryRoot $LibraryRoot
    $configBefore = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    foreach ($folderChange in @((Get-PlanValue $plan 'folderNames' @()))) {
        $scope = [string]$folderChange.scope
        $key = [string]$folderChange.key
        $newName = [string]$folderChange.newName
        Assert-AIOSafeLeafName -Name $newName -Label '文件夹名'
        $collection = if ($scope -eq 'topic') { @($config.Topics) } elseif ($scope -eq 'kind') { @($config.Kinds) } else { throw "未知文件夹范围：$scope" }
        $entry = $collection | Where-Object Key -eq $key | Select-Object -First 1
        if ($null -eq $entry) { throw "找不到文件夹键：$key" }
        $entry.Name = $newName
    }

    $records = Get-AIORecords -LibraryRoot $LibraryRoot -Config $config
    $duplicateRecordHashes = @($records | Group-Object Hash | Where-Object Count -gt 1)
    if ($duplicateRecordHashes.Count -gt 0) { throw '文件索引包含重复 SHA-256，拒绝选择其中任意一条。' }
    $byHash = @{}
    foreach ($record in $records) { $byHash[$record.Hash] = $record }
    $reservedTargets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    Write-AIOAtomicJson -Path $markerPath -Value ([pscustomobject]@{
        TransactionId = $transactionId; StartedAt = (Get-Date).ToString('o'); StageDir = $stageDir; BackupDir = $backupDir
    })

    foreach ($item in $items) {
        $hash = ([string]$item.hash).ToUpperInvariant()
        if ($hash -notmatch '^[A-F0-9]{64}$') { throw "计划哈希格式无效：$hash" }
        if (-not $byHash.ContainsKey($hash)) { throw "索引中找不到哈希：$hash" }
        $record = $byHash[$hash]
        $oldPath = [string]$record.LibraryPath
        if (-not (Test-AIOManagedPath -LibraryRoot $LibraryRoot -Path $oldPath -AllowQuarantine)) { throw "当前路径不属于受管副本区域：$oldPath" }
        if (-not (Test-Path -LiteralPath $oldPath -PathType Leaf)) { throw "集中副本不存在：$oldPath" }
        Assert-AIOPathChainNotReparse -Path $oldPath
        if ((Get-FileHash -LiteralPath $oldPath -Algorithm SHA256).Hash -ne $hash) { throw "集中副本哈希不一致：$oldPath" }

        $quarantine = [bool](Get-PlanValue $item 'quarantine' $false)
        $newName = [string](Get-PlanValue $item 'newFileName' $record.FileName)
        $topicKey = [string](Get-PlanValue $item 'newTopicKey' $record.TopicKey)
        $kindKey = [string](Get-PlanValue $item 'newKindKey' $record.KindKey)
        Assert-AIOSafeLeafName -Name $newName -Label '文件名'
        if ([System.IO.Path]::GetExtension($newName) -ine [System.IO.Path]::GetExtension($oldPath)) { throw "禁止改变扩展名：$oldPath -> $newName" }

        if ($quarantine) {
            $targetDirectory = Join-Path $systemDir '隔离区'
        }
        else {
            $topicName = Get-AIOMapName -Config $config -Scope Topic -Key $topicKey
            $targetDirectory = Get-AIOStorageDirectory -LibraryRoot $LibraryRoot -Record $record -Config $config -TopicKey $topicKey -KindKey $kindKey
        }
        if (-not (Test-AIOManagedPath -LibraryRoot $LibraryRoot -Path $targetDirectory -AllowQuarantine:$quarantine)) { throw "目标目录不属于受管副本区域：$targetDirectory" }
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        Assert-AIOPathChainNotReparse -Path $targetDirectory
        $targetPath = Get-SafeTarget -Directory $targetDirectory -FileName $newName -Hash $hash -OldPath $oldPath -ReservedPaths $reservedTargets
        if (-not (Test-AIOManagedPath -LibraryRoot $LibraryRoot -Path $targetPath -AllowQuarantine:$quarantine)) { throw "目标路径不属于受管副本区域：$targetPath" }

        $oldState = [pscustomobject]@{
            FileName = $record.FileName; DisplayName = $record.DisplayName; Topic = $record.Topic; Kind = $record.Kind
            TopicKey = $record.TopicKey; KindKey = $record.KindKey; LibraryPath = $record.LibraryPath
            CollectionName = $record.CollectionName
            NamingRevision = $record.NamingRevision; RenamedAt = $record.RenamedAt
            Quarantined = $record.Quarantined; LastRenameTransaction = $record.LastRenameTransaction
        }
        $moves.Add([pscustomobject]@{
            Hash = $hash; Record = $record; Item = $item; OldPath = $oldPath; TargetPath = $targetPath
            StagePath = (Join-Path $stageDir ($hash + [System.IO.Path]::GetExtension($oldPath)))
            OldState = $oldState; MovedToStage = $false; MovedToTarget = $false; Quarantine = $quarantine
            TopicKey = $topicKey; KindKey = $kindKey
        })
    }

    foreach ($move in $moves) {
        if ($move.OldPath -ine $move.TargetPath) {
            Move-Item -LiteralPath $move.OldPath -Destination $move.StagePath
            $move.MovedToStage = $true
        }
    }
    foreach ($move in $moves) {
        if ($move.MovedToStage) {
            $targetParent = Split-Path -Parent $move.TargetPath
            if (-not (Test-Path -LiteralPath $targetParent)) { New-Item -ItemType Directory -Path $targetParent -Force | Out-Null }
            Move-Item -LiteralPath $move.StagePath -Destination $move.TargetPath
            $move.MovedToTarget = $true
        }

        $record = $move.Record
        Set-AIOProperty $record 'FileName' ([System.IO.Path]::GetFileName($move.TargetPath))
        Set-AIOProperty $record 'DisplayName' ([System.IO.Path]::GetFileName($move.TargetPath))
        Set-AIOProperty $record 'LibraryPath' $move.TargetPath
        Set-AIOProperty $record 'TopicKey' $move.TopicKey
        Set-AIOProperty $record 'KindKey' $move.KindKey
        if (-not $move.Quarantine) {
            Set-AIOProperty $record 'Topic' (Get-AIOMapName -Config $config -Scope Topic -Key $move.TopicKey)
            Set-AIOProperty $record 'Kind' (Get-AIOMapName -Config $config -Scope Kind -Key $move.KindKey)
            if (@($record.SourceApps) -notcontains 'Hermes') { Set-AIOProperty $record 'CollectionName' $record.Topic }
        }
        Set-AIOProperty $record 'NamingRevision' $namingRevision
        Set-AIOProperty $record 'RenamedAt' (Get-Date).ToString('o')
        Set-AIOProperty $record 'Quarantined' $move.Quarantine
        Set-AIOProperty $record 'LastRenameTransaction' $transactionId
        Set-AIOProperty $record 'RenameReason' ([string](Get-PlanValue $move.Item 'reason' ''))
    }

    Write-AIOAtomicJson -Path $configPath -Value $config
    Save-AIOIndexes -LibraryRoot $LibraryRoot -Records $records
    $removedShortcutCount = Remove-AIORecentShortcuts -LibraryRoot $LibraryRoot

    $journalItems = $moves | ForEach-Object {
        [pscustomobject]@{
            Hash = $_.Hash; OldState = $_.OldState
            NewState = [pscustomobject]@{
                FileName = $_.Record.FileName; DisplayName = $_.Record.DisplayName; Topic = $_.Record.Topic; Kind = $_.Record.Kind
                TopicKey = $_.Record.TopicKey; KindKey = $_.Record.KindKey; LibraryPath = $_.Record.LibraryPath
                CollectionName = $_.Record.CollectionName
                NamingRevision = $_.Record.NamingRevision; RenamedAt = $_.Record.RenamedAt
                Quarantined = $_.Record.Quarantined; LastRenameTransaction = $_.Record.LastRenameTransaction
            }
        }
    }
    $journal = [pscustomobject]@{
        TransactionId = $transactionId; CompletedAt = (Get-Date).ToString('o'); UndoneAt = $null
        ConfigExistedBefore = $configExistedBefore; ConfigBefore = $configBefore; ConfigAfter = $config
        Items = @($journalItems); RemovedShortcutCount = $removedShortcutCount
    }
    Write-AIOAtomicJson -Path $historyPath -Value $journal
    Remove-AIOEmptyDirectories -LibraryRoot $LibraryRoot
    Remove-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -Path $stageDir
    Remove-Item -LiteralPath $markerPath -Force
    Write-Output ('重命名完成：{0} 个文件；事务：{1}；已清理遗留快捷方式：{2}。' -f $moves.Count, $transactionId, $removedShortcutCount)
}
catch {
    $originalError = $_
    $rollbackErrors = New-Object System.Collections.Generic.List[string]
    foreach ($move in @($moves | Sort-Object { $_.OldPath.Length } -Descending)) {
        try {
            if ($move.MovedToTarget -and (Test-Path -LiteralPath $move.TargetPath) -and -not (Test-Path -LiteralPath $move.OldPath)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $move.OldPath) -Force | Out-Null
                Move-Item -LiteralPath $move.TargetPath -Destination $move.OldPath
            }
            elseif ($move.MovedToStage -and (Test-Path -LiteralPath $move.StagePath) -and -not (Test-Path -LiteralPath $move.OldPath)) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $move.OldPath) -Force | Out-Null
                Move-Item -LiteralPath $move.StagePath -Destination $move.OldPath
            }
        } catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    foreach ($name in @('文件索引.json','文件索引.csv','文件夹配置.json')) {
        $backup = Join-Path $backupDir $name
        if (Test-Path -LiteralPath $backup) {
            try { Copy-Item -LiteralPath $backup -Destination (Join-Path $systemDir $name) -Force }
            catch { $rollbackErrors.Add($_.Exception.Message) }
        }
    }
    if ($rollbackErrors.Count -eq 0 -and $null -ne $stageDir -and (Test-Path -LiteralPath $stageDir)) {
        try { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $stageRoot -Path $stageDir }
        catch { $rollbackErrors.Add($_.Exception.Message) }
    }
    if ($rollbackErrors.Count -eq 0) {
        if (Test-Path -LiteralPath $markerPath) { Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue }
    }
    else {
        Write-Warning ('自动回滚不完整，已保留事务标记；错误：' + ($rollbackErrors -join ' | '))
    }
    throw $originalError
}
finally {
    if ($hasMutex) { try { $mutex.ReleaseMutex() } catch { } }
    $mutex.Dispose()
}
