$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $scriptsRoot 'AIOutputCenter.Common.psm1'
$inventoryScript = Join-Path $scriptsRoot 'Get-AIOutputRenameInventory.ps1'
$applyScript = Join-Path $scriptsRoot 'Apply-AIOutputRenamePlan.ps1'
$undoScript = Join-Path $scriptsRoot 'Undo-LastAIOutputRename.ps1'
Import-Module $modulePath -Force

$testParent = Join-Path ([System.IO.Path]::GetTempPath()) 'ai-output-renamer-transaction-tests'
if (-not (Test-Path -LiteralPath $testParent)) { New-Item -ItemType Directory -Path $testParent | Out-Null }
$testRoot = New-AIOOwnedTemporaryDirectory -ControlledRoot $testParent -TransactionId ('test_' + [guid]::NewGuid().ToString('N'))

try {
    $libraryRoot = Join-Path $testRoot 'library'
    $systemDir = Join-Path $libraryRoot '_系统与索引'
    $sourceDir = Join-Path $testRoot 'source'
    $originalDir = Join-Path $libraryRoot 'Codex产出\其他主题\文档'
    New-Item -ItemType Directory -Path $systemDir, $sourceDir, $originalDir -Force | Out-Null

    $sourcePath = Join-Path $sourceDir 'source.txt'
    $copyPath = Join-Path $originalDir 'copy.txt'
    $sourcePath2 = Join-Path $sourceDir 'source-2.txt'
    $copyPath2 = Join-Path $originalDir 'copy-2.txt'
    Set-Content -LiteralPath $sourcePath -Value 'synthetic source content' -Encoding UTF8
    Set-Content -LiteralPath $sourcePath2 -Value 'different synthetic source content' -Encoding UTF8
    Copy-Item -LiteralPath $sourcePath -Destination $copyPath
    Copy-Item -LiteralPath $sourcePath2 -Destination $copyPath2
    $sourceHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    $copyHash = (Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash
    $sourceHash2 = (Get-FileHash -LiteralPath $sourcePath2 -Algorithm SHA256).Hash
    $copyHash2 = (Get-FileHash -LiteralPath $copyPath2 -Algorithm SHA256).Hash
    if ($sourceHash -cne $copyHash) { throw 'Synthetic source and copy hashes differ before the test.' }
    if ($sourceHash2 -cne $copyHash2 -or $copyHash2 -ceq $copyHash) { throw 'Second synthetic pair is not distinct and internally identical.' }

    $config = Get-AIODefaultConfig
    Write-AIOAtomicJson -Path (Join-Path $systemDir '文件夹配置.json') -Value $config
    $record = [pscustomobject]@{
        Hash = $copyHash; FileName = 'copy.txt'; OriginalFileName = 'source.txt'; DisplayName = 'copy.txt'
        Topic = '其他主题'; Kind = '文档'; TopicKey = 'other'; KindKey = 'documents'
        CollectionName = '其他主题'; NamingRevision = 0; RenamedAt = $null; Quarantined = $false
        LastRenameTransaction = $null; SourceApp = 'Codex'; SourceApps = @('Codex')
        SourceInstances = @('Codex / synthetic'); SourcePaths = @($sourcePath)
        SizeBytes = (Get-Item -LiteralPath $copyPath).Length; SourceLastWrite = (Get-Item -LiteralPath $sourcePath).LastWriteTime.ToString('o')
        FirstSeen = (Get-Date).ToString('o'); LastSeen = (Get-Date).ToString('o'); LibraryPath = $copyPath
    }
    $record2 = [pscustomobject]@{
        Hash = $copyHash2; FileName = 'copy-2.txt'; OriginalFileName = 'source-2.txt'; DisplayName = 'copy-2.txt'
        Topic = '其他主题'; Kind = '文档'; TopicKey = 'other'; KindKey = 'documents'
        CollectionName = '其他主题'; NamingRevision = 0; RenamedAt = $null; Quarantined = $false
        LastRenameTransaction = $null; SourceApp = 'Codex'; SourceApps = @('Codex')
        SourceInstances = @('Codex / synthetic-2'); SourcePaths = @($sourcePath2)
        SizeBytes = (Get-Item -LiteralPath $copyPath2).Length; SourceLastWrite = (Get-Item -LiteralPath $sourcePath2).LastWriteTime.ToString('o')
        FirstSeen = (Get-Date).ToString('o'); LastSeen = (Get-Date).ToString('o'); LibraryPath = $copyPath2
    }
    Save-AIOIndexes -LibraryRoot $libraryRoot -Records @($record, $record2)

    $configPath = Join-Path $systemDir '文件夹配置.json'
    $configHashBefore = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    $inventoryPath = Join-Path $testRoot 'inventory.json'
    & $inventoryScript -LibraryRoot $libraryRoot -OutputPath $inventoryPath | Out-Null
    $configHashAfter = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    if ($configHashBefore -cne $configHashAfter) { throw 'Read-only inventory changed the folder configuration.' }
    $inventoryHash = (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash
    $inventoryOverwriteBlocked = $false
    try { & $inventoryScript -LibraryRoot $libraryRoot -OutputPath $inventoryPath | Out-Null }
    catch { $inventoryOverwriteBlocked = $_.Exception.Message -like '*拒绝覆盖*' }
    if (-not $inventoryOverwriteBlocked -or (Get-FileHash -LiteralPath $inventoryPath -Algorithm SHA256).Hash -cne $inventoryHash) {
        throw 'Inventory overwrite was not blocked without changing the existing file.'
    }

    $emptyLibrary = Join-Path $testRoot 'empty-library'
    $emptySystem = Join-Path $emptyLibrary '_系统与索引'
    New-Item -ItemType Directory -Path $emptySystem -Force | Out-Null
    Write-AIOAtomicJson -Path (Join-Path $emptySystem '文件索引.json') -Value @()
    & $inventoryScript -LibraryRoot $emptyLibrary -OutputPath (Join-Path $testRoot 'empty-inventory.json') | Out-Null
    if (Test-Path -LiteralPath (Join-Path $emptySystem '文件夹配置.json')) { throw 'Read-only inventory created a configuration file.' }

    $recentDir = Join-Path $libraryRoot '00_最近新增'
    New-Item -ItemType Directory -Path $recentDir | Out-Null
    $unownedShortcut = Join-Path $recentDir 'keep.lnk'
    Set-Content -LiteralPath $unownedShortcut -Value 'not an owned shortcut' -Encoding UTF8
    Remove-Item -LiteralPath $configPath -Force

    $planPath = Join-Path $testRoot 'plan.json'
    $plan = [pscustomobject]@{
        schemaVersion = 1; namingRevision = 1; folderNames = @()
        items = @(
            [pscustomobject]@{
                hash = $copyHash; newFileName = '中文语义副本.txt'; newTopicKey = 'tools'
                newKindKey = 'documents'; quarantine = $false; reason = 'synthetic test'
            },
            [pscustomobject]@{
                hash = $copyHash2; newFileName = '中文语义副本.txt'; newTopicKey = 'tools'
                newKindKey = 'documents'; quarantine = $false; reason = 'collision test'
            }
        )
    }
    Write-AIOAtomicJson -Path $planPath -Value $plan
    & $applyScript -PlanPath $planPath -LibraryRoot $libraryRoot | Out-Null

    $renamedPath = Join-Path $libraryRoot 'Codex产出\AI工具与系统维护资料\文档\中文语义副本.txt'
    $renamedPath2 = Join-Path $libraryRoot ('Codex产出\AI工具与系统维护资料\文档\中文语义副本（' + $copyHash2.Substring(0,8) + '）.txt')
    if (-not (Test-Path -LiteralPath $renamedPath -PathType Leaf)) { throw 'Renamed copy was not created at the expected managed path.' }
    if (-not (Test-Path -LiteralPath $renamedPath2 -PathType Leaf)) { throw 'Same-name different-content copy did not receive a collision-safe hash suffix.' }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) { throw 'Source file was moved or removed.' }
    if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Source file content changed.' }
    if ((Get-FileHash -LiteralPath $sourcePath2 -Algorithm SHA256).Hash -cne $sourceHash2) { throw 'Second source file content changed.' }
    if (-not (Test-Path -LiteralPath $unownedShortcut -PathType Leaf)) { throw 'Unowned legacy shortcut was deleted.' }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'Successful apply did not persist its effective configuration.' }
    $afterApply = @(Get-AIORecords -LibraryRoot $libraryRoot -Config (Get-AIOConfig -LibraryRoot $libraryRoot))
    $afterByHash = @{}; foreach ($item in $afterApply) { $afterByHash[$item.Hash] = $item }
    if (@($afterByHash[$copyHash].SourcePaths).Count -ne 1 -or [string]$afterByHash[$copyHash].SourcePaths[0] -cne $sourcePath -or
        @($afterByHash[$copyHash2].SourcePaths).Count -ne 1 -or [string]$afterByHash[$copyHash2].SourcePaths[0] -cne $sourcePath2) {
        throw 'Source provenance changed during rename.'
    }

    & $undoScript -LibraryRoot $libraryRoot | Out-Null
    if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) { throw 'Undo did not restore the original copy path.' }
    if (-not (Test-Path -LiteralPath $copyPath2 -PathType Leaf)) { throw 'Undo did not restore the second copy path.' }
    if ((Get-FileHash -LiteralPath $copyPath -Algorithm SHA256).Hash -cne $copyHash) { throw 'Undo changed copy content.' }
    if ((Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Undo changed source content.' }
    if ((Get-FileHash -LiteralPath $sourcePath2 -Algorithm SHA256).Hash -cne $sourceHash2) { throw 'Undo changed second source content.' }
    if (Test-Path -LiteralPath $configPath) { throw 'Undo did not restore the original no-configuration state.' }

    $badPlanPath = Join-Path $testRoot 'bad-plan.json'
    $badPlan = [pscustomobject]@{
        schemaVersion = 1; namingRevision = 1; folderNames = @()
        items = @([pscustomobject]@{
            hash = $copyHash; newFileName = '..\escape.txt'; newTopicKey = 'tools'
            newKindKey = 'documents'; quarantine = $false; reason = 'must fail'
        })
    }
    Write-AIOAtomicJson -Path $badPlanPath -Value $badPlan
    $badPlanBlocked = $false
    try { & $applyScript -PlanPath $badPlanPath -LibraryRoot $libraryRoot | Out-Null }
    catch { $badPlanBlocked = $_.Exception.Message -like '*单个路径组件*' -or $_.Exception.Message -like '*非法文件名*' }
    if (-not $badPlanBlocked) { throw 'Path traversal filename was not blocked.' }
    if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) { throw 'Rejected plan changed the managed copy.' }
    if (Test-Path -LiteralPath $configPath) { throw 'Rejected plan created a configuration file.' }
    if (Test-Path -LiteralPath (Join-Path $systemDir '.rename-in-progress.json')) { throw 'Clean rollback left a stale transaction marker.' }
    $stageRoot = Join-Path $systemDir '重命名暂存'
    if ((Test-Path -LiteralPath $stageRoot) -and @(Get-ChildItem -LiteralPath $stageRoot -Force).Count -ne 0) {
        throw 'Clean rollback left a transaction staging directory.'
    }

    $allRecords = @(Get-AIORecords -LibraryRoot $libraryRoot -Config (Get-AIOConfig -LibraryRoot $libraryRoot))
    $singleRecord = $allRecords | Where-Object Hash -eq $copyHash | Select-Object -First 1
    Write-AIOAtomicJson -Path (Join-Path $systemDir '文件索引.json') -Value @($singleRecord, $singleRecord)
    $duplicateBlocked = $false
    try { & $applyScript -PlanPath $planPath -LibraryRoot $libraryRoot | Out-Null }
    catch { $duplicateBlocked = $_.Exception.Message -like '*重复 SHA-256*' }
    if (-not $duplicateBlocked) { throw 'Duplicate index hashes were not blocked.' }
    Save-AIOIndexes -LibraryRoot $libraryRoot -Records $allRecords

    Write-Output 'PASS: read-only inventory, collision-safe rename/undo, source preservation, unsafe plan and duplicate-hash rejection'
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $testParent -Path $testRoot }
    if ((Test-Path -LiteralPath $testParent -PathType Container) -and @(Get-ChildItem -LiteralPath $testParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $testParent -Force
    }
}
