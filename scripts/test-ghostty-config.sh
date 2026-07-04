#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CONFIG="$ROOT/ghostty-config/newmux.config"
CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
PATCHED_GHOSTTY=${NEWMUX_GHOSTTY_BIN:-"$CACHE_HOME/newmux/ghostty-macos-build/$GHOSTTY_CONFIGURATION/Ghostty.app/Contents/MacOS/ghostty"}
USE_PATCHED_GHOSTTY=${NEWMUX_USE_PATCHED_GHOSTTY:-1}

if [ -x "$PATCHED_GHOSTTY" ] && \
	{ [ "$USE_PATCHED_GHOSTTY" = 1 ] || [ -n "${NEWMUX_GHOSTTY_BIN:-}" ]; }; then
	GHOSTTY=$PATCHED_GHOSTTY
elif command -v ghostty >/dev/null 2>&1; then
	GHOSTTY=ghostty
elif [ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]; then
	GHOSTTY=/Applications/Ghostty.app/Contents/MacOS/ghostty
else
	echo "Ghostty executable not found; skipping config validation" >&2
	exit 77
fi

"$GHOSTTY" +validate-config --config-file="$CONFIG"
echo "Ghostty config validated: $CONFIG"
