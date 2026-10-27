Set-StrictMode -Version 2.0

function Set-AIOProperty {
    param([object]$Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties.Name -contains $Name) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Write-AIOAtomicText {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Assert-AIOPathChainNotReparse -Path $parent
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "拒绝覆盖符号链接、联接点或其他重解析点：$Path"
    }
    $existingAttributes = if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-Item -LiteralPath $Path -Force).Attributes } else { $null }
    $temp = Join-Path $parent ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
    Set-Content -LiteralPath $temp -Value $Content -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
    if ($null -ne $existingAttributes) { (Get-Item -LiteralPath $Path -Force).Attributes = $existingAttributes }
}

function Write-AIOAtomicJson {
    param([string]$Path, $Value, [int]$Depth = 10)
    # -InputObject preserves an empty array as [] instead of writing an empty, invalid JSON file.
    Write-AIOAtomicText -Path $Path -Content (ConvertTo-Json -InputObject $Value -Depth $Depth)
}

function Get-AIODefaultConfig {
    [pscustomobject]@{
        SchemaVersion = 2; NamingRevision = 1; RecentDays = 14
        Topics = @(
            [pscustomobject]@{ Key = 'research'; Name = '研究资料' },
            [pscustomobject]@{ Key = 'study'; Name = '学习与课程' },
            [pscustomobject]@{ Key = 'work'; Name = '工作项目' },
            [pscustomobject]@{ Key = 'design'; Name = '设计与创作' },
            [pscustomobject]@{ Key = 'tools'; Name = 'AI工具与系统维护资料' },
            [pscustomobject]@{ Key = 'personal'; Name = '个人与生活' },
            [pscustomobject]@{ Key = 'other'; Name = '其他主题' }
        )
        Kinds = @(
            [pscustomobject]@{ Key = 'documents'; Name = '文档' },
            [pscustomobject]@{ Key = 'spreadsheets'; Name = '表格' },
            [pscustomobject]@{ Key = 'presentations'; Name = '演示文稿' },
            [pscustomobject]@{ Key = 'images'; Name = '图片' },
            [pscustomobject]@{ Key = 'media'; Name = '音视频' },
            [pscustomobject]@{ Key = 'code_data'; Name = '脚本与数据' },
            [pscustomobject]@{ Key = 'archives'; Name = '压缩包' },
            [pscustomobject]@{ Key = 'other'; Name = '其他文件' }
        )
    }
}

function Get-AIOConfig {
    param([string]$LibraryRoot, [switch]$Create)
    $path = Join-Path $LibraryRoot '_系统与索引\文件夹配置.json'
    if (Test-Path -LiteralPath $path) {
        Assert-AIOPathChainNotReparse -Path $path
        $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $legacyTopics = @($config.Topics | Where-Object { $_.Key -eq 'unclassified' -or $_.Name -eq '待分类' })
        if ($legacyTopics.Count -gt 0) {
            $config.Topics = @($config.Topics | Where-Object { $_.Key -ne 'unclassified' -and $_.Name -ne '待分类' })
            if ($Create) { Write-AIOAtomicJson -Path $path -Value $config }
        }
        return $config
    }
    $config = Get-AIODefaultConfig
    if ($Create) { Write-AIOAtomicJson -Path $path -Value $config }
    return $config
}

function Get-AIONormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '路径不能为空。' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $pathRoot }
    return $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Assert-AIOPathChainNotReparse {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = Get-AIONormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $full)) { throw "路径不存在：$full" }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    while ($null -ne $item) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "路径链包含符号链接、联接点或其他重解析点：$($item.FullName)"
        }
        $item = if ($item -is [System.IO.DirectoryInfo]) { $item.Parent } else { $item.Directory }
    }
}

