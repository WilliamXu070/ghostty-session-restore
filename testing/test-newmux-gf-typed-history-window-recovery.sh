#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-typed-window-$$"
GOLDEN_TEST_NAME="gf-typed-history-window-recovery"
UI_LOG="/tmp/newmux-gf-typed-history-window-recovery-$$.log"
KEEP_OPEN=${NEWMUX_GOLDEN_KEEP_OPEN:-1}
NEWMUX_USE_PATCHED_GHOSTTY=${NEWMUX_USE_PATCHED_GHOSTTY:-0}
NEWMUX_GOLDEN_BACKGROUND_INPUT=0
export NEWMUX_USE_PATCHED_GHOSTTY
export NEWMUX_GOLDEN_BACKGROUND_INPUT

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="${TMPDIR:-$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$}"
if [ "$TMPDIR" = "$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$" ]; then
	mkdir -p "$TMPDIR"
fi
export TMPDIR
NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-$ROOT/.local/nm-sock/gf-typed-win-$$.sock}"
mkdir -p "$(dirname "$NEWMUX_SOCKET_PATH")"
export NEWMUX_SOCKET_PATH

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

window_ids()
{
	newmux_cmd -f "$CONF" list-windows -t "$1" -F '#{window_id}'
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
PRIMARY=$(primary_session)
record_golden_evidence "01-after-launch"

WINDOWS_BEFORE=$(window_ids "$PRIMARY")
COUNT_BEFORE=$(printf '%s\n' "$WINDOWS_BEFORE" | sed '/^$/d' | wc -l | tr -d ' ')
press_key "t" "command down"
if ! wait_for_at_least_window_count "$PRIMARY" $((COUNT_BEFORE + 1)); then
	record_golden_evidence "02-new-window-for-history-failed"
	echo "Cmd+T did not create a window for typed history recovery" >&2
	exit 1
fi
TARGET_WINDOW=$(window_ids "$PRIMARY" |
	while IFS= read -r window_id; do
		if ! printf '%s\n' "$WINDOWS_BEFORE" | grep -Fqx "$window_id"; then
			printf '%s\n' "$window_id"
			break
		fi
	done)
if [ -z "$TARGET_WINDOW" ]; then
	record_golden_evidence "02-new-window-id-missing"
	echo "could not identify typed-history target window" >&2
	exit 1
fi
TARGET_PANE=$(newmux_cmd -f "$CONF" list-panes -t "$PRIMARY:$TARGET_WINDOW" \
	-F '#{pane_id}' | head -1)
TARGET_PID_BEFORE=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')
RECOVERY_MARKER="__NEWMUX_RECOVERED_HISTORY_${SOCKET_NAME}_$$"
STEP_MARKER_PREFIX="__NEWMUX_TYPED_HISTORY_STEP_"
STEP_COUNT=10
newmux_cmd -f "$CONF" select-window -t "$SESSION:$TARGET_WINDOW"
record_golden_evidence "02-after-new-window"

i=1
while [ "$i" -le "$STEP_COUNT" ]; do
	step=$(printf '%02d' "$i")
	newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" -l "ls"
	newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" Enter
	newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" -l "echo ${STEP_MARKER_PREFIX}${step}"
	newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" Enter
	sleep 0.2
	i=$((i + 1))
done
newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" -l "echo codex"
newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" Enter
newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" -l "echo $RECOVERY_MARKER"
newmux_cmd -f "$CONF" send-keys -t "$TARGET_PANE" Enter
sleep 0.2
record_golden_evidence "03-after-typed-ls-ten-times-and-codex"

BEFORE_CAPTURE="$GOLDEN_RUN_DIR/typed-window-history-before-delete.txt"
newmux_cmd -f "$CONF" capture-pane -epS - -t "$TARGET_PANE" \
	> "$BEFORE_CAPTURE" 2>&1 || true
STEP_COUNT_BEFORE=0
i=1
while [ "$i" -le "$STEP_COUNT" ]; do
	step=$(printf '%02d' "$i")
	if ! grep -q "${STEP_MARKER_PREFIX}${step}" "$BEFORE_CAPTURE"; then
		echo "typed window setup missing step marker before delete" >&2
		echo "marker=${STEP_MARKER_PREFIX}${step}" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	STEP_COUNT_BEFORE=$((STEP_COUNT_BEFORE + 1))
	i=$((i + 1))
done
if [ "$STEP_COUNT_BEFORE" -ne "$STEP_COUNT" ]; then
	echo "typed window setup should include exactly ten step markers before delete" >&2
	echo "step_count_before=$STEP_COUNT_BEFORE expected=$STEP_COUNT" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! grep -q 'codex' "$BEFORE_CAPTURE"; then
	echo "typed window setup should show codex before delete" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! grep -q "$RECOVERY_MARKER" "$BEFORE_CAPTURE"; then
	echo "typed window setup should include recovery marker before delete" >&2
	echo "marker=$RECOVERY_MARKER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

CURRENT_WINDOW_BEFORE_DELETE=$(current_window_id "$SESSION")
if [ "$CURRENT_WINDOW_BEFORE_DELETE" != "$TARGET_WINDOW" ]; then
	record_golden_evidence "04-typed-window-not-active-before-delete"
	echo "typed-history window should be active before Cmd+W delete" >&2
	echo "expected=$TARGET_WINDOW active=$CURRENT_WINDOW_BEFORE_DELETE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

press_key "w" "command down"
if ! wait_for_window_count "$PRIMARY" "$COUNT_BEFORE"; then
	record_golden_evidence "04-delete-typed-window-failed"
	echo "Cmd+W did not delete the typed-history window" >&2
	exit 1
fi
if ! wait_for_recovery_count 1; then
	record_golden_evidence "04-recovery-stack-after-typed-window-delete-failed"
	echo "typed-history window delete did not enter recovery stack" >&2
	exit 1
fi
record_golden_evidence "04-after-cmd-w-delete-typed-window"

press_key "t" "command down, shift down"
if ! wait_for_at_least_window_count "$PRIMARY" $((COUNT_BEFORE + 1)); then
	record_golden_evidence "05-restore-typed-window-failed"
	echo "Cmd+Shift+T did not restore the typed-history window" >&2
	exit 1
fi
record_golden_evidence "05-after-cmd-shift-t-restore-typed-window"

if ! window_ids "$PRIMARY" | grep -qx "$TARGET_WINDOW"; then
	echo "restored typed-history window should keep original window id" >&2
	echo "window_id=$TARGET_WINDOW" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! newmux_cmd -f "$CONF" list-panes -t "$PRIMARY:$TARGET_WINDOW" \
	-F '#{pane_id}' | grep -qx "$TARGET_PANE"; then
	echo "restored typed-history window should keep original pane id" >&2
	echo "pane_id=$TARGET_PANE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

TARGET_PID_AFTER=$(newmux_cmd -f "$CONF" display-message \
	-p -t "$TARGET_PANE" '#{pane_pid}')
if [ "$TARGET_PID_AFTER" != "$TARGET_PID_BEFORE" ]; then
	echo "restored typed-history window should keep the same live process" >&2
	echo "before_pid=$TARGET_PID_BEFORE after_pid=$TARGET_PID_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

AFTER_CAPTURE="$GOLDEN_RUN_DIR/typed-window-history-after-restore.txt"
newmux_cmd -f "$CONF" capture-pane -epS - -t "$TARGET_PANE" \
	> "$AFTER_CAPTURE" 2>&1 || true
STEP_COUNT_AFTER=0
AFTER_LAST_STEP_LINE=0
i=1
while [ "$i" -le "$STEP_COUNT" ]; do
	step=$(printf '%02d' "$i")
	marker_line=$(grep -n "${STEP_MARKER_PREFIX}${step}" "$AFTER_CAPTURE" \
		| head -n 1 | cut -d: -f1 || true)
	if [ -z "$marker_line" ]; then
		echo "restored window should preserve all typed ls step markers" >&2
		echo "missing_marker=${STEP_MARKER_PREFIX}${step}" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	if [ "$marker_line" -lt "$AFTER_LAST_STEP_LINE" ]; then
		echo "step markers changed order after restore" >&2
		echo "marker=${STEP_MARKER_PREFIX}${step}" >&2
		echo "previous_marker_line=$AFTER_LAST_STEP_LINE" >&2
		echo "current_marker_line=$marker_line" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	AFTER_LAST_STEP_LINE=$marker_line
	STEP_COUNT_AFTER=$((STEP_COUNT_AFTER + 1))
	i=$((i + 1))
done
if [ "$STEP_COUNT_AFTER" -ne "$STEP_COUNT" ]; then
	echo "restored window should preserve exactly ten step markers" >&2
	echo "step_count_after=$STEP_COUNT_AFTER expected=$STEP_COUNT" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
AFTER_CODex_LINE=$(grep -n 'echo codex' "$AFTER_CAPTURE" \
	| head -n 1 | cut -d: -f1 || true)
if [ -z "$AFTER_CODex_LINE" ]; then
	echo "restored window should preserve typed codex command" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$AFTER_CODex_LINE" -le "$AFTER_LAST_STEP_LINE" ]; then
	echo "restored window should keep codex command after all step markers" >&2
	echo "last_step_line=$AFTER_LAST_STEP_LINE" >&2
	echo "codex_line=$AFTER_CODex_LINE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

AFTER_RECOVERY_LINE=$(grep -n "$RECOVERY_MARKER" "$AFTER_CAPTURE" \
	| head -n 1 | cut -d: -f1 || true)
if [ -z "$AFTER_RECOVERY_LINE" ]; then
	echo "restored window should preserve recovery marker in visible buffer" >&2
	echo "marker=$RECOVERY_MARKER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$AFTER_RECOVERY_LINE" -le "$AFTER_CODex_LINE" ]; then
	echo "restored window should keep recovery marker after codex command" >&2
	echo "codex_line=$AFTER_CODex_LINE" >&2
	echo "recovery_line=$AFTER_RECOVERY_LINE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if ! grep -q 'codex' "$AFTER_CAPTURE"; then
	echo "restored window should preserve typed codex output" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
if ! grep -q "$RECOVERY_MARKER" "$AFTER_CAPTURE"; then
	echo "restored window should preserve recovery marker in visible buffer" >&2
	echo "marker=$RECOVERY_MARKER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

AFTER_CAPTURE_LINES=$(wc -l < "$AFTER_CAPTURE")
if [ "$AFTER_CAPTURE_LINES" -lt 1 ]; then
	echo "restored capture should contain output" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-typed-history-window-recovery UI test passed"
echo "  window_id=$TARGET_WINDOW"
echo "  pane_id=$TARGET_PANE"
echo "  pid=$TARGET_PID_AFTER"
echo "  step_count_after=$STEP_COUNT_AFTER"
echo "  evidence=$GOLDEN_RUN_DIR"
if [ "$KEEP_OPEN" = 1 ]; then
	echo "  kept_open=1"
fi
