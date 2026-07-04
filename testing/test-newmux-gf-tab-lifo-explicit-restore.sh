#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-tab-lifo-$$"
GOLDEN_TEST_NAME="gf-tab-lifo-explicit-restore"
UI_LOG="/tmp/newmux-gf-tab-lifo-explicit-restore-$$.log"
KEEP_OPEN=${NEWMUX_GOLDEN_KEEP_OPEN:-0}
NEWMUX_GOLDEN_BACKGROUND_INPUT=0
export NEWMUX_GOLDEN_BACKGROUND_INPUT

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-tab-lifo-$$.sock"
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

window_ids()
{
	newmux_cmd -f "$CONF" list-windows -t "$1" -F '#{window_id}'
}

pane_for_window()
{
	newmux_cmd -f "$CONF" list-panes -t "$1:$2" -F '#{pane_id}' |
		head -1
}

make_recoverable_window()
{
	name=$1
	marker=$2

	window_id=$(newmux_cmd -f "$CONF" new-window -d -P \
		-F '#{window_id}' -t "$PRIMARY:" -n "$name" \
		"printf '%s\\n' '$marker'; exec /bin/zsh")
	if ! wait_for_window_marker "$window_id" "$marker"; then
		record_golden_evidence "window-marker-timeout-$name"
		echo "recoverable window marker did not appear" >&2
		echo "window=$window_id marker=$marker" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	printf '%s\n' "$window_id"
}

capture_window()
{
	window_id=$1
	output_file=$2
	pane_id=$(pane_for_window "$PRIMARY" "$window_id")
	newmux_cmd -f "$CONF" capture-pane -epS - -t "$pane_id" \
		> "$output_file" 2>&1 || true
}

wait_for_window_marker()
{
	window_id=$1
	marker=$2
	output_file="$GOLDEN_RUN_DIR/wait-$window_id.txt"
	i=1
	while [ "$i" -le 100 ]; do
		capture_window "$window_id" "$output_file"
		if grep -q "$marker" "$output_file"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

restore_next_window()
{
	NEWMUX_SOCKET="$SOCKET_NAME" \
	NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
	NEWMUX_RESTORE_OPEN_TAB=0 \
	NEWMUX_SESSION="$PRIMARY" \
		"$ROOT/scripts/request-newmux-restore-tab.sh" \
		"$NEWMUX_SOCKET_PATH" >/dev/null 2>&1 || true

	NEWMUX_SOCKET="$SOCKET_NAME" \
	NEWMUX_SOCKET_PATH="$NEWMUX_SOCKET_PATH" \
	NEWMUX_STARTER_ASSUME_CLIENTS=1 \
	NEWMUX_STARTER_PRINT_WINDOW=1 \
	NEWMUX_SESSION="$PRIMARY" \
		"$ROOT/scripts/start-newmux-fresh.sh" 2>/dev/null || true
}

assert_restored_window()
{
	actual=$1
	expected=$2
	marker=$3
	label=$4

	if [ "$actual" != "$expected" ]; then
		record_golden_evidence "$label-wrong-window"
		echo "restore returned the wrong window" >&2
		echo "expected=$expected actual=$actual" >&2
		echo "stale_window=$STALE_WINDOW" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	if [ "$actual" = "$STALE_WINDOW" ]; then
		record_golden_evidence "$label-stale-window"
		echo "restore attached the stale unrepresented window" >&2
		echo "stale_window=$STALE_WINDOW" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi

	newmux_cmd -f "$CONF" select-window -t "$SESSION:$actual"
	record_golden_evidence "$label"

	capture="$GOLDEN_RUN_DIR/$label-capture.txt"
	capture_window "$actual" "$capture"
	if ! grep -q "$marker" "$capture"; then
		echo "restored window did not contain its marker" >&2
		echo "window_id=$actual marker=$marker" >&2
		echo "capture=$capture" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	if grep -q "$STALE_MARKER" "$capture"; then
		echo "restored window capture contained stale marker" >&2
		echo "window_id=$actual stale_marker=$STALE_MARKER" >&2
		echo "capture=$capture" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
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

STALE_MARKER="__NEWMUX_STALE_UNREPRESENTED_${SOCKET_NAME}_$$"
STALE_WINDOW=$(make_recoverable_window "stale-unrepresented" "$STALE_MARKER")
record_golden_evidence "02-after-stale-unrepresented-window"

MARKER_A="__NEWMUX_LIFO_RESTORE_A_${SOCKET_NAME}_$$"
MARKER_B="__NEWMUX_LIFO_RESTORE_B_${SOCKET_NAME}_$$"
MARKER_C="__NEWMUX_LIFO_RESTORE_C_${SOCKET_NAME}_$$"
WINDOW_A=$(make_recoverable_window "lifo-a" "$MARKER_A")
WINDOW_B=$(make_recoverable_window "lifo-b" "$MARKER_B")
WINDOW_C=$(make_recoverable_window "lifo-c" "$MARKER_C")

newmux_cmd -f "$CONF" newmux-soft-delete-window \
	-t "$PRIMARY:$WINDOW_A" >/dev/null
newmux_cmd -f "$CONF" newmux-soft-delete-window \
	-t "$PRIMARY:$WINDOW_B" >/dev/null
newmux_cmd -f "$CONF" newmux-soft-delete-window \
	-t "$PRIMARY:$WINDOW_C" >/dev/null
if ! wait_for_recovery_count 3; then
	record_golden_evidence "03-recovery-stack-count-failed"
	echo "expected three recoverable deleted tabs" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi
record_golden_evidence "03-after-soft-delete-a-b-c"

RESTORED_C=$(restore_next_window)
assert_restored_window "$RESTORED_C" "$WINDOW_C" "$MARKER_C" \
	"04-after-restore-c"
if ! wait_for_recovery_count 2; then
	echo "expected two recoverable deleted tabs after first restore" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

RESTORED_B=$(restore_next_window)
assert_restored_window "$RESTORED_B" "$WINDOW_B" "$MARKER_B" \
	"05-after-restore-b"
if ! wait_for_recovery_count 1; then
	echo "expected one recoverable deleted tab after second restore" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

RESTORED_A=$(restore_next_window)
assert_restored_window "$RESTORED_A" "$WINDOW_A" "$MARKER_A" \
	"06-after-restore-a"
if ! wait_for_recovery_count 0; then
	echo "expected empty recovery stack after LIFO restores" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if ! window_ids "$PRIMARY" | grep -qx "$STALE_WINDOW"; then
	echo "stale unrepresented window should remain active state, not recovery" >&2
	echo "stale_window=$STALE_WINDOW" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-tab-lifo-explicit-restore UI test passed"
echo "  stale_window=$STALE_WINDOW"
echo "  restored_order=$RESTORED_C,$RESTORED_B,$RESTORED_A"
echo "  expected_order=$WINDOW_C,$WINDOW_B,$WINDOW_A"
echo "  evidence=$GOLDEN_RUN_DIR"