function Resolve-AIOLibraryRoot {
    param([Parameter(Mandatory = $true)][string]$LibraryRoot)
    $full = Get-AIONormalizedPath -Path $LibraryRoot
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    if ([string]::Equals($full, $volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "副本库不能是卷根目录：$full"
    }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "找不到 AI 输出副本库：$full" }
    Assert-AIOPathChainNotReparse -Path $full
    $systemDir = Join-Path $full '_系统与索引'
    $indexPath = Join-Path $systemDir '文件索引.json'
    if (-not (Test-Path -LiteralPath $systemDir -PathType Container) -or -not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw "指定目录缺少 _系统与索引\文件索引.json，不能证明它是 AI 输出副本库：$full"
    }
    Assert-AIOPathChainNotReparse -Path $systemDir
    Assert-AIOPathChainNotReparse -Path $indexPath
    return $full
}

function Assert-AIOSafeLeafName {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Label = '名称')
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -in @('.', '..')) { throw "$Label 不能为空或使用点路径。" }
    if ($Name -ne $Name.TrimEnd(' ', '.')) { throw "$Label 不能以空格或点结尾：$Name" }
    if ($Name -match '[\x00-\x1f<>:"/\\|?*]') { throw "非法$Label：$Name" }
    if ([System.IO.Path]::GetFileName($Name) -cne $Name) { throw "$Label 必须是单个路径组件：$Name" }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    if ($stem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw "$Label 使用了 Windows 保留名称：$Name" }
}

function Get-AIOMapName {
    param($Config, [ValidateSet('Topic','Kind')] [string]$Scope, [string]$Key)
    $collection = if ($Scope -eq 'Topic') { @($Config.Topics) } else { @($Config.Kinds) }
    $match = $collection | Where-Object { $_.Key -eq $Key } | Select-Object -First 1
    if ($null -eq $match) { throw "未知的 $Scope 键：$Key" }
    $name = [string]$match.Name
    Assert-AIOSafeLeafName -Name $name -Label "$Scope 文件夹名"
    return $name
}

function ConvertTo-AIOTopicKey {
    param([string]$Name)
    switch ($Name) {
        '研究资料' { 'research' }
        '学习与课程' { 'study' }
        '工作项目' { 'work' }
        '图片与设计' { 'design' }
        '设计与创作' { 'design' }
        '工具与脚本' { 'tools' }
        'AI工具与自动化脚本' { 'tools' }
        'AI工具与系统维护资料' { 'tools' }
        '家庭与生活' { 'personal' }
        '个人与生活' { 'personal' }
        '其他主题' { 'other' }
        '待分类' { 'other' }
        default { 'other' }
    }
}

function ConvertTo-AIOKindKey {
    param([string]$Name)
    switch ($Name) {
        '文档' { 'documents' }
        '表格' { 'spreadsheets' }
        '演示文稿' { 'presentations' }
        '图片' { 'images' }
        '音视频' { 'media' }
        '代码与数据' { 'code_data' }
        '脚本与数据' { 'code_data' }
        '压缩包' { 'archives' }
        default { 'other' }
    }
}

