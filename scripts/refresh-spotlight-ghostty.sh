#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}

GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
PATCHED_APP=${NEWMUX_PATCHED_GHOSTTY_APP:-"$CACHE_HOME/newmux/ghostty-macos-build/$GHOSTTY_CONFIGURATION/Ghostty.app"}
TARGET_APP=${NEWMUX_SPOTLIGHT_GHOSTTY_APP:-/Applications/Ghostty.app}
BACKUP_SUFFIX=${NEWMUX_SPOTLIGHT_GHOSTTY_BACKUP_SUFFIX:-.newmux-backup}
BUILD_GHOSTTY=${NEWMUX_GHOSTTY_BUILD:-1}
FORCE=${NEWMUX_GHOSTTY_BUILD_FORCE_REBUILD:-0}
CONFIG="$ROOT/ghostty-config/newmux.config"
MARKER="$ROOT/.local/newmux-ghostty-src-fingerprint"

source_fingerprint()
{
	(
		cd "$ROOT/ghostty-src"
		git rev-parse HEAD 2>/dev/null || true
		git diff --binary HEAD -- 2>/dev/null || true
		git ls-files --others --exclude-standard -z 2>/dev/null |
			xargs -0 shasum 2>/dev/null || true
		shasum "$ROOT/scripts/build-ghostty.sh" 2>/dev/null || true
	) | shasum | awk '{ print $1 }'
}

if [ "$(uname)" != Darwin ]; then
	echo "This script is macOS-only." >&2
	exit 1
fi

if [ ! -d "$ROOT/ghostty-src" ]; then
	echo "ghostty-src/ was not found in $ROOT" >&2
	exit 1
fi

if [ "$BUILD_GHOSTTY" != 0 ]; then
	current_fingerprint=$(source_fingerprint)
	stored_fingerprint=$(cat "$MARKER" 2>/dev/null || true)
	if [ "$FORCE" != 0 ] || [ ! -d "$PATCHED_APP" ] || \
		[ "$current_fingerprint" != "$stored_fingerprint" ]; then
		"$ROOT/scripts/build-ghostty.sh"
	fi
	mkdir -p "$(dirname -- "$MARKER")"
	echo "$current_fingerprint" > "$MARKER"
fi

if [ ! -x "$PATCHED_APP/Contents/MacOS/ghostty" ]; then
	echo "Patched Ghostty app not found at:" >&2
	echo "  $PATCHED_APP" >&2
	exit 1
fi

mkdir -p "$(dirname -- "$TARGET_APP")"
if [ -e "$TARGET_APP" ]; then
	if [ -L "$TARGET_APP" ]; then
		rm -f "$TARGET_APP"
	else
		backup="${TARGET_APP}${BACKUP_SUFFIX}"
		if [ ! -e "$backup" ]; then
			mv "$TARGET_APP" "$backup"
			echo "Backed up existing app to: $backup"
		else
			rm -rf "$TARGET_APP"
		fi
	fi
fi

cp -R "$PATCHED_APP" "$TARGET_APP"
if [ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]; then
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

"$TARGET_APP/Contents/MacOS/ghostty" +validate-config --config-file="$CONFIG" >/dev/null

echo "Spotlight target now points to patched Ghostty:"
echo "  $TARGET_APP"
