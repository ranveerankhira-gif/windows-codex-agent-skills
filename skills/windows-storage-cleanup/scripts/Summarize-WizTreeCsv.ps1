[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Roots,

    [ValidateRange(1, 100)]
    [int]$Top = 20,

    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedRoot {
    param([Parameter(Mandatory)][string]$Path)

    $isDriveAbsolute = $Path -match '^[A-Za-z]:[\\/]'
    $isUncAbsolute = $Path -match '^[\\/]{2}[^\\/]+[\\/]+[^\\/]+'
    $isExtendedAbsolute = $Path -match '^\\\\\?\\'
    if (-not ($isDriveAbsolute -or $isUncAbsolute -or $isExtendedAbsolute)) {
        throw "Root must be an absolute path: $Path"
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $driveRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.TrimEnd('\') -ieq $driveRoot.TrimEnd('\')) {
        return $driveRoot
    }

    return $fullPath.TrimEnd('\')
}

function Get-HeaderIndex {
    param(
        [Parameter(Mandatory)][string[]]$Headers,
        [Parameter(Mandatory)][string[]]$Aliases,
        [Parameter(Mandatory)][string]$FieldName
    )

    foreach ($alias in $Aliases) {
        for ($index = 0; $index -lt $Headers.Count; $index++) {
            if ($Headers[$index] -ieq $alias) {
                return $index
            }
        }
    }

    throw "WizTree CSV is missing the required '$FieldName' column. Found: $($Headers -join ', ')"
}

function ConvertTo-Int64 {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory)][string]$FieldName,
        [Parameter(Mandatory)][long]$LineNumber
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return [int64]0
    }

    $parsed = [int64]0
    if (-not [int64]::TryParse($Value, [System.Globalization.NumberStyles]::Integer,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
        throw "Invalid $FieldName value '$Value' at CSV line $LineNumber."
    }
    if ($parsed -lt 0) {
        throw "Negative $FieldName value '$Value' at CSV line $LineNumber."
    }

    return $parsed
}

$resolvedCsv = (Resolve-Path -LiteralPath $CsvPath).Path
$rootMap = [System.Collections.Generic.Dictionary[string, object]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)

foreach ($root in $Roots) {
    $normalized = Get-NormalizedRoot -Path $root
    if (-not $rootMap.ContainsKey($normalized)) {
        $rootMap.Add($normalized, [pscustomobject]@{
            DirectItems = [int64]0
            AllocatedBytes = [int64]0
            TopItems = [System.Collections.Generic.List[object]]::new()
        })
    }
}

Add-Type -AssemblyName Microsoft.VisualBasic
$parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new(
    $resolvedCsv,
    [System.Text.Encoding]::UTF8,
    $true
)
$parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
$parser.SetDelimiters(',')
$parser.HasFieldsEnclosedInQuotes = $true

try {
    $banner = $parser.ReadLine()
    if ([string]::IsNullOrWhiteSpace($banner) -or $banner -notmatch '(?i)WizTree\s+\d+(?:\.\d+)+') {
        throw 'The first line does not identify a WizTree export.'
    }

    if ($parser.EndOfData) {
        throw 'The WizTree CSV does not contain a header row.'
    }

    $headers = $parser.ReadFields()
    if ($null -eq $headers) {
        throw 'The WizTree CSV header could not be parsed.'
    }

    # Keep the script ASCII so Windows PowerShell 5.1 does not misread localized aliases.
    $pathHeaderZh = -join [char[]]@(0x6587, 0x4EF6, 0x540D, 0x79F0)
    $sizeHeaderZh = -join [char[]]@(0x5927, 0x5C0F)
    $allocatedHeaderZh = -join [char[]]@(0x5206, 0x914D)
    $modifiedHeaderZh = -join [char[]]@(0x4FEE, 0x6539, 0x65F6, 0x95F4)
    $filesHeaderZh = -join [char[]]@(0x6587, 0x4EF6)
    $foldersHeaderZh = -join [char[]]@(0x6587, 0x4EF6, 0x5939)

    $pathIndex = Get-HeaderIndex -Headers $headers -Aliases @('File Name', 'Filename', $pathHeaderZh) -FieldName 'path'
    $sizeIndex = Get-HeaderIndex -Headers $headers -Aliases @('Size', $sizeHeaderZh) -FieldName 'size'
    $allocatedIndex = Get-HeaderIndex -Headers $headers -Aliases @('Allocated', $allocatedHeaderZh) -FieldName 'allocated size'
    $modifiedIndex = Get-HeaderIndex -Headers $headers -Aliases @('Date Modified', 'Modified', $modifiedHeaderZh) -FieldName 'modified time'
    $filesIndex = Get-HeaderIndex -Headers $headers -Aliases @('Files', $filesHeaderZh) -FieldName 'file count'
    $foldersIndex = Get-HeaderIndex -Headers $headers -Aliases @('Folders', $foldersHeaderZh) -FieldName 'folder count'
    $requiredMaxIndex = @($pathIndex, $sizeIndex, $allocatedIndex, $modifiedIndex, $filesIndex, $foldersIndex) |
        Measure-Object -Maximum |
        Select-Object -ExpandProperty Maximum

    $lineNumber = 2L
    while (-not $parser.EndOfData) {
        $lineNumber++
        try {
            $fields = $parser.ReadFields()
        }
        catch [Microsoft.VisualBasic.FileIO.MalformedLineException] {
            throw "Malformed CSV at line ${lineNumber}: $($_.Exception.Message)"
        }

        if ($null -eq $fields -or $fields.Count -le $requiredMaxIndex) {
            throw "WizTree CSV line $lineNumber has fewer columns than the header."
        }

        $itemPath = $fields[$pathIndex]
        if ([string]::IsNullOrWhiteSpace($itemPath)) {
            continue
        }

        $trimmedPath = $itemPath.TrimEnd('\')
        $parent = [System.IO.Path]::GetDirectoryName($trimmedPath)
        if ([string]::IsNullOrWhiteSpace($parent)) {
            continue
        }

        $normalizedParent = Get-NormalizedRoot -Path $parent
        if (-not $rootMap.ContainsKey($normalizedParent)) {
            continue
        }

        $allocatedBytes = ConvertTo-Int64 -Value $fields[$allocatedIndex] -FieldName 'allocated size' -LineNumber $lineNumber
        $item = [pscustomobject]@{
            Name           = [System.IO.Path]::GetFileName($trimmedPath)
            Path           = $itemPath
            SizeBytes      = ConvertTo-Int64 -Value $fields[$sizeIndex] -FieldName 'size' -LineNumber $lineNumber
            AllocatedBytes = $allocatedBytes
            AllocatedMiB   = [math]::Round($allocatedBytes / 1MB, 1)
            Modified       = $fields[$modifiedIndex]
            IsDirectory    = $itemPath.EndsWith('\')
            Files          = ConvertTo-Int64 -Value $fields[$filesIndex] -FieldName 'file count' -LineNumber $lineNumber
            Folders        = ConvertTo-Int64 -Value $fields[$foldersIndex] -FieldName 'folder count' -LineNumber $lineNumber
        }
        $state = $rootMap[$normalizedParent]
        $state.DirectItems = [int64]$state.DirectItems + 1
        $state.AllocatedBytes = [int64]$state.AllocatedBytes + $allocatedBytes
        $state.TopItems.Add($item)
        if ($state.TopItems.Count -gt $Top) {
            $worst = @($state.TopItems |
                Sort-Object -Property @{ Expression = 'AllocatedBytes'; Descending = $false },
                    @{ Expression = 'Path'; Descending = $true } |
                Select-Object -First 1)[0]
            [void]$state.TopItems.Remove($worst)
        }
    }
}
finally {
    $parser.Close()
}

$rootSummaries = foreach ($root in $rootMap.Keys) {
    $state = $rootMap[$root]
    [pscustomobject]@{
        Root           = $root
        DirectItems    = $state.DirectItems
        AllocatedBytes = $state.AllocatedBytes
        AllocatedGiB   = [math]::Round($state.AllocatedBytes / 1GB, 3)
        Top            = @($state.TopItems |
            Sort-Object -Property @{ Expression = 'AllocatedBytes'; Descending = $true },
                @{ Expression = 'Path'; Descending = $false })
    }
}

$result = [pscustomobject]@{
    CsvPath     = $resolvedCsv
    Banner      = $banner
    Roots       = @($rootSummaries | Sort-Object -Property Root)
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 7
}
else {
    $result
}
