# Assemble a clean, shippable runtime for one config into dist\<Config>\.
# Copies exe/dll/modules + data (shaders/config/fonts/project) from the build output,
# excluding dev artifacts (pdb/lib/exp/ilk/obj/pch) and the Intermediate scratch dir.
# PDBs stay in the build folder (x64\<Config>) as symbols; they are not shipped.
#
#   powershell -File NukeUtils\stage_release.ps1 -Config Release
param([string]$Config = "Release")
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $root "NukeEngine\x64\$Config"
$dst  = Join-Path $root "dist\$Config"
$devExt   = @('.pdb','.lib','.exp','.ilk','.iobj','.ipdb','.obj','.pch','.log','.tlog')
$scratch  = 'Intermediate'

if (-not (Test-Path $src)) { throw "build output not found: $src  (build $Config first)" }
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$base = (Resolve-Path $src).Path
$files = 0; $bytes = 0
foreach ($f in Get-ChildItem $src -Recurse -File) {
    $rel = $f.FullName.Substring($base.Length).TrimStart('\')
    if (($rel -split '\\')[0] -eq $scratch) { continue }   # build scratch
    if ($devExt -contains $f.Extension)     { continue }    # dev artifacts, not shipped
    if ($f.Name -like '*-gd-*')             { continue }    # defensive: never ship debug-variant deps
    $target = Join-Path $dst $rel
    $tdir = Split-Path $target -Parent
    if (-not (Test-Path $tdir)) { New-Item -ItemType Directory -Force -Path $tdir | Out-Null }
    Copy-Item $f.FullName $target -Force
    $files++; $bytes += $f.Length
}
"Staged $Config -> $dst"
"  $files files, {0} MB" -f [math]::Round($bytes/1MB,2)
