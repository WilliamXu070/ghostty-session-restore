#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
GHOSTTY_SRC="$ROOT/ghostty-src"
ZIG=${ZIG:-}
GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
if [ -n "${NEWMUX_GHOSTTY_ZIG_OPTIMIZE:-}" ]; then
	GHOSTTY_ZIG_OPTIMIZE=$NEWMUX_GHOSTTY_ZIG_OPTIMIZE
else
	case "$GHOSTTY_CONFIGURATION" in
		Debug) GHOSTTY_ZIG_OPTIMIZE=Debug ;;
		*) GHOSTTY_ZIG_OPTIMIZE=ReleaseFast ;;
	esac
fi

if [ ! -d "$GHOSTTY_SRC" ]; then
	echo "ghostty-src/ was not found." >&2
	exit 1
fi

if [ -z "$ZIG" ]; then
	if command -v zig >/dev/null 2>&1; then
		ZIG=$(command -v zig)
	elif [ -x /opt/homebrew/opt/zig@0.15/bin/zig ]; then
		ZIG=/opt/homebrew/opt/zig@0.15/bin/zig
	else
		echo "zig was not found." >&2
		echo "Install the Ghostty-supported Zig with: brew install zig@0.15" >&2
		exit 1
	fi
fi

if ! command -v nu >/dev/null 2>&1; then
	echo "nu was not found." >&2
	echo "Install Nushell with: brew install nushell" >&2
	exit 1
fi

if [ "$(uname)" != Darwin ]; then
	echo "The local Ghostty app build is only supported on macOS." >&2
	exit 1
fi

echo "Building Ghostty core with $("$ZIG" version) ($GHOSTTY_ZIG_OPTIMIZE)..."
cd "$GHOSTTY_SRC"
"$ZIG" build -Demit-macos-app=false "-Doptimize=$GHOSTTY_ZIG_OPTIMIZE"

echo "Building Ghostty.app..."
cd "$GHOSTTY_SRC/macos"
CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
export NEWMUX_GHOSTTY_SYMROOT=${NEWMUX_GHOSTTY_SYMROOT:-"$CACHE_HOME/newmux/ghostty-macos-build"}
mkdir -p "$NEWMUX_GHOSTTY_SYMROOT"
xattr -cr . "$NEWMUX_GHOSTTY_SYMROOT" 2>/dev/null || true
./build.nu --scheme Ghostty --configuration "$GHOSTTY_CONFIGURATION" --action build

APP="$NEWMUX_GHOSTTY_SYMROOT/$GHOSTTY_CONFIGURATION/Ghostty.app"
if [ ! -d "$APP" ]; then
	echo "Expected app was not created: $APP" >&2
	exit 1
fi

echo "Built patched Ghostty app:"
echo "  $APP"
