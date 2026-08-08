#!/bin/sh
# bundle_editor_linux.sh <run_dir> [--appimage <out.AppImage>] — the Linux counterpart of
# bundle_editor.sh: mirror the run dir's runtime into NukeEngine-Editor.AppDir (flat layout,
# AppRun = the editor binary), self-contained and appimagetool-ready.
#
# Unlike the mac bundle, the STOCK config/ + imgui.ini seeds ship INSIDE the image: an
# AppImage mounts read-only, Config::writableDir() redirects every write to the XDG config
# home, and reload() falls back to these baseDir() seeds for defaults. The dev run dir is
# untouched — RunRoot() inside the mounted image is the image root itself.
#
# --appimage: additionally squash the AppDir into an AppImage. Needs appimagetool — from
# $NUKE_APPIMAGETOOL, or on PATH. Runs with extract-and-run so it works from within
# containers/AppImages (no FUSE needed).
# --strip: strip the binaries INSIDE the AppDir (distribution images; the run dir's own
# copies keep their symbols for gdb).
set -eu

RUN="$1"; shift
OUTIMG=""
DO_STRIP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--appimage) OUTIMG="$2"; shift 2 ;;
		--strip)    DO_STRIP=1; shift ;;
		*) echo "bundle_editor_linux: unknown option $1" >&2; exit 2 ;;
	esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APPDIR="$RUN/NukeEngine-Editor.AppDir"

if [ ! -f "$RUN/NukeEngine-Editor" ]; then
	echo "bundle_editor_linux: no editor binary at $RUN" >&2
	exit 1
fi

mkdir -p "$APPDIR"

# Editor + player + every root .so as siblings ($ORIGIN rpath resolves there).
for f in "$RUN/NukeEngine-Editor" "$RUN/NukePlayer" "$RUN"/*.so "$RUN"/*.so.*; do
	[ -f "$f" ] && cp -pf "$f" "$APPDIR/" || true
done

# Runtime dirs, mirrored (stale image copies of removed files must not linger).
for d in modules shaders fonts config; do
	if [ -d "$RUN/$d" ]; then
		rsync -a --delete "$RUN/$d/" "$APPDIR/$d/"
	fi
done
[ -f "$RUN/imgui.ini" ] && cp -pf "$RUN/imgui.ini" "$APPDIR/" || true

# AppImage identity: AppRun entry point, one .desktop at the root, the icon it names.
ln -sf NukeEngine-Editor "$APPDIR/AppRun"
if [ -f "$ROOT/NukeEngine-Editor/res/logo.png" ]; then
	cp -pf "$ROOT/NukeEngine-Editor/res/logo.png" "$APPDIR/nukeengine-editor.png"
	cp -pf "$ROOT/NukeEngine-Editor/res/logo.png" "$APPDIR/.DirIcon"
fi
cat > "$APPDIR/nukeengine-editor.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=NukeEngine Editor
Exec=NukeEngine-Editor %f
Icon=nukeengine-editor
Terminal=false
Categories=Development;IDE;
MimeType=application/x-nukeengine-project;application/x-nukeengine-package;application/x-nukeengine-mod;
EOF

if [ "$DO_STRIP" = 1 ]; then
	for f in "$APPDIR/NukeEngine-Editor" "$APPDIR/NukePlayer" "$APPDIR"/*.so "$APPDIR"/*.so.* "$APPDIR"/modules/*.so; do
		[ -f "$f" ] && strip -s "$f" 2>/dev/null || true
	done
fi

# The editor packs GAMES into AppImages at runtime — ship appimagetool inside the image
# (tools/) so an installed editor needs nothing from the host. Best-effort: a dev machine
# without the tool still gets a working editor (games then ship as loose AppDirs).
TOOL="${NUKE_APPIMAGETOOL:-$(command -v appimagetool || true)}"
if [ -n "$TOOL" ] && [ -f "$TOOL" ]; then
	mkdir -p "$APPDIR/tools"
	cp -pf "$TOOL" "$APPDIR/tools/appimagetool"
	chmod +x "$APPDIR/tools/appimagetool"
fi

echo "AppDir ready: $APPDIR"

if [ -n "$OUTIMG" ]; then
	TOOL="${NUKE_APPIMAGETOOL:-}"
	[ -n "$TOOL" ] || TOOL=$(command -v appimagetool || true)
	if [ -z "$TOOL" ]; then
		echo "bundle_editor_linux: appimagetool not found (set NUKE_APPIMAGETOOL or add to PATH)" >&2
		exit 1
	fi
	APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$(uname -m)" "$TOOL" "$APPDIR" "$OUTIMG"
	echo "AppImage ready: $OUTIMG"
fi
