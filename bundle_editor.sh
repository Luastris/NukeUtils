#!/bin/sh
# bundle_editor.sh <run_dir> — make NukeEngine-Editor.app self-contained: mirror the run
# dir's runtime (player, dylibs, modules/, shaders/, fonts/) into Contents/MacOS.
# RunRoot() prefers the loose layout beside the .app, so the inner copies are only loaded
# by a bundle standing alone. config/, imgui.ini and project/ stay out (live dev state).
set -eu

RUN="$1"
APP="$RUN/NukeEngine-Editor.app"
MACOS="$APP/Contents/MacOS"

if [ ! -d "$MACOS" ]; then
    echo "bundle_editor: no editor bundle at $APP" >&2
    exit 1
fi

# Player + every dylib as siblings of the executable (@rpath/@loader_path resolves there).
for f in "$RUN"/*.dylib "$RUN/NukePlayer"; do
    if [ -f "$f" ]; then
        cp -pf "$f" "$MACOS/"
    fi
done

# Runtime dirs, mirrored (stale bundle copies of removed files must not linger).
for d in modules shaders fonts; do
    if [ -d "$RUN/$d" ]; then
        rsync -a --delete "$RUN/$d/" "$MACOS/$d/"
    fi
done
