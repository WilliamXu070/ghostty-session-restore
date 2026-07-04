#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-five-tab-$$"
GOLDEN_TEST_NAME="gf-five-tab-restore-order-latency"
UI_LOG="/tmp/newmux-gf-five-tab-restore-order-latency-$$.log"
KEEP_OPEN=${NEWMUX_GOLDEN_KEEP_OPEN:-0}
NEWMUX_GOLDEN_BACKGROUND_INPUT=0
export NEWMUX_GOLDEN_BACKGROUND_INPUT

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-five-tab-$$.sock"
export NEWMUX_SOCKET_PATH
mkdir -p "$(dirname "$NEWMUX_SOCKET_PATH")"

TEST_BIN="$TMPDIR/bin"
mkdir -p "$TEST_BIN"
cat > "$TEST_BIN/hello" <<'EOS'
#!/bin/sh
printf '__NEWMUX_FIVE_TAB_HELLO_COMMAND_EXECUTED__\n'
EOS
cat > "$TEST_BIN/codex" <<'EOS'
#!/bin/sh
printf '__NEWMUX_FIVE_TAB_CODEX_COMMAND_EXECUTED__\n'
EOS
chmod +x "$TEST_BIN/hello" "$TEST_BIN/codex"
PATH="$TEST_BIN:$PATH"
export PATH
NEWMUX_USER_ZSHRC_SOURCED=1
export NEWMUX_USER_ZSHRC_SOURCED

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

