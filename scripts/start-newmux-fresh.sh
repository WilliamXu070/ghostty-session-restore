#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-dev}
SOCKET_PATH=${NEWMUX_SOCKET_PATH:-}
PRIMARY_SESSION=${NEWMUX_SESSION:-newmux}
ATTACH_UNREPRESENTED=${NEWMUX_ATTACH_UNREPRESENTED:-0}
RESTORE_MARKER="${TMPDIR:-/tmp}/newmux-restore-tab-$(id -u)-$SOCKET_NAME"
RESTORE_QUEUE_DIR="$RESTORE_MARKER.queue"
RESTORE_CLAIM_DIR="$RESTORE_MARKER.claim"
RESTORE_MARKER_TTL_SECONDS=${NEWMUX_RESTORE_MARKER_TTL_SECONDS:-30}
NEWMUX_TAB_MARKER_WAIT_MS=${NEWMUX_TAB_MARKER_WAIT_MS:-150}
RESTORE_TRACE_FILE=${NEWMUX_RESTORE_TRACE_FILE:-}
DIRECT_ATTACH_WINDOW=${NEWMUX_ATTACH_WINDOW:-}
PENDING_ATTACH_TOKEN=${NEWMUX_ATTACH_PENDING_TOKEN:-}
PENDING_ATTACH_DIR=${NEWMUX_ATTACH_PENDING_DIR:-}
PENDING_ATTACH_WAIT_MS=${NEWMUX_ATTACH_PENDING_WAIT_MS:-8000}

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
	rm -rf "$RESTORE_QUEUE_DIR"
	rmdir "$RESTORE_CLAIM_DIR" 2>/dev/null || true
	rmdir "$RESTORE_MARKER.request-lock" 2>/dev/null || true
	newmux newmux-clear-recently-closed >/dev/null 2>&1 || true
	newmux kill-session -t __newmux-recovery >/dev/null 2>&1 || true
}

