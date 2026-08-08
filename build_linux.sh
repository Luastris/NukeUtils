#!/bin/sh
# build_linux.sh — the whole Linux build in one command.
#
#   NukeUtils/build_linux.sh                # configure + build Debug -> NukeEngine/linux/Debug
#   NukeUtils/build_linux.sh --release      # Release tree (build-linux-release; Package Project needs it)
#   NukeUtils/build_linux.sh --appimage     # ...and squash the editor into NukeEngine-Editor.AppImage
#   NukeUtils/build_linux.sh --deps         # one-time: vendored deps + the vcpkg install, then build
#   NukeUtils/build_linux.sh -j 8           # cap build parallelism
#
# Prerequisites (one-time, distro packages — see also the README's Quick start (Linux)):
#   Debian/Ubuntu:
#     sudo apt install build-essential cmake ninja-build git curl zip unzip tar pkg-config \
#       autoconf autoconf-archive automake libtool bison flex \
#       libx11-dev libxrandr-dev libxinerama-dev libxcursor-dev libxi-dev libxext-dev \
#       libxfixes-dev libxkbcommon-dev libwayland-dev wayland-protocols \
#       libgl1-mesa-dev libegl1-mesa-dev libvulkan-dev \
#       libasound2-dev libpulse-dev libudev-dev libdbus-1-dev
#   Fedora (classic):
#     sudo dnf install gcc-c++ cmake ninja-build git curl zip unzip tar pkgconf-pkg-config \
#       autoconf autoconf-archive automake libtool bison flex \
#       libX11-devel libXrandr-devel libXinerama-devel libXcursor-devel libXi-devel \
#       libXext-devel libXfixes-devel libxkbcommon-devel wayland-devel wayland-protocols-devel \
#       mesa-libGL-devel mesa-libEGL-devel vulkan-loader-devel \
#       alsa-lib-devel pulseaudio-libs-devel systemd-devel dbus-devel
#   Arch:
#     sudo pacman -S --needed base-devel cmake ninja git curl zip unzip tar autoconf-archive \
#       libx11 libxrandr libxinerama libxcursor libxi libxext libxfixes libxkbcommon \
#       wayland wayland-protocols mesa vulkan-icd-loader vulkan-headers alsa-lib libpulse dbus
#   Atomic Fedora (Bazzite/Silverblue/Kinoite): no dnf — build in a distrobox
#   (ubuntu:22.04 + the Debian/Ubuntu list); distrobox-export --bin cmake/ninja for the
#   editor's own File -> Build Engine.
#   Optional: dotnet-sdk-8.0 (NukeCSharp), zenity or kdialog (native file dialogs),
#   appimagetool on PATH (--appimage; the editor also ships its own copy in tools/).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=Debug
DO_APPIMAGE=0
DO_DEPS=0
JOBS=""

while [ $# -gt 0 ]; do
	case "$1" in
		--release)  CONFIG=Release; shift ;;
		--debug)    CONFIG=Debug; shift ;;
		--appimage) DO_APPIMAGE=1; shift ;;
		--deps)     DO_DEPS=1; shift ;;
		-j)         JOBS="$2"; shift 2 ;;
		*) echo "unknown option: $1 (see the header of this script)" >&2; exit 2 ;;
	esac
done

# ---- VCPKG_ROOT: same probe order as the editor's GUI-launch discovery -------------------
if [ -z "${VCPKG_ROOT:-}" ]; then
	for cand in "$HOME/vcpkg" "$HOME/projects/vcpkg" "$HOME/dev/vcpkg" /opt/vcpkg /usr/local/vcpkg; do
		[ -f "$cand/scripts/buildsystems/vcpkg.cmake" ] && { VCPKG_ROOT="$cand"; export VCPKG_ROOT; break; }
	done
fi
if [ -z "${VCPKG_ROOT:-}" ]; then
	echo "VCPKG_ROOT is not set and no vcpkg found in the common homes." >&2
	echo "  git clone https://github.com/microsoft/vcpkg ~/vcpkg && ~/vcpkg/bootstrap-vcpkg.sh" >&2
	echo "  export VCPKG_ROOT=\$HOME/vcpkg" >&2
	exit 1
fi
echo "VCPKG_ROOT: $VCPKG_ROOT"

# ---- --deps: vendored clones (idempotent) + the classic vcpkg install --------------------
if [ "$DO_DEPS" = 1 ]; then
	# DiligentCore: a plain clone at the pinned commit (NOT a git submodule, gitignored —
	# the Windows dev tree carries it the same way). Patches apply at configure time.
	DC="$ROOT/NukeRenderDiligent/deps/DiligentEngine/DiligentCore"
	if [ ! -d "$DC" ]; then
		PIN=$(grep -o '`[0-9a-f]\{40\}`' "$ROOT/NukeRenderDiligent/patches/README.md" | tr -d '\`')
		echo "DiligentCore: cloning at $PIN"
		git clone https://github.com/DiligentGraphics/DiligentCore.git "$DC"
		git -C "$DC" checkout "$PIN"
		git -C "$DC" submodule update --init --recursive
	fi
	# LuaBridge3 at the commit NukeScript records for it.
	LB="$ROOT/NukeScript/deps/LuaBridge3"
	if [ ! -d "$LB" ]; then
		PIN=$(git -C "$ROOT/NukeScript" ls-tree HEAD deps/LuaBridge3 | awk '{print $3}')
		echo "LuaBridge3: cloning at $PIN"
		git clone https://github.com/kunitoki/LuaBridge3.git "$LB"
		git -C "$LB" checkout "$PIN"
	fi
	# Engine dependencies (classic mode; one long first run) + the ONE shared dynamic GLFW
	# every window-touching module loads, built with BOTH backends (X11 + Wayland).
	"$VCPKG_ROOT/vcpkg" install assimp boost-atomic boost-bind boost-chrono boost-config \
		boost-container boost-dll boost-filesystem boost-function boost-smart-ptr boost-system \
		boost-thread boost-tokenizer boost-tuple glfw3 glm lua meshoptimizer nlohmann-json \
		stb zstd zlib --triplet=x64-linux
	"$VCPKG_ROOT/vcpkg" install "glfw3[wayland]:x64-linux-dynamic" \
		--overlay-ports="$ROOT/vcpkg-overlays" --recurse
fi

# ---- configure + build -------------------------------------------------------------------
BLD="$ROOT/build-linux"; [ "$CONFIG" = Release ] && BLD="$ROOT/build-linux-release"
GEN=""
command -v ninja >/dev/null 2>&1 && GEN="-G Ninja"
# shellcheck disable=SC2086
cmake -S "$ROOT" -B "$BLD" $GEN -DCMAKE_BUILD_TYPE=$CONFIG
cmake --build "$BLD" --parallel ${JOBS:+$JOBS}

RUN="$ROOT/NukeEngine/linux/$CONFIG"
echo "Run dir: $RUN"

# ---- --appimage: squash the self-contained editor image ----------------------------------
if [ "$DO_APPIMAGE" = 1 ]; then
	sh "$ROOT/NukeUtils/bundle_editor_linux.sh" "$RUN" --appimage "$RUN/NukeEngine-Editor.AppImage"
fi
