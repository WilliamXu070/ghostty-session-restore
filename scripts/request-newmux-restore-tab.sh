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
REQUEST_QUEUE_DIR="$MARKER.queue"
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
		-e 'tell application "Ghostty" to activate' \
		-e 'tell application "Ghostty" to new tab in front window' \
		>/dev/null 2>&1 || true
	trace_restore "open_ghostty_surface.applescript.end"
}

restore_field()
{
	text=$1
	name=$2
	printf '%s\n' "$text" |
		awk -v name="$name" '{
			for (i = 1; i <= NF; i++) {
				split($i, field, "=")
				if (field[1] == name) {
					print substr($i, length(name) + 2)
					exit
				}
			}
		}'
}

write_restore_ticket()
{
	sequence=$1
	kind=$2
	created_ms=$(trace_now_ms)
	mkdir -p "$REQUEST_QUEUE_DIR"
	tmp="$REQUEST_QUEUE_DIR/.ticket-$created_ms-$sequence-$$"
	ticket="$REQUEST_QUEUE_DIR/$created_ms-$sequence-$$.ticket"

	{
		printf 'kind=%s\n' "$kind"
		printf 'sequence=%s\n' "$sequence"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'created_ms=%s\n' "$created_ms"
	} > "$tmp"
	mv "$tmp" "$ticket"
}

write_window_marker()
{
	window_id=$1
	created_ms=$(trace_now_ms)
	tmp="$MARKER.runtime-restore.$$"

	{
		printf 'kind=window\n'
		printf 'source=runtime_lifo\n'
		printf 'window_id=%s\n' "$window_id"
		printf 'created_at=%s\n' "$(date +%s)"
		printf 'created_ms=%s\n' "$created_ms"
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
if [ "$REQUEST_DEBOUNCE_MS" -gt 0 ] && request_was_recent; then
	trace_restore "exit.debounced" "debounce_ms=$REQUEST_DEBOUNCE_MS"
	exit 0
fi

trace_restore "runtime_restore.start"
RUNTIME_RESTORE=$("$ROOT/scripts/newmux-runtime.py" restore-latest \
	--socket-name "$SOCKET_NAME" \
	--socket-path "$EXPLICIT_SOCKET_PATH" \
	--primary-session "$PRIMARY_SESSION" \
	--json 2>/dev/null || true)
trace_restore "runtime_restore.end" "result=${RUNTIME_RESTORE:-}"
RUNTIME_WINDOW=$(printf '%s\n' "$RUNTIME_RESTORE" |
	sed -n 's/.*"restored": true.*"window": "\([^"]*\)".*/\1/p')
if [ -n "$RUNTIME_WINDOW" ]; then
	now_ms > "$REQUEST_STAMP"
	trace_restore "runtime_restore.marker.start" "window=$RUNTIME_WINDOW"
	write_window_marker "$RUNTIME_WINDOW"
	trace_restore "runtime_restore.marker.end" "window=$RUNTIME_WINDOW"
	open_ghostty_surface
	trace_restore "exit.after_runtime_open" "window=$RUNTIME_WINDOW"
	exit 0
fi

trace_restore "reserve_latest.start"
RESERVED=$(newmux_cmd newmux-reserve-latest-closed -P 2>/dev/null || true)
trace_restore "reserve_latest.end" "result=${RESERVED:-}"
if [ -z "$RESERVED" ]; then
	trace_restore "exit.empty_stack"
	exit 0
fi
now_ms > "$REQUEST_STAMP"

RESERVED_TYPE=$(restore_field "$RESERVED" kind)
RESTORE_SEQUENCE=$(restore_field "$RESERVED" sequence)
case "$RESTORE_SEQUENCE" in
	''|*[!0-9]*)
		trace_restore "exit.bad_sequence" "sequence=$RESTORE_SEQUENCE"
		exit 0
		;;
esac

if [ "$RESERVED_TYPE" = pane ]; then
	trace_restore "claim_reserved_pane.start" "sequence=$RESTORE_SEQUENCE"
	newmux_cmd newmux-claim-reserved-closed -P \
		-S "$RESTORE_SEQUENCE" >/dev/null 2>&1 || true
	trace_restore "claim_reserved_pane.end" "sequence=$RESTORE_SEQUENCE"
	exit 0
fi

if [ "$RESERVED_TYPE" != window ]; then
	trace_restore "exit.bad_type" "type=$RESERVED_TYPE" \
		"sequence=$RESTORE_SEQUENCE"
	exit 0
fi

trace_restore "write_ticket.start" "sequence=$RESTORE_SEQUENCE" \
	"type=$RESERVED_TYPE"
write_restore_ticket "$RESTORE_SEQUENCE" "$RESERVED_TYPE"
trace_restore "write_ticket.end" "sequence=$RESTORE_SEQUENCE"
open_ghostty_surface
trace_restore "exit.after_open"
