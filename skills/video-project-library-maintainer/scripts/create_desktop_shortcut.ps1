param(
    [Parameter(Mandatory = $true)][string]$ShortcutPath,
    [Parameter(Mandatory = $true)][string]$TargetPath
)
$ErrorActionPreference = 'Stop'
if (-not [IO.Path]::IsPathFullyQualified($ShortcutPath)) { throw "ShortcutPath must be absolute: $ShortcutPath" }
if (-not [IO.Path]::IsPathFullyQualified($TargetPath)) { throw "TargetPath must be absolute: $TargetPath" }
$shortcutFull = [IO.Path]::GetFullPath($ShortcutPath)
$targetFull = [IO.Path]::GetFullPath($TargetPath)
if ([IO.Path]::GetExtension($shortcutFull) -ine '.lnk') { throw "ShortcutPath must end in .lnk: $shortcutFull" }

function Assert-NoReparseComponent([string]$PathValue, [string]$Label) {
    $current = [IO.Path]::GetPathRoot($PathValue)
    $relative = $PathValue.Substring($current.Length)
    foreach ($part in ($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label contains a reparse point: $current"
            }
        }
    }
}

Assert-NoReparseComponent -PathValue $targetFull -Label 'TargetPath'
Assert-NoReparseComponent -PathValue $shortcutFull -Label 'ShortcutPath'
if (-not (Test-Path -LiteralPath $targetFull -PathType Container)) { throw "Target directory does not exist: $targetFull" }
$parent = Split-Path -Parent $shortcutFull
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "Shortcut parent does not exist: $parent" }
$shell = New-Object -ComObject WScript.Shell
if (Test-Path -LiteralPath $shortcutFull) {
    if (-not (Test-Path -LiteralPath $shortcutFull -PathType Leaf)) { throw "ShortcutPath exists but is not a file: $shortcutFull" }
    $existing = $shell.CreateShortcut($shortcutFull)
    $existingTarget = [IO.Path]::GetFullPath($existing.TargetPath)
    if ($existingTarget -eq $targetFull) { exit 0 }
    throw "Shortcut already exists with a different target: $shortcutFull -> $existingTarget"
}
$temporary = Join-Path $parent ('.video-project-library-' + [Guid]::NewGuid().ToString('N') + '.lnk')
try {
    $shortcut = $shell.CreateShortcut($temporary)
    $shortcut.TargetPath = $targetFull
    $shortcut.WorkingDirectory = $targetFull
    $shortcut.Description = '视频工程资料库'
    $shortcut.Save()
    Move-Item -LiteralPath $temporary -Destination $shortcutFull
}
finally {
    if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
}
