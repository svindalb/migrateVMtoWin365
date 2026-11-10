#requires -Version 7.2
<# Offline validation of the GitHub upload allowlist, hashes and local Markdown links.
   -Strict also rejects any extra file/directory in a clean upload tree.
   Does not authenticate, inspect operational journals or certify secret removal. #>
[CmdletBinding()]
param(
    [string]$RootPath = (Split-Path $PSScriptRoot -Parent),
    [switch]$Strict
)
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RootPath)
if (-not [IO.Directory]::Exists($root) -or ([IO.File]::GetAttributes($root) -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Package root must be an existing unlinked directory.'
}
$manifestPath = Join-Path $root 'package-manifest.json'
if ([IO.File]::GetAttributes($manifestPath) -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked manifest rejected.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or -not $manifest.files.Count) { throw 'Invalid package manifest.' }
$files = @($manifest.files)
$required = @(
    '.gitignore', 'README.md', 'Start-CpcMigration.ps1',
    'CpcMigration.Core.psm1', 'CpcMigration.Workflow.psm1', 'CpcMigration.Confirmation.psm1',
    'CpcMigration.Journals.psm1', 'CpcMigration.xaml', 'CpcMigration.Journals.xaml',
    'docs/OPERATOR-GUIDE.md', 'docs/SECURITY-AND-RECOVERY.md',
    'tests/Test-Offline.ps1', 'tests/Test-Recovery.ps1', 'tests/Test-Logging.ps1',
    'tests/Test-Workflow.ps1', 'tests/Test-Journals.ps1', 'tests/Test-Package.ps1', 'package-manifest.json'
)
foreach ($file in $required) { if ($file -cnotin $files) { throw "Required upload file omitted: $file" } }
if (@($files | Select-Object -Unique).Count -ne $files.Count) { throw 'Duplicate package entries.' }
foreach ($relative in $files) {
    if ($relative -cnotin $required) { throw "Unreviewed upload entry: $relative" }
}
$script:Checks = 0

function Get-MarkdownAnchors([string]$Path) {
    # GitHub-style slugs for the ATX headings used in this package. Ignore code
    # fences; suffix duplicate headings so TOC checks catch accidental collisions.
    $anchors = [collections.generic.hashset[string]]::new([StringComparer]::Ordinal)
    $fence = ''; $counts = @{}
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*(`{3,}|~{3,})') {
            $marker = $Matches[1].Substring(0, 1)
            if (-not $fence) { $fence = $marker }
            elseif ($marker -eq $fence) { $fence = '' }
            continue
        }
        if ($fence -or $line -notmatch '^#{1,6}\s+(.+?)\s*#*\s*$') { continue }
        $slug = $Matches[1].ToLowerInvariant() -replace '[^\p{L}\p{N}\p{M}_\- ]', '' -replace ' ', '-'
        $number = if ($counts.ContainsKey($slug)) { [int]$counts[$slug] + 1 } else { 0 }
        $counts[$slug] = $number
        if ($number) { $slug += '-' + $number }
        $null = $anchors.Add($slug)
    }
    return ,$anchors
}

function Test-PackageTree([string]$Base) {
    $basePrefix = $Base.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($relative in $files) {
        $path = Join-Path $Base $relative
        if (-not [IO.File]::Exists($path)) { throw "Missing upload file: $relative" }
        # Check parents too; a plain file inside a linked directory is not safe.
        $entry = $path
        while ($entry.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            if ([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::ReparsePoint) { throw "Linked upload path: $relative" }
            $entry = [IO.Path]::GetDirectoryName($entry)
        }
        $script:Checks++
        if ($relative -notlike '*.md') { continue }
        $text = [IO.File]::ReadAllText($path)
        foreach ($link in [regex]::Matches($text, '\[[^\]\r\n]+\]\(([^)\s]+)\)')) {
            $target = $link.Groups[1].Value
            if ($target -match '^(https?://|mailto:)') { continue } # External URLs not validated.
            $parts = $target -split '#', 2
            $fileTarget = [uri]::UnescapeDataString($parts[0])
            $resolved = if ($fileTarget) {
                [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetDirectoryName($path)) $fileTarget))
            } else { $path }
            if (-not $resolved.StartsWith($basePrefix, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($resolved)) {
                throw "Broken/outside local link in ${relative}: $target"
            }
            $packageRelative = [IO.Path]::GetRelativePath($Base, $resolved).Replace('\','/')
            if ($packageRelative -cnotin $files) { throw "Unpackaged link in ${relative}: $target" }
            if ($parts.Count -eq 2 -and $parts[1] -and $resolved -like '*.md') {
                $anchors = Get-MarkdownAnchors $resolved
                if (-not $anchors.Contains([uri]::UnescapeDataString($parts[1]))) { throw "Missing heading in ${relative}: $target" }
            }
            $script:Checks++
        }
    }
}

if ($Strict) {
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse) {
        $relative = [IO.Path]::GetRelativePath($root, $item.FullName).Replace('\','/')
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked tree entry: $relative" }
        if ($item.PSIsContainer) {
            if ($relative -cnotin @('docs','tests')) { throw "Extra upload directory: $relative" }
        } elseif ($relative -cnotin $files) { throw "Extra upload file: $relative" }
        $script:Checks++
    }
}
Test-PackageTree $root
$stage = Join-Path ([IO.Path]::GetTempPath()) ('cpcm-github-package-test-' + [guid]::NewGuid().ToString('N'))
try {
    foreach ($relative in $files) {
        $source = Join-Path $root $relative; $target = Join-Path $stage $relative
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy($source, $target, $false)
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $target).Hash) { throw "Staged bytes differ: $relative" }
        $script:Checks++
    }
    Test-PackageTree $stage
    Write-Host "Package tests: $script:Checks passed; $($files.Count) upload files staged, hash-verified and local file/heading links checked; no cloud calls."
} finally {
    if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) }
}