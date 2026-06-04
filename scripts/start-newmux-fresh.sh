#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-dev}
SOCKET_PATH=${NEWMUX_SOCKET_PATH:-}
PRIMARY_SESSION=${NEWMUX_SESSION:-newmux}
ATTACH_UNREPRESENTED=${NEWMUX_ATTACH_UNREPRESENTED:-0}
RESTORE_MARKER="${TMPDIR:-/tmp}/newmux-restore-tab-$(id -u)-$SOCKET_NAME"
RESTORE_CLAIM_DIR="$RESTORE_MARKER.claim"
RESTORE_MARKER_TTL_SECONDS=${NEWMUX_RESTORE_MARKER_TTL_SECONDS:-5}
RESTORE_TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}

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
		printf '%s\tstartup\tpid=%s\t%s' "$(trace_now_ms)" "$$" "$1"
		if [ $# -gt 1 ]; then
			shift
			printf '\t%s' "$@"
		fi
		printf '\n'
	} >> "$RESTORE_TRACE_FILE" 2>/dev/null || true
}

trace_restore "enter" "argv=${*:-}" "socket_name=$SOCKET_NAME" \
	"socket_path=$SOCKET_PATH" "marker=$RESTORE_MARKER"

newmux()
{
	if [ -n "$SOCKET_PATH" ]; then
		"$ROOT/bin/newmux" -S "$SOCKET_PATH" "$@"
		return
	fi
	"$ROOT/bin/newmux" -L "$SOCKET_NAME" "$@"
}

find_unrepresented_window()
{
	represented=$(newmux list-clients -F '#{client_session}' 2>/dev/null |
		while IFS= read -r client_session; do
			[ -n "$client_session" ] || continue
			newmux display-message -p -t "$client_session" '#{window_id}' \
				2>/dev/null || true
		done | sort -u)

	newmux list-windows -t "$PRIMARY_SESSION" -F '#{window_id}' 2>/dev/null |
		while IFS= read -r window_id; do
			[ -n "$window_id" ] || continue
			if ! printf '%s\n' "$represented" | grep -Fqx "$window_id"; then
				printf '%s\n' "$window_id"
				break
			fi
		done
}

has_attached_clients()
{
	if [ "${NEWMUX_STARTER_ASSUME_CLIENTS:-0}" != 0 ]; then
		return 0
	fi
	[ -n "$(newmux list-clients -F '#{client_pid}' 2>/dev/null || true)" ]
}

clear_detached_recovery_state()
{
	rm -f "$RESTORE_MARKER" "$RESTORE_MARKER.requested"
	rmdir "$RESTORE_CLAIM_DIR" 2>/dev/null || true
	rmdir "$RESTORE_MARKER.request-lock" 2>/dev/null || true
	newmux newmux-clear-recently-closed >/dev/null 2>&1 || true
	newmux kill-session -t __newmux-recovery >/dev/null 2>&1 || true
}

clear_restore_marker_files()
{
	rm -f "$RESTORE_MARKER" "$RESTORE_MARKER.requested"
	rmdir "$RESTORE_CLAIM_DIR" 2>/dev/null || true
	rmdir "$RESTORE_MARKER.request-lock" 2>/dev/null || true
}

restore_marker_is_stale()
{
	[ -f "$RESTORE_MARKER" ] || return 1
	created_at=$(awk -F= '$1 == "created_at" { print $2; exit }' \
		"$RESTORE_MARKER" 2>/dev/null || true)
	case "$created_at" in
		''|*[!0-9]*)
			return 0
			;;
	esac
	now=$(date +%s)
	[ $((now - created_at)) -gt "$RESTORE_MARKER_TTL_SECONDS" ]
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

validate_window_id()
{
	window_id=$1
	case "$window_id" in
		@*[!0-9]*|@|'')
			return 1
			;;
		@*)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

claim_requested_restore_window_id()
{
	request_sequence=$1
	trace_restore "claim_requested.list_recent.start" \
		"sequence=$request_sequence"
	recent=$(newmux newmux-list-recently-closed 2>/dev/null || true)
	trace_restore "claim_requested.list_recent.end" \
		"sequence=$request_sequence" \
		"count=$(printf '%s\n' "$recent" | sed '/^$/d' | wc -l | tr -d ' ')"
	recent_sequence=$(printf '%s\n' "$recent" | awk 'NR == 1 { print $1 }')
	recent_type=$(printf '%s\n' "$recent" | awk 'NR == 1 { print $2 }')
	if [ "$recent_sequence" != "$request_sequence" ] ||
		[ "$recent_type" != window ]; then
		trace_restore "claim_requested.stack_mismatch" \
			"request_sequence=$request_sequence" \
			"recent_sequence=$recent_sequence" "recent_type=$recent_type"
		return 3
	fi

	trace_restore "claim_requested.reopen.start" \
		"sequence=$request_sequence"
	result=$(newmux newmux-reopen-latest-closed -P \
		-t "$PRIMARY_SESSION:" 2>/dev/null || true)
	trace_restore "claim_requested.reopen.end" \
		"sequence=$request_sequence" "result=${result:-}"
	if [ -z "$result" ]; then
		return 3
	fi
	restore_kind=$(restore_field "$result" kind)
	window_id=$(restore_field "$result" window_id)
	if [ "$restore_kind" != window ] ||
		! validate_window_id "$window_id"; then
		trace_restore "claim_requested.bad_result" \
			"kind=$restore_kind" "window_id=$window_id"
		return 3
	fi

	trace_restore "claim_requested.ok" "window_id=$window_id"
	printf '%s\n' "$window_id"
	return 0
}