clear_restore_marker_files()
{
	rm -f "$RESTORE_MARKER" "$RESTORE_MARKER.requested"
	rm -rf "$RESTORE_QUEUE_DIR"
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

wait_for_restore_marker()
{
	waited_ms=0
	while [ "$waited_ms" -lt "$NEWMUX_TAB_MARKER_WAIT_MS" ]; do
		[ -f "$RESTORE_MARKER" ] && return 0
		sleep 0.02
		waited_ms=$((waited_ms + 20))
	done
	return 1
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

validate_pending_token()
{
	token=$1
	case "$token" in
		''|*/*|*..*|*[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-]*)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

wait_for_pending_attach_window()
{
	validate_pending_token "$PENDING_ATTACH_TOKEN" || return 1
	[ -n "$PENDING_ATTACH_DIR" ] || return 1
	case "$PENDING_ATTACH_WAIT_MS" in
		''|*[!0-9]*)
			PENDING_ATTACH_WAIT_MS=8000
			;;
	esac

	pending_file="$PENDING_ATTACH_DIR/$PENDING_ATTACH_TOKEN.window"
	cancel_file="$PENDING_ATTACH_DIR/$PENDING_ATTACH_TOKEN.cancelled"
	waited_ms=0
	while [ "$waited_ms" -lt "$PENDING_ATTACH_WAIT_MS" ]; do
		[ -f "$cancel_file" ] && return 1
		if [ -f "$pending_file" ]; then
			window_id=$(sed -n '1p' "$pending_file" 2>/dev/null || true)
			if validate_window_id "$window_id"; then
				printf '%s\n' "$window_id"
				return 0
			fi
		fi
		sleep 0.02
		waited_ms=$((waited_ms + 20))
	done
	return 1
}

claim_next_restore_ticket_sequence()
{
	ticket=
	[ -d "$RESTORE_QUEUE_DIR" ] || return 1
	for candidate in "$RESTORE_QUEUE_DIR"/*.ticket; do
		[ -e "$candidate" ] || break
		if [ -z "$ticket" ] ||
			[ "$(basename "$candidate")" \< "$(basename "$ticket")" ]; then
			ticket=$candidate
		fi
	done
	[ -n "$ticket" ] || return 1

	claim_ticket="$ticket.claim.$$"
	if ! mv "$ticket" "$claim_ticket" 2>/dev/null; then
		return 2
	fi
	sequence=$(awk -F= '$1 == "sequence" { print $2; exit }' \
		"$claim_ticket" 2>/dev/null || true)
	kind=$(awk -F= '$1 == "kind" { print $2; exit }' \
		"$claim_ticket" 2>/dev/null || true)
	rm -f "$claim_ticket"

	if [ "$kind" != window ]; then
		trace_restore "claim_ticket.bad_kind" "kind=$kind" \
			"sequence=$sequence"
		return 3
	fi
	case "$sequence" in
		''|*[!0-9]*)
			trace_restore "claim_ticket.bad_sequence" \
				"sequence=$sequence"
			return 3
			;;
	esac

	trace_restore "claim_ticket.read" "sequence=$sequence" \
		"kind=$kind"
	printf '%s\n' "$sequence"
	return 0
}

claim_reserved_restore_window_id()
{
	request_sequence=$1
	trace_restore "claim_reserved.reopen.start" \
		"sequence=$request_sequence"
	result=$(newmux newmux-claim-reserved-closed -P \
		-S "$request_sequence" -t "$PRIMARY_SESSION:" \
		2>/dev/null || true)
	trace_restore "claim_reserved.reopen.end" \
		"sequence=$request_sequence" "result=${result:-}"
	if [ -z "$result" ]; then
		return 3
	fi
	restore_kind=$(restore_field "$result" kind)
	window_id=$(restore_field "$result" window_id)
	if [ "$restore_kind" != window ] ||
		! validate_window_id "$window_id"; then
		trace_restore "claim_reserved.bad_result" \
			"kind=$restore_kind" "window_id=$window_id"
		return 3
	fi

	trace_restore "claim_reserved.ok" "window_id=$window_id"
	printf '%s\n' "$window_id"
	return 0
}

claim_restore_window_id()
{
	trace_restore "claim_marker.start"
	if ! mkdir "$RESTORE_CLAIM_DIR" 2>/dev/null; then
		trace_restore "claim_marker.busy" "claim_dir=$RESTORE_CLAIM_DIR"
		return 2
	fi
	if ticket_sequence=$(claim_next_restore_ticket_sequence); then
		claim_reserved_restore_window_id "$ticket_sequence"
		return $?
	fi
	ticket_status=$?
	if [ "$ticket_status" -eq 2 ]; then
		return 2
	fi
	if [ "$ticket_status" -eq 3 ]; then
		finish_restore_claim
		return 3
	fi

	if [ ! -f "$RESTORE_MARKER" ]; then
		trace_restore "claim_marker.wait.start" \
			"wait_ms=$NEWMUX_TAB_MARKER_WAIT_MS"
		if ! wait_for_restore_marker; then
			trace_restore "claim_marker.missing"
			finish_restore_claim
			return 1
		fi
		trace_restore "claim_marker.wait.end"
	fi
	if restore_marker_is_stale; then
		rm -f "$RESTORE_MARKER"
		trace_restore "claim_marker.stale"
		finish_restore_claim
		return 1
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
			if requested_window=$(claim_reserved_restore_window_id \
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
	"$ROOT/scripts/newmux-runtime.py" remember-tab-session \
		--socket-name "$SOCKET_NAME" \
		--socket-path "$SOCKET_PATH" \
		--tab-session "$tab_session" \
		--window-id "$window_id" >/dev/null 2>&1 || true
	"$ROOT/scripts/newmux-runtime.py" restore-tab-sessions \
		--socket-name "$SOCKET_NAME" \
		--socket-path "$SOCKET_PATH" >/dev/null 2>&1 || true
	if [ "${NEWMUX_STARTER_PRINT_WINDOW:-0}" != 0 ]; then
		trace_restore "attach.print_window" "window_id=$window_id"
		printf '%s\n' "$window_id"
		exit 0
	fi
	trace_restore "attach.exec_newmux" "window_id=$window_id" \
		"tab_session=$tab_session"
	if [ -n "$SOCKET_PATH" ]; then
		exec "$ROOT/bin/newmux" -S "$SOCKET_PATH" -f "$CONF" \
			attach-session -t "$tab_session"
	fi
	exec "$ROOT/bin/newmux" -L "$SOCKET_NAME" -f "$CONF" \
		attach-session -t "$tab_session"
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

if [ "${1:-}" != kill-only ] && [ -n "$PENDING_ATTACH_TOKEN" ]; then
	trace_restore "pending_attach.start" "token=$PENDING_ATTACH_TOKEN"
	if TAB_WINDOW=$(wait_for_pending_attach_window); then
		trace_restore "pending_attach.ok" "window_id=$TAB_WINDOW"
		attach_native_tab_to_window "$TAB_WINDOW"
	fi
	trace_restore "pending_attach.timeout" "token=$PENDING_ATTACH_TOKEN"
	exit 0
fi

if [ "${1:-}" != kill-only ] && [ -n "$DIRECT_ATTACH_WINDOW" ]; then
	trace_restore "direct_attach.start" "window_id=$DIRECT_ATTACH_WINDOW"
	if validate_window_id "$DIRECT_ATTACH_WINDOW" &&
		newmux display-message -p -t "$DIRECT_ATTACH_WINDOW" \
			'#{window_id}' >/dev/null 2>&1; then
		attach_native_tab_to_window "$DIRECT_ATTACH_WINDOW"
	fi
	trace_restore "direct_attach.invalid" "window_id=$DIRECT_ATTACH_WINDOW"
	exit 0
fi

if [ "${1:-}" != kill-only ] && has_attached_clients; then
	trace_restore "attached_clients.true"
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

	trace_restore "cleanup_unattached_tabs.start"
	cleanup_unattached_native_tab_sessions
	trace_restore "cleanup_unattached_tabs.end"

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
	trace_restore "detached_existing_session.clear_for_fresh_start"
	newmux kill-server >/dev/null 2>&1 || true
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
