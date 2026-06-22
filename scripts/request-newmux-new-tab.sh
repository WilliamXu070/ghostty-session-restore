#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOCKET_PATH=${1:-}
TARGET_PANE=${2:-}
PRIMARY_SESSION=${NEWMUX_SESSION:-newmux}
SOCKET_NAME=${NEWMUX_SOCKET:-}
if [ -z "$SOCKET_NAME" ]; then
	if [ -n "$SOCKET_PATH" ]; then
		SOCKET_NAME=$(basename "$SOCKET_PATH")
		SOCKET_NAME=${SOCKET_NAME%.sock}
	else
		SOCKET_NAME=newmux-dev
	fi
fi
EXPLICIT_SOCKET_PATH=${NEWMUX_SOCKET_PATH:-$SOCKET_PATH}
MARKER="${TMPDIR:-/tmp}/newmux-restore-tab-$(id -u)-$SOCKET_NAME"
REQUEST_LOCK_DIR="$MARKER.new-tab-lock"
REQUEST_DEBOUNCE_MS=${NEWMUX_NEW_TAB_REQUEST_DEBOUNCE_MS:-0}
REQUEST_STAMP="$MARKER.new-tab-requested"
OPEN_TAB_DELAY_SECONDS=${NEWMUX_NEW_TAB_OPEN_DELAY_SECONDS:-0}
RECORD_KEY_EVENTS=${NEWMUX_RECORD_KEY_EVENTS:-0}
TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}

newmux_cmd()
{
	if [ -n "$EXPLICIT_SOCKET_PATH" ]; then
		"$ROOT/bin/newmux" -S "$EXPLICIT_SOCKET_PATH" "$@"
		return
	fi
	"$ROOT/bin/newmux" -L "$SOCKET_NAME" "$@"
}

now_ms()
{
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
	else
		printf '%s000\n' "$(date +%s)"
	fi
}

trace_new_tab()
{
	[ -n "$TRACE_FILE" ] || return 0
	{
		printf '%s\tnew-tab\tpid=%s\t%s' "$(now_ms)" "$$" "$1"
		if [ $# -gt 1 ]; then
			shift
			printf '\t%s' "$@"
		fi
		printf '\n'
	} >> "$TRACE_FILE" 2>/dev/null || true
}

request_was_recent()
{
	[ -f "$REQUEST_STAMP" ] || return 1
	stamp=$(cat "$REQUEST_STAMP" 2>/dev/null || true)
	case "$stamp" in
		''|*[!0-9]*)
			rm -f "$REQUEST_STAMP"
			return 1
			;;
	esac
	now=$(now_ms)
	if [ $((now - stamp)) -le "$REQUEST_DEBOUNCE_MS" ]; then
		return 0
	fi
	rm -f "$REQUEST_STAMP"
	return 1
}

open_ghostty_surface()
{
	if [ "$(uname)" != Darwin ] || [ "${NEWMUX_NEW_TAB_OPEN_TAB:-1}" = 0 ]; then
		trace_new_tab "open_ghostty_surface.skip"
		return 0
	fi

	if [ "$OPEN_TAB_DELAY_SECONDS" != 0 ]; then
		sleep "$OPEN_TAB_DELAY_SECONDS"
	fi
	osascript \
		-e 'tell application "Ghostty" to activate' \
		-e 'tell application "Ghostty" to new tab in front window' \
		>/dev/null 2>&1 || true
}

write_window_marker()
{
	window_id=$1
	created_ms=$(now_ms)
	tmp="$MARKER.new-tab.$$"

	{
		printf 'kind=window\n'
		printf 'source=new_tab\n'
		printf 'window_id=%s\n' "$window_id"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'created_ms=%s\n' "$created_ms"
	} > "$tmp"
	mv "$tmp" "$MARKER"
}

if ! mkdir "$REQUEST_LOCK_DIR" 2>/dev/null; then
	trace_new_tab "request_lock.busy" "lock=$REQUEST_LOCK_DIR"
	exit 0
fi
trap 'rmdir "$REQUEST_LOCK_DIR" 2>/dev/null || true' EXIT

trace_new_tab "enter" "socket_name=$SOCKET_NAME" \
	"socket_path=${EXPLICIT_SOCKET_PATH:-}" "target_pane=$TARGET_PANE"

if [ "$REQUEST_DEBOUNCE_MS" -gt 0 ] && request_was_recent; then
	trace_new_tab "exit.debounced" "debounce_ms=$REQUEST_DEBOUNCE_MS"
	exit 0
fi
now_ms > "$REQUEST_STAMP"

if [ -n "$TARGET_PANE" ]; then
	cwd=$(newmux_cmd display-message -p -t "$TARGET_PANE" \
		'#{pane_current_path}' 2>/dev/null || true)
else
	cwd=
fi

if [ -n "$cwd" ]; then
	window_id=$(newmux_cmd new-window -d -P -F '#{window_id}' \
		-t "$PRIMARY_SESSION:" -c "$cwd")
else
	window_id=$(newmux_cmd new-window -d -P -F '#{window_id}' \
		-t "$PRIMARY_SESSION:")
fi

trace_new_tab "window.created" "window_id=$window_id" "cwd=${cwd:-}"
write_window_marker "$window_id"
trace_new_tab "marker.written" "window_id=$window_id" "marker=$MARKER"
"$ROOT/scripts/newmux-runtime.py" mark \
	--socket-name "$SOCKET_NAME" \
	--socket-path "$EXPLICIT_SOCKET_PATH" \
	--target "$window_id" >/dev/null 2>&1 &
if [ -n "$TARGET_PANE" ] && [ "$RECORD_KEY_EVENTS" != 0 ]; then
	"$ROOT/scripts/newmux-ui-bridge.py" key-event \
		--key cmd+t \
		--socket-path "$EXPLICIT_SOCKET_PATH" \
		--target-pane "$TARGET_PANE" >/dev/null 2>&1 &
fi
open_ghostty_surface
trace_new_tab "exit.after_open" "window_id=$window_id"