claim_restore_window_id()
{
	trace_restore "claim_marker.start"
	if [ ! -f "$RESTORE_MARKER" ]; then
		trace_restore "claim_marker.missing"
		return 1
	fi
	if restore_marker_is_stale; then
		rm -f "$RESTORE_MARKER"
		trace_restore "claim_marker.stale"
		return 1
	fi
	if ! mkdir "$RESTORE_CLAIM_DIR" 2>/dev/null; then
		trace_restore "claim_marker.busy" "claim_dir=$RESTORE_CLAIM_DIR"
		return 2
	fi
	kind=$(awk -F= '$1 == "kind" { print $2; exit }' \
		"$RESTORE_MARKER" 2>/dev/null || true)
	sequence=$(awk -F= '$1 == "sequence" { print $2; exit }' \
		"$RESTORE_MARKER" 2>/dev/null || true)
	window_id=$(awk -F= '$1 == "window_id" { print $2; exit }' \
		"$RESTORE_MARKER" 2>/dev/null || true)
	rm -f "$RESTORE_MARKER"
	trace_restore "claim_marker.read" "kind=$kind" \
		"sequence=$sequence" "window_id=$window_id"

	case "$kind" in
		window_request)
			case "$sequence" in
				''|*[!0-9]*)
					finish_restore_claim
					return 3
					;;
			esac
			if requested_window=$(claim_requested_restore_window_id \
				"$sequence"); then
				printf '%s\n' "$requested_window"
				return 0
			fi
			status=$?
			finish_restore_claim
			return "$status"
			;;
		window|'')
			if ! validate_window_id "$window_id"; then
				finish_restore_claim
				return 1
			fi
			printf '%s\n' "$window_id"
			return 0
			;;
		*)
			finish_restore_claim
			return 1
			;;
	esac
	return 0
}

finish_restore_claim()
{
	rmdir "$RESTORE_CLAIM_DIR" 2>/dev/null || true
}

attach_native_tab_to_window()
{
	window_id=$1
	tab_session="newmux-tab-$(date +%s)-$$"

	trace_restore "attach.start" "window_id=$window_id" \
		"tab_session=$tab_session"
	trace_restore "attach.new_session.start" "tab_session=$tab_session"
	newmux new-session -d -t "$PRIMARY_SESSION" -s "$tab_session"
	trace_restore "attach.new_session.end" "tab_session=$tab_session"
	trace_restore "attach.select_window.start" "window_id=$window_id" \
		"tab_session=$tab_session"
	if ! newmux select-window -t "$tab_session:$window_id" >/dev/null 2>&1; then
		trace_restore "attach.select_window.failed" "window_id=$window_id" \
			"tab_session=$tab_session"
		newmux kill-session -t "$tab_session" >/dev/null 2>&1 || true
		exec "$ROOT/scripts/run-newmux.sh" new-session -A -s "$PRIMARY_SESSION"
	fi
	trace_restore "attach.select_window.end" "window_id=$window_id" \
		"tab_session=$tab_session"
	trace_restore "attach.has_session.start" "tab_session=$tab_session"
	if ! newmux has-session -t "$tab_session" >/dev/null 2>&1; then
		trace_restore "attach.has_session.failed" "tab_session=$tab_session"
		exec "$ROOT/scripts/run-newmux.sh" new-session -A -s "$PRIMARY_SESSION"
	fi
	trace_restore "attach.has_session.end" "tab_session=$tab_session"
	if [ "${NEWMUX_STARTER_PRINT_WINDOW:-0}" != 0 ]; then
		trace_restore "attach.print_window" "window_id=$window_id"
		printf '%s\n' "$window_id"
		exit 0
	fi
	trace_restore "attach.exec_run_newmux" "window_id=$window_id" \
		"tab_session=$tab_session"
	exec "$ROOT/scripts/run-newmux.sh" attach-session -t "$tab_session"
}

cleanup_unattached_native_tab_sessions()
{
	newmux list-sessions -F '#{session_name} #{session_attached}' \
		2>/dev/null |
		while read -r session_name attached; do
			case "$session_name" in
				newmux-tab-*)
					if [ "${attached:-0}" = 0 ]; then
						newmux kill-session -t "$session_name" \
							>/dev/null 2>&1 || true
					fi
					;;
			esac
		done
}

