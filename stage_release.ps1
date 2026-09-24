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
#   -Sdk (orthogonal)  — additionally stage dist\<Config>\sdk\: the C++ game-module kit
#                       (engine headers, import libs for BOTH configs when built, NukeGen.exe,
#                       the vcpkg manifest). The game-module scaffold detects this layout
#                       (include/, lib/<Config>/, bin/) through NUKE_ENGINE_ROOT.
#
#   powershell -File NukeUtils\stage_release.ps1 -Config Release
#   powershell -File NukeUtils\stage_release.ps1 -Config Release -Mode Minimal
#   powershell -File NukeUtils\stage_release.ps1 -Config Release -Mode Minimal -Sdk
#   powershell -File NukeUtils\stage_release.ps1 -Mode Minimal -MinimalModules NukeRenderDiligent.dll,NukeScript.dll
#   -Tech (orthogonal) — the vendor upscaling / frame-generation runtimes to ship: All, None, or
#                       any of DLSS, FSR, XeSS. Full ships All, Minimal ships None unless given.
#   powershell -File NukeUtils\stage_release.ps1 -Config Release -Tech DLSS,FSR
#   powershell -File NukeUtils\stage_release.ps1 -Config Release -Mode Minimal -Tech All
param(
    [string]$Config = "Release",
    [ValidateSet("Full", "Minimal")][string]$Mode = "Full",
    [switch]$Sdk,
    # Stage matching PDBs into dist\<out>\symbols\ (NOT for players — archive next to the
    # release so any config/crash/crash.dmp a user sends resolves against this build).
    [switch]$Symbols,
    # Output dir name under dist\ (default = the config name). Lets several variants of the
    # SAME config coexist: dist\Release-Minimal, dist\Release-FullSdk, ...
    [string]$OutName = "",
    # Module dlls kept in Minimal mode. The renderer is mandatory (the engine cannot
    # boot without a "render" service); everything else is an optional plugin.
    [string[]]$MinimalModules = @("NukeRenderDiligent.dll"),
    # Vendor upscaling / frame-generation runtimes to ship: "All", "None", or any of DLSS, FSR,
    # XeSS (comma list, case-insensitive). Default: All in Full mode, None in Minimal. The
    # renderer loads them by name and offers only what it finds - nothing else changes.
    [string[]]$Tech = @()
)
$ErrorActionPreference = "Stop"

$root = Split-Path $PSScriptRoot -Parent
$src  = Join-Path $root "NukeEngine\x64\$Config"
if ($OutName -eq "") { $OutName = $Config }
$dst  = Join-Path $root "dist\$OutName"
$devExt   = @('.pdb','.lib','.exp','.ilk','.iobj','.ipdb','.obj','.pch','.log','.tlog')
$scratch  = 'Intermediate'

if (-not (Test-Path $src)) { throw "build output not found: $src  (build $Config first)" }

# Projects are detected, not hardcoded: any top-level dir carrying a .nuproj is a
# game project (project\, NukeNativeRim\, whatever the user creates next).
$projectDirs = @(Get-ChildItem $src -Directory | Where-Object {
    Test-Path (Join-Path $_.FullName "*.nuproj")
} | ForEach-Object { $_.Name })
if ($projectDirs.Count) { "Excluding project dirs: $($projectDirs -join ', ')" }