function ConvertTo-AIORecordV2 {
    param($Record, $Config)
    if (-not ($Record.PSObject.Properties.Name -contains 'OriginalFileName')) {
        $original = $Record.FileName
        if ($Record.PSObject.Properties.Name -contains 'SourcePaths' -and @($Record.SourcePaths).Count -gt 0) { $original = Split-Path -Leaf @($Record.SourcePaths)[0] }
        Set-AIOProperty $Record 'OriginalFileName' $original
    }
    if (-not ($Record.PSObject.Properties.Name -contains 'DisplayName')) { Set-AIOProperty $Record 'DisplayName' $Record.FileName }
    if (-not ($Record.PSObject.Properties.Name -contains 'TopicKey')) { Set-AIOProperty $Record 'TopicKey' (ConvertTo-AIOTopicKey $Record.Topic) }
    elseif ($Record.TopicKey -eq 'unclassified') { Set-AIOProperty $Record 'TopicKey' 'other' }
    if ($Record.Topic -eq '待分类') { Set-AIOProperty $Record 'Topic' (Get-AIOMapName -Config $Config -Scope Topic -Key 'other') }
    if (-not ($Record.PSObject.Properties.Name -contains 'KindKey')) { Set-AIOProperty $Record 'KindKey' (ConvertTo-AIOKindKey $Record.Kind) }
    if (-not ($Record.PSObject.Properties.Name -contains 'NamingRevision')) { Set-AIOProperty $Record 'NamingRevision' 0 }
    if (-not ($Record.PSObject.Properties.Name -contains 'RenamedAt')) { Set-AIOProperty $Record 'RenamedAt' $null }
    if (-not ($Record.PSObject.Properties.Name -contains 'Quarantined')) { Set-AIOProperty $Record 'Quarantined' $false }
    if (-not ($Record.PSObject.Properties.Name -contains 'LastRenameTransaction')) { Set-AIOProperty $Record 'LastRenameTransaction' $null }
    if (-not ($Record.PSObject.Properties.Name -contains 'SourcePaths')) { Set-AIOProperty $Record 'SourcePaths' @() }
    if (-not ($Record.PSObject.Properties.Name -contains 'SourceApp')) { Set-AIOProperty $Record 'SourceApp' '' }
    if (-not ($Record.PSObject.Properties.Name -contains 'SourceApps')) {
        $legacySources = if ([string]::IsNullOrWhiteSpace([string]$Record.SourceApp)) { @() } else { @([string]$Record.SourceApp) }
        Set-AIOProperty $Record 'SourceApps' $legacySources
    }
    if (-not ($Record.PSObject.Properties.Name -contains 'SourceInstances')) { Set-AIOProperty $Record 'SourceInstances' @() }
    if (-not ($Record.PSObject.Properties.Name -contains 'CollectionName')) { Set-AIOProperty $Record 'CollectionName' ([string]$Record.Topic) }
    $Record.SourceApps = @(@($Record.SourceApps) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    $Record.SourceInstances = @(@($Record.SourceInstances) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if (@($Record.SourceApps).Count -gt 0) { $Record.SourceApp = [string]@($Record.SourceApps)[0] }
    return $Record
}

function Get-AIORecords {
    param([string]$LibraryRoot, $Config)
    $path = Join-Path $LibraryRoot '_系统与索引\文件索引.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $loaded = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $records = @()
    foreach ($record in @($loaded)) { $records += (ConvertTo-AIORecordV2 -Record $record -Config $Config) }
    return @($records)
}

function Save-AIOIndexes {
    param([string]$LibraryRoot, [object[]]$Records)
    $systemDir = Join-Path $LibraryRoot '_系统与索引'
    $jsonPath = Join-Path $systemDir '文件索引.json'
    $csvPath = Join-Path $systemDir '文件索引.csv'
    $ordered = @($Records | Sort-Object Topic, Kind, FileName)
    Write-AIOAtomicJson -Path $jsonPath -Value $ordered
    $rows = $ordered | ForEach-Object {
        [pscustomobject]@{
            文件名 = $_.FileName; 原始文件名 = $_.OriginalFileName; 一级入口 = $(if (@($_.SourceApps) -contains 'Hermes') { 'Hermes产出' } else { 'Codex产出' }); 内部分类 = $_.CollectionName; 主题 = $_.Topic; 类型 = $_.Kind
            来源 = (@($_.SourceApps) -join ' | '); 来源实例 = (@($_.SourceInstances) -join ' | ')
            命名版本 = $_.NamingRevision; 已隔离 = $_.Quarantined
            首次收录时间 = $_.FirstSeen; 最后发现时间 = $_.LastSeen; 重命名时间 = $_.RenamedAt
            大小字节 = $_.SizeBytes; SHA256 = $_.Hash; 集中存放路径 = $_.LibraryPath
            原始路径 = (@($_.SourcePaths) -join ' | ')
        }
    }
    $temp = Join-Path $systemDir ('.' + [guid]::NewGuid().ToString('N') + '.csv')
    $rows | Export-Csv -LiteralPath $temp -NoTypeInformation -Encoding UTF8
    if ((Test-Path -LiteralPath $csvPath) -and ((Get-Item -LiteralPath $csvPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        throw "拒绝覆盖符号链接、联接点或其他重解析点：$csvPath"
    }
    Move-Item -LiteralPath $temp -Destination $csvPath -Force
}

function Get-AIOStorageDirectory {
    param([string]$LibraryRoot, $Record, $Config, [string]$TopicKey, [string]$KindKey)
    $topicName = Get-AIOMapName -Config $Config -Scope Topic -Key $TopicKey
    $kindName = Get-AIOMapName -Config $Config -Scope Kind -Key $KindKey
    $sourceApps = @($Record.SourceApps)
    if ($sourceApps -contains 'Hermes') {
        $collectionName = if ([string]::IsNullOrWhiteSpace([string]$Record.CollectionName)) { $topicName } else { [string]$Record.CollectionName }
        Assert-AIOSafeLeafName -Name $collectionName -Label '集合文件夹名'
        return (Join-Path (Join-Path (Join-Path $LibraryRoot 'Hermes产出') $collectionName) $kindName)
    }
    if ($sourceApps -contains 'Codex') {
        return (Join-Path (Join-Path (Join-Path $LibraryRoot 'Codex产出') $topicName) $kindName)
    }
    $sourceName = if ($sourceApps.Count -gt 0) { [string]$sourceApps[0] } else { '未知来源' }
    Assert-AIOSafeLeafName -Name $sourceName -Label '来源文件夹名'
    return (Join-Path (Join-Path (Join-Path (Join-Path (Join-Path $LibraryRoot 'Codex产出') '其他AI导入') $sourceName) $topicName) $kindName)
}

function Remove-AIORecentShortcuts {
    param([string]$LibraryRoot)
    $recentDir = Join-Path $LibraryRoot '00_最近新增'
    if (-not (Test-Path -LiteralPath $recentDir -PathType Container)) { return 0 }
    Assert-AIOPathChainNotReparse -Path $recentDir
    $legacyMarker = Join-Path $recentDir '_此目录由AI输出中心自动管理.txt'
    if (-not (Test-Path -LiteralPath $legacyMarker -PathType Leaf)) { return 0 }
    Assert-AIONotReparsePoint -Path $legacyMarker
    $shortcuts = @(Get-ChildItem -LiteralPath $recentDir -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    foreach ($shortcut in $shortcuts) {
        Remove-Item -LiteralPath $shortcut.FullName -Force
    }
    Remove-Item -LiteralPath $legacyMarker -Force
    if (@(Get-ChildItem -LiteralPath $recentDir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $recentDir -Force
    }
    return $shortcuts.Count
}

function Test-AIOPathWithinRoot {
    param([string]$Root, [string]$Path)
    $rootFull = (Get-AIONormalizedPath -Path $Root).TrimEnd('\') + '\'
    $pathFull = Get-AIONormalizedPath -Path $Path
    return $pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-AIOManagedPath {
    param([string]$LibraryRoot, [string]$Path, [switch]$AllowQuarantine)
    if (-not (Test-AIOPathWithinRoot -Root $LibraryRoot -Path $Path)) { return $false }
    $systemDir = Join-Path $LibraryRoot '_系统与索引'
    if (-not (Test-AIOPathWithinRoot -Root $systemDir -Path $Path)) { return $true }
    if (-not $AllowQuarantine) { return $false }
    $quarantineRoot = Get-AIONormalizedPath -Path (Join-Path $systemDir '隔离区')
    $pathFull = Get-AIONormalizedPath -Path $Path
    return (
        [string]::Equals($quarantineRoot, $pathFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        (Test-AIOPathWithinRoot -Root $quarantineRoot -Path $pathFull)
    )
}

function Assert-AIONotReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "受控暂存路径不能是符号链接、联接点或其他重解析点：$Path"
    }
}

function New-AIOOwnedTemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ControlledRoot,
        [Parameter(Mandatory = $true)][string]$TransactionId
    )
    if ($TransactionId -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') {
        throw '暂存事务标识只能包含字母、数字、点、下划线和连字符。'
    }
    $rootFull = Get-AIONormalizedPath -Path $ControlledRoot
    if (-not (Test-Path -LiteralPath $rootFull)) {
        New-Item -ItemType Directory -Path $rootFull -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "受控暂存根目录无效：$rootFull"
    }
    Assert-AIOPathChainNotReparse -Path $rootFull
    $targetFull = [System.IO.Path]::GetFullPath((Join-Path $rootFull $TransactionId))
    if (-not (Test-AIOPathWithinRoot -Root $rootFull -Path $targetFull)) {
        throw "暂存目录越出受控根目录：$targetFull"
    }
    if (Test-Path -LiteralPath $targetFull) {
        throw "暂存目录已存在，拒绝复用：$targetFull"
    }
    New-Item -ItemType Directory -Path $targetFull | Out-Null
    try {
        Write-AIOAtomicJson -Path (Join-Path $targetFull '.ai-output-renamer-owned-temp.json') -Value ([pscustomobject]@{
            Schema = 'ai-output-renamer-owned-temp-v1'
            Owner = 'ai-output-renamer'
            ControlledRoot = $rootFull
            Directory = $targetFull
            TransactionId = $TransactionId
        })
    }
    catch {
        Remove-Item -LiteralPath $targetFull -Force -ErrorAction SilentlyContinue
        throw
    }
    return $targetFull
}

function Remove-AIOOwnedTemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$ControlledRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rootFull = Get-AIONormalizedPath -Path $ControlledRoot
    $targetFull = Get-AIONormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $targetFull)) { return }
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) {
        throw "受控暂存根目录不存在：$rootFull"
    }
    Assert-AIOPathChainNotReparse -Path $rootFull
    if (-not (Test-AIOPathWithinRoot -Root $rootFull -Path $targetFull)) {
        throw "拒绝删除受控暂存根目录之外的路径：$targetFull"
    }
    $targetParent = [System.IO.Path]::GetDirectoryName($targetFull)
    if (-not [string]::Equals($targetParent, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "只允许删除受控暂存根目录的直接子目录：$targetFull"
    }
    if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) {
        throw "受控暂存目标不是目录：$targetFull"
    }
    Assert-AIONotReparsePoint -Path $targetFull
    $markerPath = Join-Path $targetFull '.ai-output-renamer-owned-temp.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw "暂存目录缺少所有权标记，拒绝递归删除：$targetFull"
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (
        [string]$marker.Schema -cne 'ai-output-renamer-owned-temp-v1' -or
        [string]$marker.Owner -cne 'ai-output-renamer' -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.ControlledRoot).TrimEnd('\'), $rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([System.IO.Path]::GetFullPath([string]$marker.Directory).TrimEnd('\'), $targetFull, [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "暂存目录所有权标记不匹配，拒绝递归删除：$targetFull"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $targetFull -Force -Recurse -ErrorAction Stop)) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "暂存目录包含重解析点，拒绝递归删除：$($item.FullName)"
        }
    }
    Remove-Item -LiteralPath $targetFull -Recurse -Force
}

function Remove-AIOEmptyDirectories {
    param([string]$LibraryRoot)
    $systemDir = Join-Path $LibraryRoot '_系统与索引'
    Get-ChildItem -LiteralPath $LibraryRoot -Directory -Recurse -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            $dir = $_
            if ($dir.FullName -eq $systemDir -or $dir.FullName -like ($systemDir + '\*')) { return }
            if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return }
            if (-not (Test-AIOPathWithinRoot -Root $LibraryRoot -Path $dir.FullName)) { return }
            if (@(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction SilentlyContinue }
        }
}

Export-ModuleMember -Function *-AIO*
