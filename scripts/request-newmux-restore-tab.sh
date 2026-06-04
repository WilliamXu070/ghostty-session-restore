#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOCKET_PATH=${1:-}
PRIMARY_SESSION=${NEWMUX_SESSION:-newmux}
SOCKET_NAME=${NEWMUX_SOCKET:-}
if [ -z "$SOCKET_NAME" ]; then
	if [ -n "$SOCKET_PATH" ]; then
		SOCKET_NAME=$(basename "$SOCKET_PATH")
	else
		SOCKET_NAME=newmux-dev
	fi
fi
EXPLICIT_SOCKET_PATH=${NEWMUX_SOCKET_PATH:-$SOCKET_PATH}
MARKER="${TMPDIR:-/tmp}/newmux-restore-tab-$(id -u)-$SOCKET_NAME"
REQUEST_LOCK_DIR="$MARKER.request-lock"
REQUEST_STAMP="$MARKER.requested"
REQUEST_DEBOUNCE_MS=${NEWMUX_RESTORE_REQUEST_DEBOUNCE_MS:-0}
RESTORE_OPEN_TAB_DELAY_SECONDS=${NEWMUX_RESTORE_OPEN_TAB_DELAY_SECONDS:-0}
RESTORE_TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}

newmux_cmd()
{
	if [ -n "$EXPLICIT_SOCKET_PATH" ]; then
		"$ROOT/bin/newmux" -S "$EXPLICIT_SOCKET_PATH" "$@"
		return
	fi
	"$ROOT/bin/newmux" -L "$SOCKET_NAME" "$@"
}

trace_now_ms()
{
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
	else
		printf '%s000\n' "$(date +%s)"
	fi
}

trace_restore()
{
	[ -n "$RESTORE_TRACE_FILE" ] || return 0
	{
		printf '%s\trequest\tpid=%s\t%s' "$(trace_now_ms)" "$$" "$1"
		if [ $# -gt 1 ]; then
			shift
			printf '\t%s' "$@"
		fi
		printf '\n'
	} >> "$RESTORE_TRACE_FILE" 2>/dev/null || true
}

open_ghostty_surface()
{
	if [ "$(uname)" != Darwin ] || [ "${NEWMUX_RESTORE_OPEN_TAB:-1}" = 0 ]; then
		trace_restore "open_ghostty_surface.skip" \
			"darwin=$(uname)" "open=${NEWMUX_RESTORE_OPEN_TAB:-1}"
		return 0
	fi

	if [ "$RESTORE_OPEN_TAB_DELAY_SECONDS" != 0 ]; then
		trace_restore "open_ghostty_surface.sleep.start" \
			"seconds=$RESTORE_OPEN_TAB_DELAY_SECONDS"
		sleep "$RESTORE_OPEN_TAB_DELAY_SECONDS"
		trace_restore "open_ghostty_surface.sleep.end"
	fi
	trace_restore "open_ghostty_surface.applescript.start"
	osascript \
		-e 'tell application "System Events" to key code 17 using command down' \
		>/dev/null 2>&1 || true
	trace_restore "open_ghostty_surface.applescript.end"
}

write_restore_request()
{
	sequence=$1
	tmp="$MARKER.$$"

	{
		printf 'kind=window_request\n'
		printf 'sequence=%s\n' "$sequence"
		printf 'created_at=%s\n' "$(date +%s)"
	} > "$tmp"
	mv "$tmp" "$MARKER"
}

now_ms()
{
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
	else
		printf '%s000\n' "$(date +%s)"
	fi
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

if ! mkdir "$REQUEST_LOCK_DIR" 2>/dev/null; then
	trace_restore "request_lock.busy" "lock=$REQUEST_LOCK_DIR"
	exit 0
fi
trap 'rmdir "$REQUEST_LOCK_DIR" 2>/dev/null || true' EXIT

trace_restore "enter" "socket_name=$SOCKET_NAME" \
	"socket_path=${EXPLICIT_SOCKET_PATH:-}" "marker=$MARKER"
trace_restore "list_recent.start"
RECENT=$(newmux_cmd newmux-list-recently-closed 2>/dev/null || true)
trace_restore "list_recent.end" \
	"count=$(printf '%s\n' "$RECENT" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ -z "$RECENT" ]; then
	trace_restore "exit.empty_stack"
	exit 0
fi
if [ "$REQUEST_DEBOUNCE_MS" -gt 0 ] && request_was_recent; then
	trace_restore "exit.debounced" "debounce_ms=$REQUEST_DEBOUNCE_MS"
	exit 0
fi
now_ms > "$REQUEST_STAMP"

RECENT_TYPE=$(printf '%s\n' "$RECENT" | awk 'NR == 1 { print $2 }')
if [ "$RECENT_TYPE" = pane ]; then
	trace_restore "restore_pane.start"
	newmux_cmd newmux-reopen-latest-closed -P >/dev/null 2>&1 || true
	trace_restore "restore_pane.end"
	exit 0
fi

RESTORE_SEQUENCE=$(printf '%s\n' "$RECENT" | awk 'NR == 1 { print $1 }')
case "$RESTORE_SEQUENCE" in
	''|*[!0-9]*)
		trace_restore "exit.bad_sequence" "sequence=$RESTORE_SEQUENCE"
		exit 0
		;;
esac

trace_restore "write_request.start" "sequence=$RESTORE_SEQUENCE" \
	"type=$RECENT_TYPE"
write_restore_request "$RESTORE_SEQUENCE"
trace_restore "write_request.end" "sequence=$RESTORE_SEQUENCE"
open_ghostty_surface
trace_restore "exit.after_open"
