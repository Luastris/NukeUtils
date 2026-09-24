#!/bin/sh
# POSIX counterpart of stage_release.ps1 — assemble a clean, shippable runtime for one
# config into dist/<Config>/. Copies exe/dylib(+.app)/modules + data (shaders/config/fonts)
# from the build output, excluding dev artifacts, the Intermediate scratch dir and PROJECTS
# (any top-level dir with a .nuproj inside is a game project — user data, never shipped).
#
# Modes:
#   Full    (default) — everything shippable: all modules, script runtimes, caches.
#   Minimal           — bare boot set: exes + root runtime dylibs + renderer module
#                       + shaders/fonts/config/res. No optional modules, no managed,
#                       no plugins/, no shader cache, no imgui.ini.
#   --sdk (orthogonal) — additionally stage dist/<Config>/sdk/: the C++ game-module kit
#                       (engine headers, engine/ImGui dylibs for BOTH configs when built,
#                       NukeGen, the vcpkg manifest).
#
#   NukeUtils/stage_release.sh --config Release
#   NukeUtils/stage_release.sh --config Release --mode Minimal
#   NukeUtils/stage_release.sh --config Release --mode Minimal --sdk
#   NukeUtils/stage_release.sh --mode Minimal --minimal-modules "NukeRenderDiligent.dylib NukeScript.dylib"
#   --tech (orthogonal) — the vendor upscaling / frame-generation runtimes to ship: all, none, or a
#                       comma list of dlss, fsr, xess. Full ships all, Minimal ships none unless given.
#                       (The vendors ship those runtimes for Windows only; the switch is here for the
#                       same interface on every platform.)
#   NukeUtils/stage_release.sh --config Release --tech dlss,fsr
set -eu

CONFIG="Release"
MODE="Full"
SDK=0
OUTNAME=""
# Native module extension: .dylib on macOS, .so elsewhere (matches the CMake PREFIX "" naming).
case "$(uname -s)" in Darwin) MODEXT=dylib ;; *) MODEXT=so ;; esac
MINIMAL_MODULES="NukeRenderDiligent.$MODEXT"
TECH=""

while [ $# -gt 0 ]; do
	case "$1" in
		--config)          CONFIG="$2"; shift 2 ;;
		--mode)            MODE="$2"; shift 2 ;;
		--sdk)             SDK=1; shift ;;
		--outname)         OUTNAME="$2"; shift 2 ;;
		--minimal-modules) MINIMAL_MODULES="$2"; shift 2 ;;
		--tech)            TECH="$2"; shift 2 ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done
case "$MODE" in Full|Minimal) ;; *) echo "--mode must be Full or Minimal" >&2; exit 2 ;; esac

# Vendor runtimes by technology (the same set the editor's Package Project dialog toggles).
if [ -z "$TECH" ]; then
	if [ "$MODE" = "Full" ]; then TECH="all"; else TECH="none"; fi
fi
TECH_ON=""
for t in $(echo "$TECH" | tr 'A-Z,' 'a-z '); do
	case "$t" in
		all)  TECH_ON=" dlss fsr xess " ;;
		none) TECH_ON="" ;;
		dlss|fsr|xess) TECH_ON="$TECH_ON $t " ;;
		*) echo "--tech: unknown technology '$t' (all, none, dlss, fsr, xess)" >&2; exit 2 ;;
	esac
done
# The technology a vendor runtime belongs to ("" = not a vendor runtime).
tech_of() {
	case "$1" in
		nvngx_dlss.dll|sl.interposer.dll|sl.common.dll|sl.dlss_g.dll|sl.reflex.dll|sl.pcl.dll|nvngx_dlssg.dll|NvLowLatencyVk.dll) echo dlss ;;
		amd_fidelityfx_upscaler_dx12.dll|amd_fidelityfx_framegeneration_dx12.dll|amd_fidelityfx_vk.dll) echo fsr ;;
		libxess.dll|libxess_fg.dll|libxell.dll) echo xess ;;
		*) echo "" ;;
	esac
}
echo "Vendor tech:${TECH_ON:- none}"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Run-dir subfolder: "macos"/"linux" here (Windows' x64 tree is staged by stage_release.ps1).
case "$(uname -s)" in Darwin) RUNSUB=macos ;; *) RUNSUB=linux ;; esac
SRC="$ROOT/NukeEngine/$RUNSUB/$CONFIG"
[ -n "$OUTNAME" ] || OUTNAME="$CONFIG"
DST="$ROOT/dist/$OUTNAME"

[ -d "$SRC" ] || { echo "build output not found: $SRC  (build $CONFIG first)" >&2; exit 1; }

