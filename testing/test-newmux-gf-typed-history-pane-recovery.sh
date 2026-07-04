#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-typed-pane-$$"
GOLDEN_TEST_NAME="gf-typed-history-pane-recovery"
UI_LOG="/tmp/newmux-gf-typed-history-pane-recovery-$$.log"
KEEP_OPEN=${NEWMUX_GOLDEN_KEEP_OPEN:-1}

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-typed-pane-$$.sock"
export NEWMUX_SOCKET_PATH
mkdir -p "$(dirname "$NEWMUX_SOCKET_PATH")"

cleanup()
{
	if [ "$KEEP_OPEN" = 1 ]; then
		return
	fi
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
	record_golden_evidence "02-split-for-history-failed"
	echo "Cmd+D did not create a pane for typed history recovery" >&2
	exit 1
fi

TARGET_PANE=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$SESSION:" '#{pane_id}')
TARGET_PID_BEFORE=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')
record_golden_evidence "02-after-split"

i=1
while [ "$i" -le 10 ]; do
	type_terminal_line_in_pane "$TARGET_PANE" "ls"
	i=$((i + 1))
done
type_terminal_line_in_pane "$TARGET_PANE" "echo codex"
record_golden_evidence "03-after-typed-ls-ten-times-and-codex"

BEFORE_CAPTURE="$GOLDEN_RUN_DIR/typed-pane-history-before-delete.txt"
newmux_cmd -f "$CONF" capture-pane -epS - -t "$TARGET_PANE" \
	> "$BEFORE_CAPTURE" 2>&1 || true
LS_COUNT_BEFORE=$(grep -c 'ls' "$BEFORE_CAPTURE" || true)
if [ "$LS_COUNT_BEFORE" -lt 10 ]; then
	echo "typed pane setup should show at least ten ls entries before delete" >&2
	echo "ls_count_before=$LS_COUNT_BEFORE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! grep -q 'codex' "$BEFORE_CAPTURE"; then
	echo "typed pane setup should show codex before delete" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

press_key "w" "command down, option down"
if ! wait_for_panes "$SESSION" 1; then
	record_golden_evidence "04-delete-typed-pane-failed"
	echo "Cmd+Option+W did not delete the typed-history pane" >&2
	exit 1
fi
if ! wait_for_recovery_count 1; then
	record_golden_evidence "04-recovery-stack-after-typed-delete-failed"
	echo "typed-history pane delete did not enter recovery stack" >&2
	exit 1
fi
record_golden_evidence "04-after-delete-typed-pane"

press_key "t" "command down, shift down"
if ! wait_for_panes "$SESSION" 2; then
	record_golden_evidence "05-restore-typed-pane-failed"
	echo "Cmd+Shift+T did not restore the typed-history pane" >&2
	exit 1
fi
record_golden_evidence "05-after-restore-typed-pane"

if ! newmux_cmd -f "$CONF" list-panes -t "$SESSION:" \
	-F '#{pane_id}' | grep -qx "$TARGET_PANE"; then
	echo "restored typed-history pane should keep original pane id" >&2
	echo "pane_id=$TARGET_PANE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

TARGET_PID_AFTER=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')
if [ "$TARGET_PID_AFTER" != "$TARGET_PID_BEFORE" ]; then
	echo "restored typed-history pane should keep the same live process" >&2
	echo "before_pid=$TARGET_PID_BEFORE after_pid=$TARGET_PID_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

AFTER_CAPTURE="$GOLDEN_RUN_DIR/typed-pane-history-after-restore.txt"
newmux_cmd -f "$CONF" capture-pane -epS - -t "$TARGET_PANE" \
	> "$AFTER_CAPTURE" 2>&1 || true
LS_COUNT_AFTER=$(grep -c 'ls' "$AFTER_CAPTURE" || true)
if [ "$LS_COUNT_AFTER" -lt 10 ]; then
	echo "restored pane should preserve at least ten ls entries" >&2
	echo "ls_count_after=$LS_COUNT_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! grep -q 'codex' "$AFTER_CAPTURE"; then
	echo "restored pane should preserve typed codex command" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-typed-history-pane-recovery UI test passed"
echo "  pane_id=$TARGET_PANE"
echo "  pid=$TARGET_PID_AFTER"
echo "  ls_count_after=$LS_COUNT_AFTER"
echo "  evidence=$GOLDEN_RUN_DIR"
if [ "$KEEP_OPEN" = 1 ]; then
	echo "  kept_open=1"
fi
