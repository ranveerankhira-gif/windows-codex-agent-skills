param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validator = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\validate_layout_plan.ps1'))
$pwsh = (Get-Command pwsh -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('zhuomian-zhengli-tests-' + [Guid]::NewGuid().ToString('N'))
$ownedMarker = Join-Path $tempRoot '.owned-by-zhuomian-zhengli-tests'
$createdFiles = [Collections.Generic.List[string]]::new()

function Copy-JsonObject($Value) {
    return $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
}

function Write-TestJson([string] $Name, $Value) {
    $path = Join-Path $tempRoot $Name
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
    $createdFiles.Add($path)
    return $path
}

function Invoke-ValidatorCase([string] $Name, $Plan, $Inventory, [bool] $ExpectedSuccess, [switch] $AllowLargeReflow) {
    $planPath = Write-TestJson "$Name-plan.json" $Plan
    $inventoryPath = Write-TestJson "$Name-inventory.json" $Inventory
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $validator, '-PlanPath', $planPath, '-InventoryPath', $inventoryPath, '-Mode', 'Preflight')
    if ($AllowLargeReflow) { $arguments += '-AllowLargeReflow' }
    $output = & $pwsh @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 30
    if ([bool]$result.success -ne $ExpectedSuccess) {
        throw "$Name returned success=$($result.success), expected=$ExpectedSuccess. Output: $($output -join ' ')"
    }
    if ($ExpectedSuccess -and $exitCode -ne 0) { throw "$Name exited $exitCode, expected 0." }
    if (-not $ExpectedSuccess -and $exitCode -eq 0) { throw "$Name exited 0, expected failure." }
    return $result
}

function New-Plan($Inventory) {
    return [pscustomobject]@{
        schemaVersion = 1
        inventoryCapturedAt = $Inventory.capturedAt
        grid = [pscustomobject]@{ originX=0; originY=0; spacingX=100; spacingY=100 }
        items = @($Inventory.items | ForEach-Object {
            [pscustomobject]@{ path=$_.path; x=$_.x; y=$_.y; group='example'; fixed=([bool]$_.isVirtual) }
        })
        constraints = @()
        zones = @()
    }
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    [IO.File]::WriteAllText($ownedMarker, 'owned test directory', [Text.UTF8Encoding]::new($false))

    $items = @(
        0..7 | ForEach-Object {
            [pscustomobject]@{
                path = "C:\Users\Example\Desktop\Item-$_.lnk"
                x = ($_ * 100)
                y = 0
                isDirectory = ($_ -eq 0)
                isVirtual = $false
            }
        }
    ) + @([pscustomobject]@{ path='::{00000000-0000-0000-0000-000000000001}'; x=800; y=0; isDirectory=$false; isVirtual=$true })
    $inventory = [pscustomobject]@{
        schemaVersion = 1
        capturedAt = '2030-01-01T00:00:00Z'
        metrics = [pscustomobject]@{ width=2000; height=2000; spacingX=100; spacingY=100; originX=0; originY=0; autoArrange=$false }
        items = $items
    }

    $unchanged = New-Plan $inventory
    $unchangedResult = Invoke-ValidatorCase 'unchanged' $unchanged $inventory $true
    if ($unchangedResult.movement.movedItemCount -ne 0) { throw 'Unchanged plan reported moved items.' }

    $smallMove = Copy-JsonObject $unchanged
    $smallMove.items[0].y = 100
    $smallMove.items[0] | Add-Member -NotePropertyName moveReason -NotePropertyValue 'Move one folder beside its related shortcut.'
    $smallResult = Invoke-ValidatorCase 'small-folder-move' $smallMove $inventory $true
    if ($smallResult.movement.movedFolderCount -ne 1 -or $smallResult.movement.isLargeReflow) { throw 'Small folder move budget was calculated incorrectly.' }

    $missingReason = Copy-JsonObject $smallMove
    $missingReason.items[0].moveReason = ''
    Invoke-ValidatorCase 'missing-move-reason' $missingReason $inventory $false | Out-Null

    $virtualMove = Copy-JsonObject $unchanged
    $virtualMove.items[8].y = 100
    Invoke-ValidatorCase 'virtual-item-move' $virtualMove $inventory $false | Out-Null

    $largeMove = Copy-JsonObject $unchanged
    0..7 | ForEach-Object {
        $largeMove.items[$_].y = 400
        $largeMove.items[$_] | Add-Member -NotePropertyName moveReason -NotePropertyValue 'Synthetic large-reflow test.'
    }
    $blockedLarge = Invoke-ValidatorCase 'large-reflow-blocked' $largeMove $inventory $false
    if (-not $blockedLarge.movement.isLargeReflow) { throw 'Large reflow was not classified as large.' }
    $allowedLarge = Invoke-ValidatorCase 'large-reflow-authorized' $largeMove $inventory $true -AllowLargeReflow
    if (-not $allowedLarge.movement.largeReflowAuthorized) { throw 'Large-reflow authorization was not reported.' }

    $stalePath = Copy-JsonObject $unchanged
    $stalePath.items[0].path = 'C:\Users\Example\Desktop\Unknown.lnk'
    Invoke-ValidatorCase 'stale-path' $stalePath $inventory $false | Out-Null

    $duplicateCoordinate = Copy-JsonObject $unchanged
    $duplicateCoordinate.items[1].x = $duplicateCoordinate.items[0].x
    Invoke-ValidatorCase 'duplicate-coordinate' $duplicateCoordinate $inventory $false | Out-Null

    'PASS: 8 layout-validator behavior cases'
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($tempRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $ownedMarker) -and
        -not ((Get-Item -LiteralPath $resolvedRoot).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        foreach ($file in $createdFiles) {
            if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force }
        }
        Remove-Item -LiteralPath $ownedMarker -Force
        Remove-Item -LiteralPath $resolvedRoot -Force
    }
}
