#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUN_ROOT="$ROOT/.local/newmux-ghostty/latest"
XDG_HOME="$RUN_ROOT/xdg"
BRIDGE_SOCKET="$RUN_ROOT/newmux-ui.sock"
BRIDGE_LOG="$RUN_ROOT/newmux-ui-bridge.log"
BRIDGE_PID="$RUN_ROOT/newmux-ui-bridge.pid"

if [ ! -x "$ROOT/bin/newmux" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi

if [ -f "$BRIDGE_PID" ]; then
	OLD_BRIDGE_PID=$(cat "$BRIDGE_PID" 2>/dev/null || true)
	if [ -n "$OLD_BRIDGE_PID" ]; then
		kill "$OLD_BRIDGE_PID" >/dev/null 2>&1 || true
	fi
fi
rm -rf "$RUN_ROOT"
mkdir -p "$XDG_HOME/ghostty"
: > "$XDG_HOME/ghostty/config"

NEWMUX_SOCKET=${NEWMUX_SOCKET:-newmux-dev}
NEWMUX_SOCKET_PATH=${NEWMUX_SOCKET_PATH:-}
"$ROOT/scripts/start-newmux-fresh.sh" kill-only >/dev/null 2>&1 || true
if [ -n "$NEWMUX_SOCKET_PATH" ]; then
	python3 "$ROOT/scripts/newmux-ui-bridge.py" serve \
		--socket-name "$NEWMUX_SOCKET" \
		--socket-path "$NEWMUX_SOCKET_PATH" \
		--bridge-socket "$BRIDGE_SOCKET" \
		>"$BRIDGE_LOG" 2>&1 &
else
	python3 "$ROOT/scripts/newmux-ui-bridge.py" serve \
		--socket-name "$NEWMUX_SOCKET" \
		--bridge-socket "$BRIDGE_SOCKET" \
		>"$BRIDGE_LOG" 2>&1 &
fi
echo "$!" > "$BRIDGE_PID"

CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
PATCHED_GHOSTTY_APP=${NEWMUX_GHOSTTY_APP:-"$CACHE_HOME/newmux/ghostty-macos-build/Debug/Ghostty.app"}
USE_PATCHED_GHOSTTY=${NEWMUX_USE_PATCHED_GHOSTTY:-1}

if [ "$(uname)" = Darwin ] && [ -d "$PATCHED_GHOSTTY_APP" ] && \
	{ [ "$USE_PATCHED_GHOSTTY" = 1 ] || [ -n "${NEWMUX_GHOSTTY_APP:-}" ]; }; then
	if [ "${NEWMUX_GHOSTTY_BACKGROUND:-0}" = 1 ]; then
			(
				exec env XDG_CONFIG_HOME="$XDG_HOME" \
					NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
					NEWMUX_SOCKET="$NEWMUX_SOCKET" \
				NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
				NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
				NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
				NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
				"$PATCHED_GHOSTTY_APP/Contents/MacOS/ghostty" \
				--config-file="$ROOT/ghostty-config/newmux.config"
		) >/dev/null 2>&1 &
		exit 0
	fi
		exec open -na "$PATCHED_GHOSTTY_APP" \
			--env XDG_CONFIG_HOME="$XDG_HOME" \
			--env PATH="$PATH" \
			--env NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
			--env NEWMUX_SOCKET="$NEWMUX_SOCKET" \
		--env NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
		--env NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
		--env NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
		--env NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
		--args --config-file="$ROOT/ghostty-config/newmux.config"
elif [ "$(uname)" = Darwin ] && [ -d /Applications/Ghostty.app ]; then
	if [ "${NEWMUX_GHOSTTY_BACKGROUND:-0}" = 1 ]; then
			(
				exec env XDG_CONFIG_HOME="$XDG_HOME" \
					NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
					NEWMUX_SOCKET="$NEWMUX_SOCKET" \
				NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
				NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
				NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
				NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
				/Applications/Ghostty.app/Contents/MacOS/ghostty \
				--config-file="$ROOT/ghostty-config/newmux.config"
		) >/dev/null 2>&1 &
		exit 0
	fi
		exec open -na Ghostty.app \
			--env XDG_CONFIG_HOME="$XDG_HOME" \
			--env PATH="$PATH" \
			--env NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
			--env NEWMUX_SOCKET="$NEWMUX_SOCKET" \
		--env NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
		--env NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
		--env NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
		--env NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
		--args --config-file="$ROOT/ghostty-config/newmux.config"
elif command -v ghostty >/dev/null 2>&1; then
	GHOSTTY=ghostty
elif [ -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]; then
	GHOSTTY=/Applications/Ghostty.app/Contents/MacOS/ghostty
else
	echo "ghostty CLI was not found on PATH." >&2
	echo "The macOS app executable was not found either." >&2
	echo "After installing Ghostty, open this profile with:" >&2
	echo "  ghostty --config-file=$ROOT/ghostty-config/newmux.config" >&2
	exit 1
fi

exec env XDG_CONFIG_HOME="$XDG_HOME" \
	NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
	NEWMUX_SOCKET="$NEWMUX_SOCKET" \
	NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
	NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
	NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
	NEWMUX_GHOSTTY_SKIP_LOGIN=1 "$GHOSTTY" \
	--config-file="$ROOT/ghostty-config/newmux.config"