# Projects are detected, not hardcoded: any top-level dir carrying a .nuproj is a game project.
PROJECT_DIRS=""
for d in "$SRC"/*/; do
	[ -d "$d" ] || continue
	if ls "$d"/*.nuproj >/dev/null 2>&1; then
		PROJECT_DIRS="$PROJECT_DIRS $(basename "$d")"
	fi
done
[ -z "$PROJECT_DIRS" ] || echo "Excluding project dirs:$PROJECT_DIRS"

rm -rf "$DST"
mkdir -p "$DST"

FILES=0; BYTES=0; SKIPPED=0
# Dev artifacts (never shipped): symbol/link leftovers on either toolchain.
is_dev_artifact() {
	case "$1" in
		*.pdb|*.lib|*.exp|*.ilk|*.iobj|*.ipdb|*.obj|*.pch|*.log|*.tlog|*.a|*.o|.DS_Store|*/.DS_Store) return 0 ;;
		*-gd-*) return 0 ;;   # defensive: never ship debug-variant deps
	esac
	case "$1" in *.dSYM/*) return 0 ;; esac
	return 1
}

# find prints run-dir-relative paths; .app bundles are walked file by file (structure kept).
cd "$SRC"
find . -type f | sed 's|^\./||' | while IFS= read -r rel; do
	top=${rel%%/*}
	name=$(basename "$rel")
	[ "$top" = "Intermediate" ] && continue                       # build scratch
	case " $PROJECT_DIRS " in *" $top "*) continue ;; esac        # game projects: never shipped
	is_dev_artifact "$rel" && continue

	# Vendor upscaler / frame-generation runtimes: --tech alone decides, in every mode and folder.
	tech=$(tech_of "$name")
	if [ -n "$tech" ]; then
		case "$TECH_ON" in *" $tech "*) ;; *) continue ;; esac
	elif [ "$MODE" = "Minimal" ]; then
		[ "$top" = "plugins" ] && continue                        # script runtimes (script modules')
		[ "$rel" = "imgui.ini" ] && continue                      # editor session layout, per-machine
		# config/: keep main.json only — shadercache/mods are machine/session data.
		if [ "$top" = "config" ] && [ "$rel" != "config/main.json" ]; then continue; fi
		# modules/: whitelist only (managed/ and optional module dylibs stay behind).
		if [ "$top" = "modules" ]; then
			case "$rel" in modules/*/*) continue ;; esac
			case " $MINIMAL_MODULES " in *" $name "*) ;; *) continue ;; esac
		fi
	fi

	mkdir -p "$DST/$(dirname "$rel")"
	cp -p "$rel" "$DST/$rel"
done
FILES=$(find "$DST" -type f | wc -l | tr -d ' ')
BYTES=$(du -sk "$DST" | cut -f1)
echo "Staged $CONFIG ($MODE) -> $DST"
echo "  $FILES files, $((BYTES / 1024)) MB"
# Architecture report — say what got staged, never make anyone guess.
if command -v lipo >/dev/null 2>&1 && [ -f "$DST/NukePlayer" ]; then
	echo "  architectures: $(lipo -archs "$DST/NukePlayer" 2>/dev/null || echo unknown)"
elif [ -f "$DST/NukePlayer" ] && command -v file >/dev/null 2>&1; then
	echo "  architectures: $(file -b "$DST/NukePlayer" | sed -n 's/.*ELF 64-bit LSB [a-z ]*, \([^,]*\),.*/\1/p')"
fi

# ---- --sdk: the C++ game-module kit ------------------------------------------------------
# Headers + the engine/ImGui dylibs per built config (modules link the dylib directly on
# Mach-O/ELF — no import libs) + NukeGen + the vcpkg manifest for the consumer's machine.
if [ "$SDK" = 1 ]; then
	SDKDIR="$DST/sdk"
	rm -rf "$SDKDIR"
	mkdir -p "$SDKDIR"

	# Headers (the whole public include tree — that IS the API surface); prune empty dirs.
	cp -R "$ROOT/NukeEngine/include" "$SDKDIR/include"
	find "$SDKDIR/include" -type d -empty -delete

	for cfg in Debug Release; do
		any=0
		for lib in libNukeEngine.dylib libNukeImGui.dylib libNukeEngine.so libNukeImGui.so; do
			lp="$ROOT/NukeEngine/$RUNSUB/$cfg/$lib"
			if [ -f "$lp" ]; then
				[ "$any" = 1 ] || mkdir -p "$SDKDIR/lib/$cfg"
				any=1
				cp -p "$lp" "$SDKDIR/lib/$cfg/$lib"
			fi
		done
		[ "$any" = 1 ] || echo "  sdk: $cfg libs not built - lib/$cfg skipped"
	done

	# The native reflection generator (bare name off Windows; .exe is a Windows-ism).
	GEN="$ROOT/NukeUtils/bin/NukeGen"
	if [ -f "$GEN" ]; then
		mkdir -p "$SDKDIR/bin"
		cp -p "$GEN" "$SDKDIR/bin/NukeGen"
	else
		echo "  sdk: WARNING - NukeUtils/bin/NukeGen not built; module reflection needs it"
	fi

	# The engine's public dependencies, for vcpkg manifest mode on the consumer's machine.
	cat > "$SDKDIR/vcpkg.json" <<'EOF'
{
  "name": "nukeengine-game-module",
  "version-string": "0.1",
  "dependencies": [ "boost", "nlohmann-json", "glm" ]
}
EOF

	# Typed cross-module wrapper headers -> inside include/ so <nukesdk/X.sdk.h> resolves.
	[ -d "$ROOT/NukeUtils/sdk/nukesdk" ] && cp -R "$ROOT/NukeUtils/sdk/nukesdk" "$SDKDIR/include/nukesdk"
	# Generated API docs, when the doc step has produced them.
	[ -d "$ROOT/NukeUtils/sdkdocs" ] && cp -R "$ROOT/NukeUtils/sdkdocs" "$SDKDIR/docs"

	SDKFILES=$(find "$SDKDIR" -type f | wc -l | tr -d ' ')
	echo "Staged SDK -> $SDKDIR ($SDKFILES files)"
fi
