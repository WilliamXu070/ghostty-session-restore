#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-layout-$$"
GOLDEN_TEST_NAME="gf-recover-layout-locality"
UI_LOG="/tmp/newmux-gf-recover-layout-locality-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-layout-$$.sock"
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

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
require_golden_ui_environment
tmux_probe

if ! start_golden_ui_session "$UI_LOG"; then
	exit 1
fi

SESSION=$(active_client_session)
record_golden_evidence "01-after-launch"

press_key "d" "command down"
if ! wait_for_panes "$SESSION" 2; then
	record_golden_evidence "02-cmd-d-split-right-failed"
	echo "Cmd+D did not create a right split" >&2
	exit 1
fi
record_golden_evidence "02-after-cmd-d-split-right"

press_key "d" "command down, shift down"
if ! wait_for_panes "$SESSION" 3; then
	record_golden_evidence "03-cmd-shift-d-split-down-failed"
	echo "Cmd+Shift+D did not create a down split" >&2
	exit 1
fi
record_golden_evidence "03-after-cmd-shift-d-split-down"

LAYOUT_BEFORE=$(window_layout "$SESSION")
TARGET_PANE=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$SESSION:" '#{pane_id}')
TARGET_PID_BEFORE=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')

press_key "w" "command down, option down"
if ! wait_for_panes "$SESSION" 2; then
	record_golden_evidence "04-cmd-option-w-delete-pane-failed"
	echo "Cmd+Option+W did not soft-delete the active pane" >&2
	exit 1
fi
if ! wait_for_recovery_count 1; then
	record_golden_evidence "04-recovery-stack-after-delete-failed"
	echo "soft-deleted pane was not recorded in recovery stack" >&2
	exit 1
fi
record_golden_evidence "04-after-cmd-option-w-delete-pane"

press_key "t" "command down, shift down"
if ! wait_for_panes "$SESSION" 3; then
	record_golden_evidence "05-cmd-shift-t-restore-pane-failed"
	echo "Cmd+Shift+T did not restore the deleted pane" >&2
	exit 1
fi
record_golden_evidence "05-after-cmd-shift-t-restore-pane"

if ! newmux_cmd -f "$CONF" list-panes -t "$SESSION:" \
	-F '#{pane_id}' | grep -qx "$TARGET_PANE"; then
	echo "restored layout does not contain original pane id" >&2
	echo "pane_id=$TARGET_PANE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

TARGET_PID_AFTER=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')
if [ "$TARGET_PID_AFTER" != "$TARGET_PID_BEFORE" ]; then
	echo "restored pane should keep the same live process" >&2
	echo "before_pid=$TARGET_PID_BEFORE after_pid=$TARGET_PID_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

LAYOUT_AFTER=$(window_layout "$SESSION")
if [ "$(normalize_layout "$LAYOUT_AFTER")" != "$(normalize_layout "$LAYOUT_BEFORE")" ]; then
	echo "layout locality lost after restore" >&2
	echo "before=$LAYOUT_BEFORE" >&2
	echo "after=$LAYOUT_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-recover-layout-locality UI test passed"
echo "  pane_id=$TARGET_PANE"
echo "  pid=$TARGET_PID_AFTER"
echo "  evidence=$GOLDEN_RUN_DIR"
