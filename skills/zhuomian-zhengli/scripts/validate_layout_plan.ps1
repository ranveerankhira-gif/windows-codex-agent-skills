param(
    [Parameter(Mandatory)] [string] $PlanPath,
    [Parameter(Mandatory)] [string] $InventoryPath,
    [ValidateSet('Preflight','Postflight')] [string] $Mode = 'Preflight',
    [switch] $AllowLargeReflow
)

$ErrorActionPreference = 'Stop'

function Read-JsonFile([string] $Path) {
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8 | ConvertFrom-Json -Depth 30
}

function New-CiMap {
    return [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
}

function Add-Error([Collections.Generic.List[string]] $Errors, [string] $Message) {
    $Errors.Add($Message)
}

function Test-NearInteger([double] $Value, [double] $Expected, [double] $TolerancePixels, [double] $Spacing) {
    return [Math]::Abs(($Value - $Expected) * $Spacing) -le $TolerancePixels
}

$plan = Read-JsonFile $PlanPath
$inventory = Read-JsonFile $InventoryPath
$errors = [Collections.Generic.List[string]]::new()
$warnings = [Collections.Generic.List[string]]::new()
$constraintResults = [Collections.Generic.List[object]]::new()
$zoneResults = [Collections.Generic.List[object]]::new()
$movedItems = [Collections.Generic.List[object]]::new()

if ($plan.schemaVersion -ne 1) { Add-Error $errors 'Plan schemaVersion must be 1.' }
if ($inventory.schemaVersion -ne 1) { Add-Error $errors 'Inventory schemaVersion must be 1.' }

$spacingX = [double]$plan.grid.spacingX
$spacingY = [double]$plan.grid.spacingY
$originX = [double]$plan.grid.originX
$originY = [double]$plan.grid.originY
if ($spacingX -le 0 -or $spacingY -le 0) { Add-Error $errors 'Grid spacing must be positive.' }

if ([Math]::Abs($spacingX - [double]$inventory.metrics.spacingX) -gt 2 -or
    [Math]::Abs($spacingY - [double]$inventory.metrics.spacingY) -gt 2) {
    Add-Error $errors 'Plan grid spacing does not match the live desktop inventory.'
}
if ($inventory.metrics.autoArrange) { Add-Error $errors 'Desktop auto-arrange is enabled.' }

$planMap = New-CiMap
$inventoryMap = New-CiMap
foreach ($item in @($inventory.items)) {
    if ([string]::IsNullOrWhiteSpace([string]$item.path)) { Add-Error $errors 'Inventory contains an empty parsing path.'; continue }
    if ($inventoryMap.ContainsKey([string]$item.path)) { Add-Error $errors "Duplicate inventory path: $($item.path)" }
    else { $inventoryMap.Add([string]$item.path, $item) }
}
foreach ($item in @($plan.items)) {
    if ([string]::IsNullOrWhiteSpace([string]$item.path)) { Add-Error $errors 'Plan contains an empty parsing path.'; continue }
    if ($planMap.ContainsKey([string]$item.path)) { Add-Error $errors "Duplicate plan path: $($item.path)" }
    else { $planMap.Add([string]$item.path, $item) }
    if ([string]::IsNullOrWhiteSpace([string]$item.group)) { Add-Error $errors "Plan item has no group: $($item.path)" }
}

foreach ($path in $inventoryMap.Keys) {
    if (-not $planMap.ContainsKey($path)) { Add-Error $errors "Plan is missing live desktop item: $path" }
}
foreach ($path in $planMap.Keys) {
    if (-not $inventoryMap.ContainsKey($path)) { Add-Error $errors "Plan contains stale or unknown item: $path" }
}

$coordinateOwners = @{}
foreach ($item in @($plan.items)) {
    $x = [int]$item.x
    $y = [int]$item.y
    $key = "$x,$y"
    if ($coordinateOwners.ContainsKey($key)) { Add-Error $errors "Duplicate target coordinate $key for $($coordinateOwners[$key]) and $($item.path)" }
    else { $coordinateOwners[$key] = [string]$item.path }
    if ($x -lt 0 -or $y -lt 0 -or $x -ge [int]$inventory.metrics.width -or $y -ge [int]$inventory.metrics.height) {
        Add-Error $errors "Target is outside the live desktop view: $($item.path) -> ($x,$y)"
    }
    if ($inventoryMap.ContainsKey([string]$item.path)) {
        $current = $inventoryMap[[string]$item.path]
        $mustBeFixed = [bool]$current.isVirtual
        if ($mustBeFixed -and -not [bool]$item.fixed) { Add-Error $errors "Virtual desktop item is not fixed: $($item.path)" }
        if ([bool]$item.fixed -and (($x -ne [int]$current.x) -or ($y -ne [int]$current.y))) {
            Add-Error $errors "Fixed item would move: $($item.path)"
        }
        if ($Mode -eq 'Preflight' -and -not $mustBeFixed -and (($x -ne [int]$current.x) -or ($y -ne [int]$current.y))) {
            if ([string]::IsNullOrWhiteSpace([string]$item.moveReason)) { Add-Error $errors "Moved item has no moveReason: $($item.path)" }
            $dxCells = [Math]::Abs(([double]$x - [double]$current.x) / $spacingX)
            $dyCells = [Math]::Abs(([double]$y - [double]$current.y) / $spacingY)
            $movedItems.Add([pscustomobject]@{
                path=[string]$item.path
                isDirectory=[bool]$current.isDirectory
                fromX=[int]$current.x; fromY=[int]$current.y
                toX=$x; toY=$y
                displacementCells=[Math]::Round(($dxCells + $dyCells), 3)
                moveReason=[string]$item.moveReason
            })
        }
        if ($Mode -eq 'Postflight' -and (($x -ne [int]$current.x) -or ($y -ne [int]$current.y))) {
            Add-Error $errors "Coordinate mismatch after apply: $($item.path); expected=($x,$y); actual=($($current.x),$($current.y))"
        }
    }
}

$movableItemCount = @($inventory.items | Where-Object { -not [bool]$_.isVirtual }).Count
$movedItemCount = $movedItems.Count
$movedFolderCount = @($movedItems | Where-Object { [bool]$_.isDirectory }).Count
$totalDisplacementCells = [Math]::Round([double](($movedItems | Measure-Object -Property displacementCells -Sum).Sum), 3)
$maximumDisplacementCells = [Math]::Round([double](($movedItems | Measure-Object -Property displacementCells -Maximum).Maximum), 3)
$movedItemLimit = [Math]::Max(6, [Math]::Floor($movableItemCount * 0.25))
$totalDisplacementLimit = [Math]::Max(24, [Math]::Round($movableItemCount * 1.25))
$isLargeReflow = $movedItemCount -gt $movedItemLimit -or $totalDisplacementCells -gt $totalDisplacementLimit
if ($Mode -eq 'Preflight' -and $isLargeReflow -and -not $AllowLargeReflow) {
    Add-Error $errors "Large reflow blocked: movedItems=$movedItemCount (limit=$movedItemLimit); totalDisplacementCells=$totalDisplacementCells (limit=$totalDisplacementLimit). Separate user authorization is required."
}
$movement = [pscustomobject]@{
    movableItemCount=$movableItemCount
    movedItemCount=$movedItemCount
    movedFolderCount=$movedFolderCount
    totalDisplacementCells=$totalDisplacementCells
    maximumDisplacementCells=$maximumDisplacementCells
    movedItemLimit=$movedItemLimit
    totalDisplacementLimit=$totalDisplacementLimit
    isLargeReflow=$isLargeReflow
    largeReflowAuthorized=[bool]$AllowLargeReflow
    movedItems=@($movedItems)
}

$tolerance = 2.0
foreach ($constraint in @($plan.constraints)) {
    $name = if ([string]::IsNullOrWhiteSpace([string]$constraint.name)) { '<unnamed constraint>' } else { [string]$constraint.name }
    $paths = @($constraint.paths | ForEach-Object { [string]$_ })
    $localErrors = [Collections.Generic.List[string]]::new()
    $members = [Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        if (-not $planMap.ContainsKey($path)) { $localErrors.Add("missing path: $path") }
        else { $members.Add($planMap[$path]) }
    }
    if ($constraint.type -eq 'pair') {
        if ($members.Count -ne 2) { $localErrors.Add('pair constraint requires exactly two paths') }
        else {
            $first = $members[0]; $second = $members[1]
            $dx = [Math]::Abs(([double]$first.x - [double]$second.x) / $spacingX)
            $dy = [Math]::Abs(([double]$first.y - [double]$second.y) / $spacingY)
            if ($null -ne $constraint.exactColumnDelta -and -not (Test-NearInteger $dx ([double]$constraint.exactColumnDelta) $tolerance $spacingX)) { $localErrors.Add("column delta is $dx") }
            if ($null -ne $constraint.exactRowDelta -and -not (Test-NearInteger $dy ([double]$constraint.exactRowDelta) $tolerance $spacingY)) { $localErrors.Add("row delta is $dy") }
            if ($null -ne $constraint.maxColumnDelta -and ($dx * $spacingX) -gt (([double]$constraint.maxColumnDelta * $spacingX) + $tolerance)) { $localErrors.Add("column delta exceeds $($constraint.maxColumnDelta)") }
            if ($null -ne $constraint.maxRowDelta -and ($dy * $spacingY) -gt (([double]$constraint.maxRowDelta * $spacingY) + $tolerance)) { $localErrors.Add("row delta exceeds $($constraint.maxRowDelta)") }
            if ([bool]$constraint.firstAboveSecond -and [int]$first.y -ge [int]$second.y) { $localErrors.Add('first item is not above second item') }
            if ([bool]$constraint.firstLeftOfSecond -and [int]$first.x -ge [int]$second.x) { $localErrors.Add('first item is not left of second item') }
        }
    } elseif ($constraint.type -eq 'compact') {
        if ($members.Count -lt 2) { $localErrors.Add('compact constraint requires at least two paths') }
        else {
            $rangeX = (($members | Measure-Object -Property x -Maximum).Maximum - ($members | Measure-Object -Property x -Minimum).Minimum) / $spacingX
            $rangeY = (($members | Measure-Object -Property y -Maximum).Maximum - ($members | Measure-Object -Property y -Minimum).Minimum) / $spacingY
            if ($null -ne $constraint.maxColumnDelta -and ($rangeX * $spacingX) -gt (([double]$constraint.maxColumnDelta * $spacingX) + $tolerance)) { $localErrors.Add("width exceeds $($constraint.maxColumnDelta) columns") }
            if ($null -ne $constraint.maxRowDelta -and ($rangeY * $spacingY) -gt (([double]$constraint.maxRowDelta * $spacingY) + $tolerance)) { $localErrors.Add("height exceeds $($constraint.maxRowDelta) rows") }
        }
    } else {
        $localErrors.Add("unsupported constraint type: $($constraint.type)")
    }
    $passed = $localErrors.Count -eq 0
    $constraintResults.Add([pscustomobject]@{ name=$name; type=[string]$constraint.type; passed=$passed; errors=@($localErrors) })
    if (-not $passed) { Add-Error $errors "Semantic constraint failed: $name ($($localErrors -join '; '))" }
}
if (@($plan.constraints).Count -eq 0) { $warnings.Add('Plan has no semantic constraints.') }

$zoneGroups = New-CiMap
foreach ($zone in @($plan.zones)) {
    $name = if ([string]::IsNullOrWhiteSpace([string]$zone.name)) { '<unnamed zone>' } else { [string]$zone.name }
    $localErrors = [Collections.Generic.List[string]]::new()
    foreach ($group in @($zone.groups | ForEach-Object { [string]$_ })) {
        if ($zoneGroups.ContainsKey($group)) { $localErrors.Add("group appears in multiple zones: $group") }
        else { $zoneGroups.Add($group, $zone) }
        foreach ($item in @($plan.items | Where-Object { -not [bool]$_.fixed -and [string]$_.group -ieq $group })) {
            $column = [Math]::Round(([double]$item.x - $originX) / $spacingX)
            $row = [Math]::Round(([double]$item.y - $originY) / $spacingY)
            if ($column -lt [int]$zone.minColumn -or $column -gt [int]$zone.maxColumn -or $row -lt [int]$zone.minRow -or $row -gt [int]$zone.maxRow) {
                $localErrors.Add("$($item.path) lies outside zone")
            }
        }
    }
    $passed = $localErrors.Count -eq 0
    $zoneResults.Add([pscustomobject]@{ name=$name; passed=$passed; errors=@($localErrors) })
    if (-not $passed) { Add-Error $errors "Zone validation failed: $name ($($localErrors -join '; '))" }
}
if (@($plan.zones).Count -eq 0) { $warnings.Add('Plan has no explicit zones.') }

$categoryCounts = @($plan.items | Where-Object { -not [bool]$_.fixed } | Group-Object group | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ group=$_.Name; count=$_.Count }
})

$result = [pscustomobject]@{
    success = ($errors.Count -eq 0)
    mode = $Mode
    liveItemCount = @($inventory.items).Count
    planItemCount = @($plan.items).Count
    fixedItemCount = @($plan.items | Where-Object { [bool]$_.fixed }).Count
    movement = $movement
    categoryCounts = $categoryCounts
    constraintResults = @($constraintResults)
    zoneResults = @($zoneResults)
    warnings = @($warnings)
    errors = @($errors)
}
$result | ConvertTo-Json -Depth 12
if (-not $result.success) { exit 2 }