# Vendor runtimes by technology (the same set the editor's Package Project dialog toggles);
# they live in the run root and/or modules\, and -Tech decides them wherever they are.
$techFiles = @{
    'DLSS' = @('nvngx_dlss.dll', 'sl.interposer.dll', 'sl.common.dll', 'sl.dlss_g.dll', 'sl.reflex.dll', 'sl.pcl.dll', 'nvngx_dlssg.dll', 'NvLowLatencyVk.dll')
    'FSR'  = @('amd_fidelityfx_upscaler_dx12.dll', 'amd_fidelityfx_framegeneration_dx12.dll', 'amd_fidelityfx_vk.dll')
    'XeSS' = @('libxess.dll', 'libxess_fg.dll', 'libxell.dll')
}
if ($Tech.Count -eq 0) { $Tech = @($(if ($Mode -eq "Full") { "All" } else { "None" })) }
$Tech = @($Tech | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$techOn = @{}
foreach ($t in $Tech) {
    $tl = $t.ToLower()
    if ($tl -eq 'all')      { foreach ($k in $techFiles.Keys) { $techOn[$k] = $true } }
    elseif ($tl -eq 'none') { $techOn = @{} }
    else {
        $k = @($techFiles.Keys | Where-Object { $_.ToLower() -eq $tl })
        if ($k.Count -eq 0) { throw "-Tech: unknown technology '$t' (All, None, DLSS, FSR, XeSS)" }
        $techOn[$k[0]] = $true
    }
}
$techOwner = @{}
foreach ($k in $techFiles.Keys) { foreach ($n in $techFiles[$k]) { $techOwner[$n.ToLower()] = $k } }
"Vendor tech: " + $(if ($techOn.Count) { (@($techOn.Keys) | Sort-Object) -join ', ' } else { 'none' })

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

    # Vendor upscaler / frame-generation runtimes: -Tech alone decides, in every mode and folder.
    $owner = $techOwner[$f.Name.ToLower()]
    if ($owner) { if (-not $techOn[$owner]) { $skipped++; continue } }
    elseif ($Mode -eq "Minimal") {
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
$techTag = if ($techOn.Count) { (@($techOn.Keys) | Sort-Object) -join '+' } else { 'no vendor tech' }
"Staged $Config ($Mode, $techTag) -> $dst"
"  $files files, {0} MB ($skipped excluded)" -f [math]::Round($bytes/1MB,2)

# ---- -Sdk: the C++ game-module kit ------------------------------------------------------
# Everything a game module compiles and links against, laid out the way the scaffold's SDK
# branch expects: include\ (engine public headers), lib\<Config>\NukeEngine.lib (+NukeImGui
# for editor-tool modules; both configs when both are built), bin\NukeGen.exe, vcpkg.json.
# Dependencies are NOT vendored: the manifest names the engine's public ones (boost,
# nlohmann-json, glm) and vcpkg's manifest mode installs them at the consumer's first
# configure.
if ($Sdk) {
    $sdkDir = Join-Path $dst "sdk"
    if (Test-Path $sdkDir) { Remove-Item $sdkDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $sdkDir | Out-Null

    # Headers (the whole public include tree — that IS the API surface). Copy-Item -Recurse
    # reproduces EMPTY directories too (stale leftovers in the source tree, untracked by git),
    # so prune them: an empty dir in a shipped SDK only raises questions.
    $incSrc = Join-Path $root "NukeEngine\include"
    Copy-Item $incSrc (Join-Path $sdkDir "include") -Recurse
    Get-ChildItem (Join-Path $sdkDir "include") -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { -not (Get-ChildItem $_.FullName -Force) } |
        Remove-Item

    # Import libs, per config, for every config that has been built. NukeImGui's lands in the
    # superbuild tree (editor-tool modules link it), NukeEngine's next to the engine dll.
    $libCandidates = @(
        @{ Name = "NukeEngine.lib"; Dirs = @("NukeEngine\x64\{0}") },
        @{ Name = "NukeImGui.lib";  Dirs = @("build\NukeImGui\{0}", "NukeEngine\x64\{0}") }
    )
    foreach ($cfg in @("Debug", "Release")) {
        $any = $false
        foreach ($lc in $libCandidates) {
            foreach ($d in $lc.Dirs) {
                $lp = Join-Path $root (($d -f $cfg))
                $lp = Join-Path $lp $lc.Name
                if (Test-Path $lp) {
                    if (-not $any) { New-Item -ItemType Directory -Force -Path (Join-Path $sdkDir "lib\$cfg") | Out-Null; $any = $true }
                    Copy-Item $lp (Join-Path $sdkDir "lib\$cfg\$($lc.Name)") -Force
                    break
                }
            }
        }
        if (-not $any) { "  sdk: $cfg libs not built - lib\$cfg skipped" }
    }

    # The native reflection generator — the one tool a module build needs (no Python).
    $gen = Join-Path $root "NukeUtils\bin\NukeGen.exe"
    if (Test-Path $gen) {
        New-Item -ItemType Directory -Force -Path (Join-Path $sdkDir "bin") | Out-Null
        Copy-Item $gen (Join-Path $sdkDir "bin\NukeGen.exe") -Force
    } else { "  sdk: WARNING - NukeUtils\bin\NukeGen.exe not built; module reflection needs it" }

    # The engine's public dependencies, for vcpkg manifest mode on the consumer's machine.
    Set-Content -Path (Join-Path $sdkDir "vcpkg.json") -Encoding utf8 -Value @'
{
  "name": "nukeengine-game-module",
  "version-string": "0.1",
  "dependencies": [ "boost", "nlohmann-json", "glm" ]
}
'@

    # Typed cross-module wrapper headers -> inside include\ so <nukesdk/X.sdk.h> resolves.
    $wrap = Join-Path $root "NukeUtils\sdk\nukesdk"
    if (Test-Path $wrap) { Copy-Item $wrap (Join-Path $sdkDir "include\nukesdk") -Recurse }

    # Generated API docs, when the doc step has produced them (SDK-5).
    $docs = Join-Path $root "NukeUtils\sdkdocs"
    if (Test-Path $docs) { Copy-Item $docs (Join-Path $sdkDir "docs") -Recurse }

    $sdkFiles = (Get-ChildItem $sdkDir -Recurse -File | Measure-Object).Count
    "Staged SDK -> $sdkDir ($sdkFiles files)"
}

# -Symbols: PDBs matching every staged exe/dll, pooled from the vcxproj output and the CMake
# module build dirs. Third-party DLLs have no PDBs here and are skipped silently.
if ($Symbols) {
    $symDir = Join-Path $dst "symbols"
    New-Item -ItemType Directory -Force -Path $symDir | Out-Null
    $pdbPool = @{}
    $poolDirs = @($src) + @(Get-ChildItem (Join-Path $root "build") -Recurse -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -eq $Config } | ForEach-Object { $_.FullName })
    foreach ($d in $poolDirs) {
        foreach ($p in Get-ChildItem $d -Filter *.pdb -File -ErrorAction SilentlyContinue) {
            if (-not $pdbPool.ContainsKey($p.BaseName)) { $pdbPool[$p.BaseName] = $p.FullName }
        }
    }
    $symCount = 0
    foreach ($bin in Get-ChildItem $dst -Recurse -File | Where-Object { $_.Extension -eq '.exe' -or $_.Extension -eq '.dll' }) {
        if ($pdbPool.ContainsKey($bin.BaseName)) {
            Copy-Item $pdbPool[$bin.BaseName] (Join-Path $symDir ($bin.BaseName + ".pdb")) -Force
            $symCount++
        }
    }
    "symbols: $symCount PDBs -> $symDir"
}
