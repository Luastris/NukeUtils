# NukeUtils

The tooling of [NukeEngine](https://github.com/Luastris/NukeEngine-Eco): the reflection
generator every module builds with, the release staging that assembles a shippable runtime,
and the platform bundling scripts. Sources only — `bin/`, `sdk/` and `sdkdocs/` are build
products the superbuild reproduces (see `.gitignore`).

## NukeGen (`NukeGen/`)

The native reflection generator: scans `NUKE_CLASS` / `NUKE_CLASS_NOCREATE` and the
`[[nuke::prop]]` / `[[nuke::func]]` attributes of a module's public headers and emits the
registration TU as a pre-build step. Static CRT, no runtime dependencies: the SDK ships it as
one exe. Modes:

- **Engine** — `NukeGen --include <NukeEngine/include> --out <src/reflect/Reflect.gen.cpp>`.
- **Module** — emits an `.inc` the module `#include`s in-TU and calls from `OnLoad`:
  `NukeGen --include NukeScript/src --out NukeScript/src/NukeScript.gen.inc
  --init NukeReflectInit_NukeScript --scan-cpp --no-includes`.
- **`--sdk <out.sdk.h>`** — a typed wrapper header over the reflection registry so OTHER
  modules use this one's API without linking it (lands in `sdk/nukesdk/<Name>.sdk.h`).
- **`--doc <out.md>`** — the markdown API reference (lands in `sdkdocs/<Name>.md`, the
  source of the docs site's `docs/api/`).

The superbuild builds and deploys it to `bin/NukeGen.exe`; every `.gen.inc` / `.gen.cpp` in
the tree comes from it. `nukegen.py` is the original Python generator, kept for old project
CMakeLists.

## Release staging

`stage_release.ps1` (Windows) / `stage_release.sh` (POSIX) assemble a clean, shippable runtime
for one config into `dist/<Config>/`: exe / dll / `modules/` + data (`shaders`, `config`,
`fonts`), without dev artifacts, the `Intermediate` scratch dir or any game project (a
top-level dir with a `.nuproj` is the user's data, never part of the engine). PDBs stay in
the build folder. `-Mode Minimal` = the bare boot set; `-Sdk` additionally stages the C++
game-module kit (`sdk/`). `-Tech` picks the vendor upscaling / frame-generation runtimes
(DLSS: NGX + Streamline DLSS-G, FSR: FidelityFX D3D12 + Vulkan, XeSS: XeSS + XeSS-FG): `All`,
`None`, or a list such as `DLSS,FSR`; Full ships all of them, Minimal none, unless given. The
renderer loads them by name and offers only what it finds.

```
powershell -File NukeUtils\stage_release.ps1 -Config Release -Mode Minimal -Sdk
powershell -File NukeUtils\stage_release.ps1 -Config Release -Tech DLSS,FSR
```

## Platform scripts

- `build_linux.sh` — the whole Linux build in one command (`--deps` first time,
  `--release`, `--appimage`).
- `bundle_editor.sh` / `bundle_editor_linux.sh` — make the editor self-contained
  (`NukeEngine-Editor.app` / an AppImage-ready `AppDir`) by mirroring the run dir's runtime.
- `nukeicons.py` — builds the editor's file-type icon font + header from the Nerd Fonts
  symbols (MIT).

## License

NukeEngine License 1.1 — see `LICENSE.md`.
