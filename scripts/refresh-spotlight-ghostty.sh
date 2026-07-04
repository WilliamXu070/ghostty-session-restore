#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}

GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
PATCHED_APP=${NEWMUX_PATCHED_GHOSTTY_APP:-"$CACHE_HOME/newmux/ghostty-macos-build/$GHOSTTY_CONFIGURATION/Ghostty.app"}
TARGET_APP=${NEWMUX_SPOTLIGHT_GHOSTTY_APP:-/Applications/Ghostty.app}
BACKUP_SUFFIX=${NEWMUX_SPOTLIGHT_GHOSTTY_BACKUP_SUFFIX:-.newmux-backup}
APP_BACKUP_DIR=${NEWMUX_SPOTLIGHT_GHOSTTY_BACKUP_DIR:-"$CACHE_HOME/newmux/app-backups"}
SPOTLIGHT_RUNTIME_ROOT=${NEWMUX_SPOTLIGHT_RUNTIME_ROOT:-"$CACHE_HOME/newmux/spotlight-runtime"}
BUILD_GHOSTTY=${NEWMUX_GHOSTTY_BUILD:-1}
FORCE=${NEWMUX_GHOSTTY_BUILD_FORCE_REBUILD:-0}
CONFIG="$ROOT/ghostty-config/newmux.config"
RUNTIME_CONFIG="$SPOTLIGHT_RUNTIME_ROOT/ghostty-config/newmux.config"
USER_GHOSTTY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
USER_GHOSTTY_CONFIG="$USER_GHOSTTY_DIR/config"
SOURCE_INCLUDE_LINE="config-file = $CONFIG"
RUNTIME_INCLUDE_LINE="config-file = $RUNTIME_CONFIG"
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

rewrite_paths()
{
	src=$1
	dst=$2
	ROOT_REPLACE=$ROOT RUNTIME_REPLACE=$SPOTLIGHT_RUNTIME_ROOT \
		perl -pe 's/\Q$ENV{ROOT_REPLACE}\E/$ENV{RUNTIME_REPLACE}/g' \
		"$src" > "$dst"
}

install_spotlight_runtime()
{
	if [ ! -x "$ROOT/bin/newmux" ]; then
		"$ROOT/scripts/build-newmux.sh"
	fi

	tmp="$SPOTLIGHT_RUNTIME_ROOT.tmp.$$"
	rm -rf "$tmp"
	mkdir -p "$tmp/bin" "$tmp/config" "$tmp/ghostty-config" "$tmp/scripts"

	cp "$ROOT/bin/newmux" "$tmp/bin/newmux"
	cp "$ROOT/scripts/start-newmux-fresh.sh" "$tmp/scripts/start-newmux-fresh.sh"
	cp "$ROOT/scripts/run-newmux.sh" "$tmp/scripts/run-newmux.sh"
	cp "$ROOT/scripts/build-newmux.sh" "$tmp/scripts/build-newmux.sh"
	cp "$ROOT/scripts/newmux-runtime.py" "$tmp/scripts/newmux-runtime.py"
	cp "$ROOT/scripts/newmux-ui-bridge.py" "$tmp/scripts/newmux-ui-bridge.py"
	cp "$ROOT/scripts/newmux-copy-to-clipboard.sh" "$tmp/scripts/newmux-copy-to-clipboard.sh"
	cp -R "$ROOT/config/newmux-zsh" "$tmp/config/newmux-zsh"
	rewrite_paths "$ROOT/config/newmux-dev.tmux.conf" "$tmp/config/newmux-dev.tmux.conf"
	rewrite_paths "$CONFIG" "$tmp/ghostty-config/newmux.config"
	chmod +x "$tmp/bin/newmux" "$tmp"/scripts/*

	rm -rf "$SPOTLIGHT_RUNTIME_ROOT.prev"
	if [ -e "$SPOTLIGHT_RUNTIME_ROOT" ]; then
		mv "$SPOTLIGHT_RUNTIME_ROOT" "$SPOTLIGHT_RUNTIME_ROOT.prev"
	fi
	mv "$tmp" "$SPOTLIGHT_RUNTIME_ROOT"
	rm -rf "$SPOTLIGHT_RUNTIME_ROOT.prev"
}

install_user_ghostty_config()
{
	mkdir -p "$USER_GHOSTTY_DIR"
	touch "$USER_GHOSTTY_CONFIG"
	cp "$USER_GHOSTTY_CONFIG" "$USER_GHOSTTY_CONFIG.newmux-backup"
	tmp="$USER_GHOSTTY_CONFIG.newmux-tmp"
	awk -v source="$SOURCE_INCLUDE_LINE" -v runtime="$RUNTIME_INCLUDE_LINE" '
		$0 == source { next }
		$0 == runtime { next }
		$0 == "# newmux development profile" { next }
		{ print }
	' "$USER_GHOSTTY_CONFIG" > "$tmp"
	{
		cat "$tmp"
		printf '\n# newmux development profile\n%s\n' "$RUNTIME_INCLUDE_LINE"
	} > "$USER_GHOSTTY_CONFIG"
	rm -f "$tmp"
}

move_existing_app_out_of_applications()
{
	app=$1
	[ -e "$app" ] || return 0
	mkdir -p "$APP_BACKUP_DIR"
	if [ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]; then
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
			-u "$app" >/dev/null 2>&1 || true
	fi
	mv "$app" "$APP_BACKUP_DIR/$(basename "$app").$(date +%Y%m%d-%H%M%S)"
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

install_spotlight_runtime
install_user_ghostty_config

mkdir -p "$(dirname -- "$TARGET_APP")"
move_existing_app_out_of_applications "${TARGET_APP}${BACKUP_SUFFIX}"
if [ -e "$TARGET_APP" ]; then
	if [ -L "$TARGET_APP" ]; then
		rm -f "$TARGET_APP"
	else
		move_existing_app_out_of_applications "$TARGET_APP"
	fi
fi

cp -R "$PATCHED_APP" "$TARGET_APP"
if [ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]; then
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP" >/dev/null 2>&1 || true
fi

"$TARGET_APP/Contents/MacOS/ghostty" +validate-config --config-file="$RUNTIME_CONFIG" >/dev/null

echo "Spotlight target now points to patched Ghostty:"
echo "  $TARGET_APP"
echo "Spotlight Newmux runtime:"
echo "  $SPOTLIGHT_RUNTIME_ROOT"