now_ms()
{
	if command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'
	else
		printf '%s000\n' "$(date +%s)"
	fi
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

capture_window()
{
	window_id=$1
	output_file=$2
	pane_id=$(pane_for_window "$PRIMARY" "$window_id")
	newmux_cmd -f "$CONF" capture-pane -epS - -t "$pane_id" \
		> "$output_file" 2>&1 || true
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

type_terminal_text()
{
	text=$1

	if ! wait_for_ghostty_frontmost_window; then
		echo "Ghostty was not ready before typing terminal text" >&2
		return 1
	fi
	osascript \
		-e 'tell application "Ghostty" to activate' \
		-e 'tell application "System Events" to tell process "Ghostty" to set frontmost to true' \
		-e "tell application \"System Events\" to keystroke \"$text\""
	sleep 0.2
}

open_new_tab()
{
	before=$1
	press_key "t" "command down"
	if ! wait_for_at_least_window_count "$PRIMARY" $((before + 1)); then
		record_golden_evidence "open-tab-count-failed-$before"
		echo "Cmd+T did not create expected tab" >&2
		echo "before=$before" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	window_ids "$PRIMARY" | tail -1
}

wait_for_window_absent()
{
	window_id=$1
	i=1
	while [ "$i" -le 100 ]; do
		if ! window_ids "$PRIMARY" | grep -qx "$window_id"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done
	return 1
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

delete_window_in_original_order()
{
	index=$1
	window_id=$2
	needle=$3
	expected_recovery_count=$4

	assert_capture_contains "$window_id" "$needle" \
		"delete-${index}-before"
	press_key "w" "command down"
	if ! wait_for_window_absent "$window_id"; then
		record_golden_evidence "delete-${index}-window-still-present"
		echo "deleted window still exists after Cmd+W" >&2
		echo "window_id=$window_id" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	if ! wait_for_recovery_count "$expected_recovery_count"; then
		record_golden_evidence "delete-${index}-recovery-count-failed"
		echo "unexpected recovery stack count after deleting tab" >&2
		echo "window_id=$window_id expected=$expected_recovery_count" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	record_golden_evidence "delete-${index}-after"
}

restore_and_assert()
{
	index=$1
	expected_window=$2
	needle=$3
	expected_remaining=$4

	start_ms=$(now_ms)
	press_key "t" "command down, shift down"
	if ! wait_for_represented_window "$expected_window"; then
		record_golden_evidence "restore-${index}-not-represented"
		echo "restored window was not represented by a native tab" >&2
		echo "expected_window=$expected_window" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	if ! wait_for_recovery_count "$expected_remaining"; then
		record_golden_evidence "restore-${index}-recovery-count-failed"
		echo "unexpected recovery stack count after restore" >&2
		echo "expected_remaining=$expected_remaining" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
	fi
	end_ms=$(now_ms)
	latency_ms=$((end_ms - start_ms))
	printf '%s\t%s\t%s\n' "$index" "$expected_window" "$latency_ms" \
		>> "$TIMINGS_FILE"

	record_golden_evidence "restore-${index}-after"
	assert_capture_contains "$expected_window" "$needle" \
		"restore-${index}-after"
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
TIMINGS_FILE="$GOLDEN_RUN_DIR/restore-timings.tsv"
printf 'restore_index\twindow_id\tlatency_ms\n' > "$TIMINGS_FILE"
ANCHOR_WINDOW=$(current_window_id "$SESSION")
record_golden_evidence "01-after-launch"

COUNT=$(window_ids "$PRIMARY" | wc -l | tr -d ' ')
WINDOW_1=$(open_new_tab "$COUNT")
type_terminal_line "hello"
assert_capture_contains "$WINDOW_1" "hello" "setup-tab-1"
record_golden_evidence "02-tab-1-hello-enter"

COUNT=$(window_ids "$PRIMARY" | wc -l | tr -d ' ')
WINDOW_2=$(open_new_tab "$COUNT")
type_terminal_text "bye"
assert_capture_contains "$WINDOW_2" "bye" "setup-tab-2"
record_golden_evidence "03-tab-2-bye-typed"

COUNT=$(window_ids "$PRIMARY" | wc -l | tr -d ' ')
WINDOW_3=$(open_new_tab "$COUNT")
type_terminal_text "truth"
assert_capture_contains "$WINDOW_3" "truth" "setup-tab-3"
record_golden_evidence "04-tab-3-truth-typed"

COUNT=$(window_ids "$PRIMARY" | wc -l | tr -d ' ')
WINDOW_4=$(open_new_tab "$COUNT")
type_terminal_line "codex"
assert_capture_contains "$WINDOW_4" "codex" "setup-tab-4"
record_golden_evidence "05-tab-4-codex-enter"

COUNT=$(window_ids "$PRIMARY" | wc -l | tr -d ' ')
WINDOW_5=$(open_new_tab "$COUNT")
type_terminal_text "sudo"
assert_capture_contains "$WINDOW_5" "sudo" "setup-tab-5"
record_golden_evidence "06-tab-5-sudo-typed"

press_key "tab" "control down"
sleep 0.25
press_key "tab" "control down"
sleep 0.25
record_golden_evidence "07-after-control-tab-to-first-user-tab"

delete_window_in_original_order 1 "$WINDOW_1" "hello" 1
delete_window_in_original_order 2 "$WINDOW_2" "bye" 2
delete_window_in_original_order 3 "$WINDOW_3" "truth" 3
delete_window_in_original_order 4 "$WINDOW_4" "codex" 4
delete_window_in_original_order 5 "$WINDOW_5" "sudo" 5
record_golden_evidence "08-after-delete-1-2-3-4-5"

restore_and_assert 1 "$WINDOW_5" "sudo" 4
restore_and_assert 2 "$WINDOW_4" "codex" 3
restore_and_assert 3 "$WINDOW_3" "truth" 2
restore_and_assert 4 "$WINDOW_2" "bye" 1
restore_and_assert 5 "$WINDOW_1" "hello" 0

max_latency=$(awk 'NR > 1 { if ($3 > max) max = $3 } END { print max + 0 }' \
	"$TIMINGS_FILE")

echo "newmux gf-five-tab-restore-order-latency UI test passed"
echo "  anchor_window=$ANCHOR_WINDOW"
echo "  opened_order=$WINDOW_1,$WINDOW_2,$WINDOW_3,$WINDOW_4,$WINDOW_5"
echo "  restored_order=$WINDOW_5,$WINDOW_4,$WINDOW_3,$WINDOW_2,$WINDOW_1"
echo "  max_restore_latency_ms=$max_latency"
echo "  timings=$TIMINGS_FILE"
echo "  evidence=$GOLDEN_RUN_DIR"
