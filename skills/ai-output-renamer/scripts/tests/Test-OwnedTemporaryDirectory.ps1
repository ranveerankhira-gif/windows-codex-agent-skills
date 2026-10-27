$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AIOutputCenter.Common.psm1'
Import-Module $modulePath -Force

$testParent = Join-Path ([System.IO.Path]::GetTempPath()) 'ai-output-renamer-owned-temp-tests'
if (-not (Test-Path -LiteralPath $testParent)) {
    New-Item -ItemType Directory -Path $testParent | Out-Null
}
$testId = 'test_' + [guid]::NewGuid().ToString('N')
$testRoot = New-AIOOwnedTemporaryDirectory -ControlledRoot $testParent -TransactionId $testId
$junction = $null

try {
    $controlled = Join-Path $testRoot 'controlled'
    $owned = New-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -TransactionId 'owned'
    Set-Content -LiteralPath (Join-Path $owned 'payload.txt') -Value 'synthetic' -Encoding UTF8
    Remove-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -Path $owned
    if (Test-Path -LiteralPath $owned) { throw 'Owned temporary directory was not removed.' }

    $unowned = Join-Path $controlled 'unowned'
    New-Item -ItemType Directory -Path $unowned | Out-Null
    $blockedUnowned = $false
    try { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -Path $unowned }
    catch { $blockedUnowned = $_.Exception.Message -like '*所有权标记*' }
    if (-not $blockedUnowned) { throw 'Unowned temporary directory was not blocked.' }

    $outside = Join-Path $testRoot 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $blockedOutside = $false
    try { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -Path $outside }
    catch { $blockedOutside = $_.Exception.Message -like '*之外*' }
    if (-not $blockedOutside) { throw 'Outside temporary directory was not blocked.' }

    $forged = New-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -TransactionId 'forged'
    $markerPath = Join-Path $forged '.ai-output-renamer-owned-temp.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $marker.Directory = Join-Path $controlled 'different'
    Set-Content -LiteralPath $markerPath -Value ($marker | ConvertTo-Json -Depth 5) -Encoding UTF8
    $blockedForged = $false
    try { Remove-AIOOwnedTemporaryDirectory -ControlledRoot $controlled -Path $forged }
    catch { $blockedForged = $_.Exception.Message -like '*所有权标记不匹配*' }
    if (-not $blockedForged) { throw 'Forged ownership marker was not blocked.' }

    $junctionTarget = Join-Path $testRoot 'junction-target'
    $junction = Join-Path $testRoot 'junction'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $junctionTarget | Out-Null
    $blockedJunction = $false
    try { Assert-AIOPathChainNotReparse -Path $junction }
    catch { $blockedJunction = $_.Exception.Message -like '*重解析点*' -or $_.Exception.Message -like '*联接点*' }
    if (-not $blockedJunction) { throw 'Windows junction was not blocked.' }
    Remove-Item -LiteralPath $junction -Force
    $junction = $null

    Write-Output 'PASS: owned temporary directory boundaries'
}
finally {
    if ($null -ne $junction -and (Test-Path -LiteralPath $junction)) { Remove-Item -LiteralPath $junction -Force }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-AIOOwnedTemporaryDirectory -ControlledRoot $testParent -Path $testRoot
    }
    if (
        (Test-Path -LiteralPath $testParent -PathType Container) -and
        @(Get-ChildItem -LiteralPath $testParent -Force -ErrorAction SilentlyContinue).Count -eq 0
    ) {
        Remove-Item -LiteralPath $testParent -Force
    }
}
