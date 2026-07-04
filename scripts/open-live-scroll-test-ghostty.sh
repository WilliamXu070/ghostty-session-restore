#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REAL_PROFILE="$ROOT/ghostty-config/newmux.config"
RUN_ROOT="$ROOT/.local/live-scroll-test/latest"
TMP_CONFIG="$RUN_ROOT/ghostty-live-scroll-test.config"
XDG_HOME="$RUN_ROOT/xdg"
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-live-scroll-test}

if [ ! -x "$ROOT/bin/newmux" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT" "$XDG_HOME/ghostty"
cp "$REAL_PROFILE" "$TMP_CONFIG"
: > "$XDG_HOME/ghostty/config"

perl -0pi -e '
	s/^title = .*$/title = Newmux Live Scroll Test/m;
	s#^command = direct:.*$#command = direct:'"$ROOT"'/scripts/start-newmux-live-scroll-test.sh#m;
	s#^input = raw:.*$#input = raw:NEWMUX_SOCKET='"$SOCKET_NAME"' exec '"$ROOT"'/scripts/start-newmux-live-scroll-test.sh\\r#m;
' "$TMP_CONFIG"

CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
PATCHED_GHOSTTY_APP=${NEWMUX_GHOSTTY_APP:-"$CACHE_HOME/newmux/ghostty-macos-build/$GHOSTTY_CONFIGURATION/Ghostty.app"}
PATCHED_GHOSTTY_BIN="$PATCHED_GHOSTTY_APP/Contents/MacOS/ghostty"
USE_PATCHED_GHOSTTY=${NEWMUX_USE_PATCHED_GHOSTTY:-0}

launch_ghostty()
{
	nohup env XDG_CONFIG_HOME="$XDG_HOME" "$1" --config-file="$TMP_CONFIG" \
		>/dev/null 2>&1 &
}

if [ "$(uname)" = Darwin ] && [ -x "$PATCHED_GHOSTTY_BIN" ] && \
	{ [ "$USE_PATCHED_GHOSTTY" = 1 ] || [ -n "${NEWMUX_GHOSTTY_APP:-}" ]; }; then
	exec open -na "$PATCHED_GHOSTTY_APP" \
		--env XDG_CONFIG_HOME="$XDG_HOME" \
		--args --config-file="$TMP_CONFIG"
elif [ "$(uname)" = Darwin ] && [ -d /Applications/Ghostty.app ]; then
	exec open -na Ghostty.app \
		--env XDG_CONFIG_HOME="$XDG_HOME" \
		--args --config-file="$TMP_CONFIG"
elif command -v ghostty >/dev/null 2>&1; then
	launch_ghostty "$(command -v ghostty)"
else
	echo "ghostty CLI was not found on PATH." >&2
	exit 1
fi
