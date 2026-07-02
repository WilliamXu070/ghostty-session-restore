#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REAL_PROFILE="$ROOT/ghostty-config/newmux.config"
RUN_ROOT="$ROOT/.local/codex-resume-scroll-test/latest"
TMP_CONFIG="$RUN_ROOT/ghostty-codex-resume-test.config"
XDG_HOME="$RUN_ROOT/xdg"
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-codex-resume-test}

if [ ! -x "$ROOT/bin/newmux" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi

NEWMUX_SOCKET="$SOCKET_NAME" "$ROOT/scripts/start-newmux-fresh.sh" kill-only

PIDS=$(ps ax -o pid=,command= | awk \
	'/ghostty-codex-resume-test.config/ && !/awk/ { print $1 }')
if [ -n "$PIDS" ]; then
	kill $PIDS >/dev/null 2>&1 || true
fi

rm -rf "$RUN_ROOT"
mkdir -p "$RUN_ROOT" "$XDG_HOME/ghostty"
cp "$REAL_PROFILE" "$TMP_CONFIG"
: > "$XDG_HOME/ghostty/config"

perl -0pi -e '
	s/^title = .*$/title = Newmux Codex Resume Scroll Test/m;
	s#^input = raw:.*\n##mg;
	s#^command = .*$#command = /bin/zsh\ninput = raw:NEWMUX_SOCKET='"$SOCKET_NAME"' exec '"$ROOT"'/scripts/start-newmux-codex-resume-test.sh\\r#m;
' "$TMP_CONFIG"

CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
GHOSTTY_CONFIGURATION=${NEWMUX_GHOSTTY_CONFIGURATION:-ReleaseLocal}
PATCHED_GHOSTTY_APP=${NEWMUX_GHOSTTY_APP:-"$CACHE_HOME/newmux/ghostty-macos-build/$GHOSTTY_CONFIGURATION/Ghostty.app"}
PATCHED_GHOSTTY_BIN="$PATCHED_GHOSTTY_APP/Contents/MacOS/ghostty"
USE_PATCHED_GHOSTTY=${NEWMUX_USE_PATCHED_GHOSTTY:-0}

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
	exec env XDG_CONFIG_HOME="$XDG_HOME" ghostty --config-file="$TMP_CONFIG"
else
	echo "ghostty CLI was not found on PATH." >&2
	exit 1
fi
