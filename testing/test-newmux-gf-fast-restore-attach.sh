#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-fast-restore-$$"
GOLDEN_TEST_NAME="gf-fast-restore-attach"
UI_LOG="/tmp/newmux-gf-fast-restore-attach-$$.log"
MAX_RESTORE_MS=${NEWMUX_FAST_RESTORE_MAX_MS:-1800}
SCREENSHOT_SETTLE_SECONDS=${NEWMUX_FAST_RESTORE_SCREENSHOT_SETTLE_SECONDS:-0.4}

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-fast-restore-$$.sock"
export NEWMUX_SOCKET_PATH
mkdir -p "$(dirname "$NEWMUX_SOCKET_PATH")"

cleanup()
{
	stop_golden_ui_session
	newmux_cmd -f "$CONF" kill-server >/dev/null 2>&1 || true
	newmux_cmd -f "$CONF" newmux-clear-recently-closed \
		>/dev/null 2>&1 || true
	rm -f "$NEWMUX_SOCKET_PATH"
}
trap cleanup EXIT INT TERM

now_ms()
{
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
	else
		printf '%s000\n' "$(date +%s)"
	fi
}

trace_test()
{
	[ -n "${NEWMUX_RESTORE_TRACE_FILE:-}" ] || return 0
	{
		printf '%s\ttest\tpid=%s\t%s' "$(now_ms)" "$$" "$1"
		if [ $# -gt 1 ]; then
			shift
			printf '\t%s' "$@"
		fi
		printf '\n'
	} >> "$NEWMUX_RESTORE_TRACE_FILE" 2>/dev/null || true
}

print_restore_trace_summary()
{
	trace_file=${NEWMUX_RESTORE_TRACE_FILE:-}
	[ -n "$trace_file" ] || return 0

	echo "  restore_trace=$trace_file"
	if [ ! -s "$trace_file" ]; then
		echo "  restore_trace_empty=1"
		return 0
	fi

	echo "  restore_trace_events:"
	sed 's/^/    /' "$trace_file"
	echo "  restore_trace_gaps:"
	awk -F '\t' '
		NR == 1 {
			prev_ms = $1
			prev_label = $2 ":" $4
			next
		}
		{
			label = $2 ":" $4
			printf "    +%4d ms  %s -> %s\n", $1 - prev_ms, prev_label, label
			prev_ms = $1
			prev_label = label
		}
	' "$trace_file"
}

window_ids()
{
	newmux_cmd -f "$CONF" list-windows -t "$1" -F '#{window_id}'
}

first_window_not_in()
{
	before=$1
	after=$2
	printf '%s\n' "$after" |
		while IFS= read -r window_id; do
			[ -n "$window_id" ] || continue
			if ! printf '%s\n' "$before" | grep -Fxq "$window_id"; then
				printf '%s\n' "$window_id"
				break
			fi
		done
}

pane_for_window()
{
	newmux_cmd -f "$CONF" list-panes -t "$1:$2" -F '#{pane_id}' |
		head -1
}

capture_window()
{
	window_id=$1
	output_file=$2
	pane_id=$(pane_for_window "$PRIMARY" "$window_id")
	newmux_cmd -f "$CONF" capture-pane -epS - -t "$pane_id" \
		> "$output_file" 2>&1 || true
}

assert_capture_contains()
{
	window_id=$1
	needle=$2
	label=$3
	capture="$GOLDEN_RUN_DIR/$label-capture.txt"

	i=1
	while [ "$i" -le 100 ]; do
		capture_window "$window_id" "$capture"
		if grep -q "$needle" "$capture"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done

	echo "window capture missing expected text" >&2
	echo "window_id=$window_id needle=$needle" >&2
	echo "capture=$capture" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
}

assert_capture_contains_at_least()
{
	window_id=$1
	needle=$2
	min_count=$3
	label=$4
	capture="$GOLDEN_RUN_DIR/$label-capture.txt"

	i=1
	while [ "$i" -le 100 ]; do
		capture_window "$window_id" "$capture"
		count=$(grep -c "$needle" "$capture" 2>/dev/null || true)
		if [ "$count" -ge "$min_count" ]; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done

	echo "window capture missing expected repeated text" >&2
	echo "window_id=$window_id needle=$needle min_count=$min_count" >&2
	echo "capture=$capture" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
}

represented_window_ids()
{
	newmux_cmd -f "$CONF" list-clients -F '#{client_session}' 2>/dev/null |
		while IFS= read -r client_session; do
			[ -n "$client_session" ] || continue
			newmux_cmd -f "$CONF" display-message -p \
				-t "$client_session" '#{window_id}' 2>/dev/null || true
		done | sort -u
}

wait_for_represented_window()
{
	expected=$1
	i=1
	while [ "$i" -le 100 ]; do
		if represented_window_ids | grep -qx "$expected"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
require_golden_ui_environment
setup_golden_run_dir "$GOLDEN_TEST_NAME"
NEWMUX_RESTORE_TRACE_FILE="$GOLDEN_RUN_DIR/restore-trace.tsv"
export NEWMUX_RESTORE_TRACE_FILE
: > "$NEWMUX_RESTORE_TRACE_FILE"

if ! start_golden_ui_session "$UI_LOG"; then
	exit 1
fi

PRIMARY=$(primary_session)
record_golden_evidence "01-after-launch"

windows_before=$(window_ids "$PRIMARY")
count_before=$(printf '%s\n' "$windows_before" | sed '/^$/d' |
	wc -l | tr -d ' ')
press_key "t" "command down"
if ! wait_for_at_least_window_count "$PRIMARY" $((count_before + 1)); then
	record_golden_evidence "02-open-delete-source-failed"
	echo "Cmd+T did not create delete source" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

windows_after=$(window_ids "$PRIMARY")
delete_window=$(first_window_not_in "$windows_before" "$windows_after")
if [ -z "$delete_window" ]; then
	delete_session=$(active_client_session)
	delete_window=$(current_window_id "$delete_session")
fi
delete_pane=$(pane_for_window "$PRIMARY" "$delete_window")
marker="__NEWMUX_FAST_RESTORE_${SOCKET_NAME}_$$"
newmux_cmd -f "$CONF" send-keys -t "$delete_pane" -l \
	"printf '${marker}\\n${marker}_2\\n${marker}_3\\n'"
newmux_cmd -f "$CONF" send-keys -t "$delete_pane" Enter
assert_capture_contains_at_least "$delete_window" "$marker" 2 \
	"02-delete-source-ready"
record_golden_evidence "02-delete-source-ready"

press_key "w" "command down"
if ! wait_for_recovery_count 1; then
	record_golden_evidence "03-delete-did-not-enter-stack"
	echo "Cmd+W did not create one recoverable tab" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if represented_window_ids | grep -qx "$delete_window"; then
	record_golden_evidence "03-deleted-window-still-represented"
	echo "deleted window is still represented before restore" >&2
	echo "window_id=$delete_window" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
record_golden_evidence "03-after-delete"

: > "$NEWMUX_RESTORE_TRACE_FILE"
trace_test "restore_key.start" "window_id=$delete_window"
start_ms=$(now_ms)
press_key "t" "command down, shift down"
trace_test "restore_key.sent" "window_id=$delete_window"
if ! wait_for_represented_window "$delete_window"; then
	record_golden_evidence "04-restore-not-represented"
	echo "restored window was not represented by a native tab" >&2
	echo "window_id=$delete_window" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
end_ms=$(now_ms)
trace_test "represented_window.seen" "window_id=$delete_window"
latency_ms=$((end_ms - start_ms))
if ! wait_for_recovery_count 0; then
	record_golden_evidence "04-restore-stack-not-empty"
	echo "recovery stack should be empty after restore" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
assert_capture_contains "$delete_window" "$marker" "04-after-restore"
sleep "$SCREENSHOT_SETTLE_SECONDS"
record_golden_evidence "04-after-restore"

if [ "$latency_ms" -gt "$MAX_RESTORE_MS" ]; then
	echo "restore attach latency exceeded threshold" >&2
	echo "latency_ms=$latency_ms max_ms=$MAX_RESTORE_MS" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-fast-restore-attach UI test passed"
echo "  restored_window=$delete_window"
echo "  latency_ms=$latency_ms"
echo "  max_ms=$MAX_RESTORE_MS"
echo "  evidence=$GOLDEN_RUN_DIR"
print_restore_trace_summary
