# Assemble a clean, shippable runtime for one config into dist\<Config>\.
# Copies exe/dll/modules + data (shaders/config/fonts) from the build output,
# excluding dev artifacts (pdb/lib/exp/ilk/obj/pch), the Intermediate scratch dir
# and PROJECTS (any top-level dir with a .nuproj inside is a game project — projects
# are the user's data, never part of the engine build).
# PDBs stay in the build folder (x64\<Config>) as symbols; they are not shipped.
#
# Modes:
#   Full    (default) — everything shippable: all modules, script runtimes, caches.
#   Minimal           — bare boot set: exes + root runtime dlls + renderer module
#                       + shaders/fonts/config/res. No optional modules, no managed,
#                       no plugins/, no shader cache, no imgui.ini.
#
#   powershell -File NukeUtils\stage_release.ps1 -Config Release
#   powershell -File NukeUtils\stage_release.ps1 -Config Release -Mode Minimal
#   powershell -File NukeUtils\stage_release.ps1 -Mode Minimal -MinimalModules NukeRenderDiligent.dll,NukeScript.dll
param(
    [string]$Config = "Release",
    [ValidateSet("Full", "Minimal")][string]$Mode = "Full",
    # Module dlls kept in Minimal mode. The renderer is mandatory (the engine cannot
    # boot without a "render" service); everything else is an optional plugin.
    [string[]]$MinimalModules = @("NukeRenderDiligent.dll")
)
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $root "NukeEngine\x64\$Config"
$dst  = Join-Path $root "dist\$Config"
$devExt   = @('.pdb','.lib','.exp','.ilk','.iobj','.ipdb','.obj','.pch','.log','.tlog')
$scratch  = 'Intermediate'

if (-not (Test-Path $src)) { throw "build output not found: $src  (build $Config first)" }

# Projects are detected, not hardcoded: any top-level dir carrying a .nuproj is a
# game project (project\, NukeNativeRim\, whatever the user creates next).
$projectDirs = @(Get-ChildItem $src -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "*.nuproj")
} | ForEach-Object { $_.Name })
if ($projectDirs.Count) { "Excluding project dirs: $($projectDirs -join ', ')" }

# Minimal-only exclusions: session/machine artifacts and optional subsystems.
$minimalSkipDirs  = @('plugins')                 # script runtimes (belong to script modules)
$minimalSkipFiles = @('imgui.ini')               # editor session layout, per-machine

if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$base = (Resolve-Path $src).Path
$files = 0; $bytes = 0; $skipped = 0
foreach ($f in Get-ChildItem $src -Recurse -File) {
    $rel   = $f.FullName.Substring($base.Length).TrimStart('\')
    $parts = $rel -split '\\'
    $top   = $parts[0]
    if ($top -eq $scratch)              { continue }   # build scratch
    if ($projectDirs -contains $top)    { $skipped++; continue }   # game projects: never shipped
    if ($devExt -contains $f.Extension) { continue }   # dev artifacts, not shipped
    if ($f.Name -like '*-gd-*')         { continue }   # defensive: never ship debug-variant deps

    if ($Mode -eq "Minimal") {
        if ($minimalSkipDirs -contains $top)                { $skipped++; continue }
        if ($parts.Count -eq 1 -and $minimalSkipFiles -contains $f.Name) { $skipped++; continue }
        # config\: keep main.json only — shadercache_vk/mods are machine/session data.
        if ($top -eq 'config' -and $rel -ne 'config\main.json')          { $skipped++; continue }
        # modules\: whitelist only (managed\ and optional module dlls stay behind).
        if ($top -eq 'modules' -and -not ($parts.Count -eq 2 -and $MinimalModules -contains $f.Name)) { $skipped++; continue }
    }

    $target = Join-Path $dst $rel
    $tdir = Split-Path $target -Parent
    if (-not (Test-Path $tdir)) { New-Item -ItemType Directory -Force -Path $tdir | Out-Null }
    Copy-Item $f.FullName $target -Force
    $files++; $bytes += $f.Length
}
"Staged $Config ($Mode) -> $dst"
"  $files files, {0} MB ($skipped excluded)" -f [math]::Round($bytes/1MB,2)
