#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
RUN_ROOT="$ROOT/.local/newmux-ghostty/latest"
XDG_HOME="$RUN_ROOT/xdg"
BRIDGE_SOCKET="${NEWMUX_UI_BRIDGE_SOCKET:-$RUN_ROOT/newmux-ui.sock}"
BRIDGE_LOG="$RUN_ROOT/newmux-ui-bridge.log"
BRIDGE_PID="$RUN_ROOT/newmux-ui-bridge.pid"
STATUS_FILE="${NEWMUX_UI_STATUS_FILE:-$RUN_ROOT/ui-status.json}"

if [ ! -x "$ROOT/bin/newmux" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi

NEWMUX_SOCKET=${NEWMUX_SOCKET:-newmux-dev}
NEWMUX_SOCKET_PATH=${NEWMUX_SOCKET_PATH_OVERRIDE:-${NEWMUX_SOCKET_PATH:-$ROOT/.local/nm-sock/$NEWMUX_SOCKET.sock}}

GHOSTTY_PROCESS_PATTERN='/Applications/Ghostty[.]app/Contents/MacOS/ghostty|/newmux/ghostty-macos-build/.*/Ghostty[.]app/Contents/MacOS/ghostty|ghostty.*ghostty-config/newmux[.]config'
STARTER_PROCESS_PATTERN="$ROOT/scripts/start-newmux-fresh[.]sh"
NEWMUX_PROCESS_PATTERN="$ROOT/bin/newmux .*config/newmux-dev[.]tmux[.]conf"

kill_matching_processes()
{
	pattern=$1
	pgrep -f "$pattern" 2>/dev/null |
		while IFS= read -r pid; do
			[ -n "$pid" ] || continue
			[ "$pid" != "$$" ] || continue
			kill "$pid" >/dev/null 2>&1 || true
		done
}

wait_for_no_matching_processes()
{
	pattern=$1
	waited_ms=0
	while [ "$waited_ms" -lt 2000 ]; do
		if ! pgrep -f "$pattern" >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.05
		waited_ms=$((waited_ms + 50))
	done
	return 1
}

kill_matching_processes "$GHOSTTY_PROCESS_PATTERN"
kill_matching_processes "$STARTER_PROCESS_PATTERN"
kill_matching_processes "$NEWMUX_PROCESS_PATTERN"
wait_for_no_matching_processes "$GHOSTTY_PROCESS_PATTERN" || true
wait_for_no_matching_processes "$STARTER_PROCESS_PATTERN" || true

if [ -f "$BRIDGE_PID" ]; then
	OLD_BRIDGE_PID=$(cat "$BRIDGE_PID" 2>/dev/null || true)
	if [ -n "$OLD_BRIDGE_PID" ]; then
		kill "$OLD_BRIDGE_PID" >/dev/null 2>&1 || true
	fi
fi
pgrep -f "$ROOT/scripts/newmux-ui-bridge.py serve .*--socket-name $NEWMUX_SOCKET" 2>/dev/null |
	while IFS= read -r OLD_BRIDGE_PID; do
		[ -n "$OLD_BRIDGE_PID" ] || continue
		kill "$OLD_BRIDGE_PID" >/dev/null 2>&1 || true
	done
rm -rf "$RUN_ROOT"
NEWMUX_SOCKET_PATH=${NEWMUX_SOCKET_PATH_OVERRIDE:-${NEWMUX_SOCKET_PATH:-$ROOT/.local/nm-sock/$NEWMUX_SOCKET.sock}}
rm -rf "$ROOT/.local/newmux-runtime/$NEWMUX_SOCKET"
rm -rf "$ROOT/.local/newmux-runtime/$(basename -- "$NEWMUX_SOCKET_PATH" .sock)"
mkdir -p "$XDG_HOME/ghostty" "$(dirname -- "$NEWMUX_SOCKET_PATH")"
: > "$XDG_HOME/ghostty/config"
printf '%s\n' "$NEWMUX_SOCKET_PATH" > "$RUN_ROOT/socket-path"
printf '%s\n' "$STATUS_FILE" > "$RUN_ROOT/ui-status-path"
rm -f "$BRIDGE_SOCKET"

NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
	"$ROOT/scripts/start-newmux-fresh.sh" kill-only >/dev/null 2>&1 || true
rm -f "$NEWMUX_SOCKET_PATH"
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
GHOSTTY_LAUNCH_PATH=${NEWMUX_GHOSTTY_LAUNCH_PATH:-"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"}

if [ "$(uname)" = Darwin ] && [ -d "$PATCHED_GHOSTTY_APP" ] && \
	{ [ "$USE_PATCHED_GHOSTTY" = 1 ] || [ -n "${NEWMUX_GHOSTTY_APP:-}" ]; }; then
	if [ "${NEWMUX_GHOSTTY_USE_OPEN:-0}" != 1 ]; then
		(
			exec env XDG_CONFIG_HOME="$XDG_HOME" \
				PATH="$GHOSTTY_LAUNCH_PATH" \
				NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
				NEWMUX_SOCKET="$NEWMUX_SOCKET" \
				NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
				NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
				NEWMUX_GHOSTTY_UI="${NEWMUX_GHOSTTY_UI:-}" \
				NEWMUX_GHOSTTY_UI_STATUS="${NEWMUX_GHOSTTY_UI_STATUS:-}" \
				NEWMUX_UI_STATUS_FILE="$STATUS_FILE" \
				NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
				NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
				"$PATCHED_GHOSTTY_APP/Contents/MacOS/ghostty" \
				--config-file="$ROOT/ghostty-config/newmux.config"
		) >/dev/null 2>&1 &
		exit 0
	fi
	exec open \
		--env "XDG_CONFIG_HOME=$XDG_HOME" \
		--env "PATH=$GHOSTTY_LAUNCH_PATH" \
		--env "NEWMUX_USER_ZSHRC_SOURCED=${NEWMUX_USER_ZSHRC_SOURCED:-}" \
		--env "NEWMUX_SOCKET=$NEWMUX_SOCKET" \
		--env "NEWMUX_SOCKET_PATH=$NEWMUX_SOCKET_PATH" \
		--env "NEWMUX_UI_BRIDGE_SOCKET=$BRIDGE_SOCKET" \
		--env "NEWMUX_GHOSTTY_UI=${NEWMUX_GHOSTTY_UI:-}" \
		--env "NEWMUX_GHOSTTY_UI_STATUS=${NEWMUX_GHOSTTY_UI_STATUS:-}" \
		--env "NEWMUX_UI_STATUS_FILE=$STATUS_FILE" \
		--env "NEWMUX_RESTORE_TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}" \
		--env "NEWMUX_GHOSTTY_SKIP_LOGIN=1" \
		-na "$PATCHED_GHOSTTY_APP" \
		--args --config-file="$ROOT/ghostty-config/newmux.config"
elif [ "$(uname)" = Darwin ] && [ "$USE_PATCHED_GHOSTTY" = 1 ]; then
	echo "patched Ghostty app not found: $PATCHED_GHOSTTY_APP" >&2
	echo "run ./scripts/build-ghostty.sh or set NEWMUX_GHOSTTY_APP" >&2
	exit 1
elif [ "$(uname)" = Darwin ] && [ -d /Applications/Ghostty.app ]; then
	if [ "${NEWMUX_GHOSTTY_BACKGROUND:-0}" = 1 ]; then
			(
				exec env XDG_CONFIG_HOME="$XDG_HOME" \
				PATH="$GHOSTTY_LAUNCH_PATH" \
					NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
				NEWMUX_SOCKET="$NEWMUX_SOCKET" \
				NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
				NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
				NEWMUX_GHOSTTY_UI="${NEWMUX_GHOSTTY_UI:-}" \
				NEWMUX_GHOSTTY_UI_STATUS="${NEWMUX_GHOSTTY_UI_STATUS:-}" \
				NEWMUX_UI_STATUS_FILE="$STATUS_FILE" \
				NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
				NEWMUX_GHOSTTY_SKIP_LOGIN=1 \
				/Applications/Ghostty.app/Contents/MacOS/ghostty \
				--config-file="$ROOT/ghostty-config/newmux.config"
		) >/dev/null 2>&1 &
		exit 0
	fi
		exec open \
			--env "XDG_CONFIG_HOME=$XDG_HOME" \
			--env "PATH=$GHOSTTY_LAUNCH_PATH" \
			--env "NEWMUX_USER_ZSHRC_SOURCED=${NEWMUX_USER_ZSHRC_SOURCED:-}" \
			--env "NEWMUX_SOCKET=$NEWMUX_SOCKET" \
		--env "NEWMUX_SOCKET_PATH=$NEWMUX_SOCKET_PATH" \
		--env "NEWMUX_UI_BRIDGE_SOCKET=$BRIDGE_SOCKET" \
		--env "NEWMUX_GHOSTTY_UI=${NEWMUX_GHOSTTY_UI:-}" \
		--env "NEWMUX_GHOSTTY_UI_STATUS=${NEWMUX_GHOSTTY_UI_STATUS:-}" \
		--env "NEWMUX_UI_STATUS_FILE=$STATUS_FILE" \
		--env "NEWMUX_RESTORE_TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}" \
		--env "NEWMUX_GHOSTTY_SKIP_LOGIN=1" \
		-na Ghostty.app \
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
	PATH="$GHOSTTY_LAUNCH_PATH" \
	NEWMUX_USER_ZSHRC_SOURCED="${NEWMUX_USER_ZSHRC_SOURCED:-}" \
	NEWMUX_SOCKET="$NEWMUX_SOCKET" \
	NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
	NEWMUX_UI_BRIDGE_SOCKET="$BRIDGE_SOCKET" \
	NEWMUX_GHOSTTY_UI="${NEWMUX_GHOSTTY_UI:-}" \
	NEWMUX_GHOSTTY_UI_STATUS="${NEWMUX_GHOSTTY_UI_STATUS:-}" \
	NEWMUX_UI_STATUS_FILE="$STATUS_FILE" \
	NEWMUX_RESTORE_TRACE_FILE="${NEWMUX_RESTORE_TRACE_FILE:-}" \
	NEWMUX_GHOSTTY_SKIP_LOGIN=1 "$GHOSTTY" \
	--config-file="$ROOT/ghostty-config/newmux.config"
