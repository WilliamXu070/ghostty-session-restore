#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-fresh-clean-$$"
GOLDEN_TEST_NAME="gf-newtab-fresh-clean"
UI_LOG="/tmp/newmux-gf-newtab-fresh-clean-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-tab-$$.sock"
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

tmux_probe()
{
	LOG_FILE=$(mktemp)
	newmux_cmd -f "$CONF" new-session -d \
		-s "__newmux-gf-probe" -n probe 'true' > "$LOG_FILE" 2>&1 || true
	if grep -q "Operation not permitted" "$LOG_FILE" || \
		grep -q "error creating /private/tmp" "$LOG_FILE"; then
		echo "socket creation is blocked in this environment (failing test)." >&2
		cat "$LOG_FILE" >&2
		rm -f "$LOG_FILE"
		return 1
	fi
	if grep -q "^error connecting to " "$LOG_FILE"; then
		echo "tmux probe returned socket-state error (failing test)." >&2
		cat "$LOG_FILE" >&2
		rm -f "$LOG_FILE"
		return 1
	fi
	newmux_cmd -f "$CONF" kill-server >/dev/null 2>&1 || true
	rm -f "$LOG_FILE"
}

capture_pane()
{
	pane_id=$1
	output_file=$2
	newmux_cmd -f "$CONF" capture-pane -epS - -t "$pane_id" \
		> "$output_file" 2>&1 || true
}

assert_pane_contains()
{
	pane_id=$1
	needle=$2
	label=$3
	capture="$GOLDEN_RUN_DIR/$label-capture.txt"

	i=1
	while [ "$i" -le 100 ]; do
		capture_pane "$pane_id" "$capture"
		if grep -q "$needle" "$capture"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done

	echo "pane capture missing expected text" >&2
	echo "pane_id=$pane_id needle=$needle" >&2
	echo "capture=$capture" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
}

assert_pane_contains_at_least()
{
	pane_id=$1
	needle=$2
	min_count=$3
	label=$4
	capture="$GOLDEN_RUN_DIR/$label-capture.txt"

	i=1
	while [ "$i" -le 100 ]; do
		capture_pane "$pane_id" "$capture"
		count=$(grep -c "$needle" "$capture" 2>/dev/null || true)
		if [ "$count" -ge "$min_count" ]; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done

	echo "pane capture missing expected repeated text" >&2
	echo "pane_id=$pane_id needle=$needle min_count=$min_count" >&2
	echo "capture=$capture" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
}

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
require_golden_ui_environment
tmux_probe

if ! start_golden_ui_session "$UI_LOG"; then
	exit 1
fi

PRIMARY=$(primary_session)
record_golden_evidence "01-after-launch"

COUNT_BEFORE=$(newmux_cmd -f "$CONF" list-windows \
	-t "$PRIMARY" -F '#{window_id}' | wc -l | tr -d ' ')
press_key "t" "command down"
if ! wait_for_at_least_window_count "$PRIMARY" $((COUNT_BEFORE + 1)); then
	record_golden_evidence "02-cmd-t-create-delete-source-failed"
	echo "Cmd+T did not create a UI tab/window to delete" >&2
	exit 1
fi
record_golden_evidence "02-after-cmd-t-delete-source"

DELETE_SESSION=$(active_client_session)
DELETE_WINDOW=$(current_window_id "$DELETE_SESSION")
DELETE_PANE=$(newmux_cmd -f "$CONF" list-panes \
	-t "$PRIMARY:$DELETE_WINDOW" -F '#{pane_id}' | head -1)
RECOVER_MARKER="__NEWMUX_NONEMPTY_TAB_MARKER_${SOCKET_NAME}"
type_terminal_line_in_pane "$DELETE_PANE" \
	"printf '${RECOVER_MARKER}\\n${RECOVER_MARKER}_2\\n${RECOVER_MARKER}_3\\n'"
newmux_cmd -f "$CONF" send-keys -t "$DELETE_PANE" C-m \
	>/dev/null 2>&1 || true
assert_pane_contains_at_least "$DELETE_PANE" "$RECOVER_MARKER" 2 \
	"03-after-making-delete-source-recoverable"
record_golden_evidence "03-after-making-delete-source-recoverable"
press_key "w" "command down"
if ! wait_for_recovery_count 1; then
	record_golden_evidence "04-cmd-w-soft-delete-failed"
	echo "Cmd+W did not create one recoverable deleted tab" >&2
	exit 1
fi
record_golden_evidence "04-after-cmd-w-deleted-tab"

COUNT_AFTER_DELETE=$(newmux_cmd -f "$CONF" list-windows \
	-t "$PRIMARY" -F '#{window_id}' | wc -l | tr -d ' ')
press_key "t" "command down"
if ! wait_for_at_least_window_count "$PRIMARY" $((COUNT_AFTER_DELETE + 1)); then
	record_golden_evidence "05-cmd-t-fresh-open-failed"
	echo "Cmd+T did not create a fresh new tab/window after a deleted tab existed" >&2
	exit 1
fi
record_golden_evidence "05-after-cmd-t-fresh-open"

WINDOWS_AFTER=$(newmux_cmd -f "$CONF" list-windows \
	-t "$PRIMARY" -F '#{window_id}')
if printf '%s\n' "$WINDOWS_AFTER" | grep -Fxq "$DELETE_WINDOW"; then
	echo "Cmd+T reopened the deleted window instead of a fresh one" >&2
	echo "deleted_window=$DELETE_WINDOW" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

RECOVERY_AFTER=$(newmux_cmd -f "$CONF" newmux-list-recently-closed |
	sed '/^$/d' | wc -l | tr -d ' ')
if [ "$RECOVERY_AFTER" -ne 1 ]; then
	echo "Cmd+T fresh open should not consume deleted recovery state" >&2
	echo "recovery_after=$RECOVERY_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-newtab-fresh-clean UI test passed"
echo "  deleted_window=$DELETE_WINDOW"
echo "  recovery_after=$RECOVERY_AFTER"
echo "  evidence=$GOLDEN_RUN_DIR"