if [ ! -x "$ROOT/bin/newmux" ]; then
	trace_restore "build_missing_binary.start"
	"$ROOT/scripts/build-newmux.sh"
	trace_restore "build_missing_binary.end"
fi

if [ "${1:-}" != kill-only ] && has_attached_clients; then
	trace_restore "attached_clients.true"
	trace_restore "cleanup_unattached_tabs.start"
	cleanup_unattached_native_tab_sessions
	trace_restore "cleanup_unattached_tabs.end"

	trace_restore "claim_restore.start"
	if TAB_WINDOW=$(claim_restore_window_id); then
		trace_restore "claim_restore.ok" "window_id=$TAB_WINDOW"
		finish_restore_claim
		attach_native_tab_to_window "$TAB_WINDOW"
	else
		claim_status=$?
		trace_restore "claim_restore.none" "status=$claim_status"
		if [ "$claim_status" -eq 2 ]; then
			trace_restore "claim_restore.busy_fallback"
			exec "$ROOT/scripts/run-newmux.sh" new-session -A -s "$PRIMARY_SESSION"
		fi
		if [ "$claim_status" -eq 3 ]; then
			trace_restore "claim_restore.invalid_request_exit"
			exit 0
		fi
	fi

	if [ "$ATTACH_UNREPRESENTED" != 0 ]; then
		trace_restore "attach_unrepresented.start"
		TAB_WINDOW=$(find_unrepresented_window | head -1)
		trace_restore "attach_unrepresented.end" "window_id=$TAB_WINDOW"
		if [ -n "$TAB_WINDOW" ]; then
			attach_native_tab_to_window "$TAB_WINDOW"
		fi
	fi

	trace_restore "clear_restore_marker_files"
	clear_restore_marker_files

	trace_restore "fresh_new_window.start"
	TAB_WINDOW=$(newmux new-window -d -P -F '#{window_id}' \
		-t "$PRIMARY_SESSION:")
	trace_restore "fresh_new_window.end" "window_id=$TAB_WINDOW"
	attach_native_tab_to_window "$TAB_WINDOW"
fi

trace_restore "clear_detached_recovery_state.start"
clear_detached_recovery_state
trace_restore "clear_detached_recovery_state.end"

if [ "${1:-}" != kill-only ] &&
	newmux has-session -t "$PRIMARY_SESSION" >/dev/null 2>&1; then
	trace_restore "detached_existing_session"
	cleanup_unattached_native_tab_sessions

	if [ "$ATTACH_UNREPRESENTED" != 0 ]; then
		trace_restore "detached_attach_unrepresented.start"
		TAB_WINDOW=$(find_unrepresented_window | head -1)
		trace_restore "detached_attach_unrepresented.end" \
			"window_id=$TAB_WINDOW"
		if [ -n "$TAB_WINDOW" ]; then
			attach_native_tab_to_window "$TAB_WINDOW"
		fi
	fi
	trace_restore "exec_existing_primary"
	exec "$ROOT/scripts/run-newmux.sh" new-session -A -s "$PRIMARY_SESSION"
fi

trace_restore "kill_stale_processes.start"
PIDS=$(ps ax -o pid=,command= | awk \
	-v bin="$ROOT/bin/newmux" \
	-v socket="$SOCKET_NAME" \
	-v socket_path="$SOCKET_PATH" \
	'{ pid = $1; cmd = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", cmd); if (index(cmd, bin " ") == 1 && ((socket_path != "" && index(cmd, " -S " socket_path) != 0) || (socket_path == "" && index(cmd, " -L " socket) != 0))) print pid }')
if [ -n "$PIDS" ]; then
	kill $PIDS >/dev/null 2>&1 || true
	sleep 0.2
	PIDS=$(ps ax -o pid=,command= | awk \
		-v bin="$ROOT/bin/newmux" \
		-v socket="$SOCKET_NAME" \
		-v socket_path="$SOCKET_PATH" \
		'{ pid = $1; cmd = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", cmd); if (index(cmd, bin " ") == 1 && ((socket_path != "" && index(cmd, " -S " socket_path) != 0) || (socket_path == "" && index(cmd, " -L " socket) != 0))) print pid }')
	if [ -n "$PIDS" ]; then
		kill -9 $PIDS >/dev/null 2>&1 || true
	fi
fi
trace_restore "kill_stale_processes.end"

rm -f "/tmp/tmux-$(id -u)/$SOCKET_NAME"

if [ "${1:-}" = kill-only ]; then
	trace_restore "exit.kill_only"
	exit 0
fi

trace_restore "exec_new_primary"
exec "$ROOT/scripts/run-newmux.sh" new-session -A -s "$PRIMARY_SESSION"
