#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-ui-status-$$"
GOLDEN_TEST_NAME="ui-status-hover"
UI_LOG="/tmp/newmux-ui-status-hover-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"

NEWMUX_SOCKET_PATH="/tmp/newmux-ui-status-$$.sock"
export NEWMUX_SOCKET_PATH

GOLDEN_RUN_DIR="$ROOT/.local/newmux-golden-runs/$GOLDEN_TEST_NAME-$$"
export GOLDEN_RUN_DIR
mkdir -p "$GOLDEN_RUN_DIR"

STATUS_FILE="$GOLDEN_RUN_DIR/ui-status.json"
export NEWMUX_UI_STATUS_FILE="$STATUS_FILE"
export NEWMUX_UI_BRIDGE_SOCKET="/tmp/newmux-ui-status-hover-$$.sock"
export NEWMUX_GHOSTTY_UI=1
export NEWMUX_GHOSTTY_UI_STATUS=1
export NEWMUX_GOLDEN_BACKGROUND_INPUT=0

cleanup()
{
	stop_golden_ui_session
	newmux_cmd -f "$CONF" kill-server >/dev/null 2>&1 || true
	rm -f "$NEWMUX_SOCKET_PATH"
}
trap cleanup EXIT INT TERM

wait_for_status_field()
{
	field=$1
	value=$2
	i=1
	while [ "$i" -le 160 ]; do
		if [ -f "$STATUS_FILE" ] &&
			grep -Eq "\"$field\"[[:space:]]*:[[:space:]]*$value" "$STATUS_FILE"; then
			return 0
		fi
		sleep 0.05
		i=$((i + 1))
	done
	return 1
}

status_number()
{
	field=$1
	awk -F: -v field="\"$field\"" '
		$1 ~ field {
			gsub(/[,[:space:]]/, "", $2)
			print $2
			exit
		}
	' "$STATUS_FILE"
}

expand_right_rail()
{
	coords=$(osascript \
		-e 'tell application "Ghostty" to activate' \
		-e 'tell application "System Events" to tell process "Ghostty"' \
		-e 'set frontmost to true' \
		-e 'set p to position of window 1' \
		-e 'set s to size of window 1' \
		-e 'set railX to (item 1 of p) + (item 1 of s) - 36' \
		-e 'set railY to (item 2 of p) + 130' \
		-e 'return (railX as text) & "," & (railY as text)' \
		-e 'end tell')

	if command -v cliclick >/dev/null 2>&1; then
		cliclick "m:$coords"
		return 0
	fi

	python3 - "$coords" <<'PY'
import sys
import time
import Quartz

x_text, y_text = sys.argv[1].split(",", 1)
x = float(x_text)
y = float(y_text)
point = Quartz.CGPoint(x, y)
Quartz.CGWarpMouseCursorPosition(point)
Quartz.CGAssociateMouseAndMouseCursorPosition(True)
time.sleep(0.25)
for event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
    event = Quartz.CGEventCreateMouseEvent(None, event_type, point, Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)
    time.sleep(0.05)
PY
}

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
require_golden_ui_environment

if ! start_golden_ui_session "$UI_LOG"; then
	exit 1
fi

if ! wait_for_status_field ui_enabled true; then
	echo "Newmux UI status file did not report ui_enabled=true" >&2
	echo "status_file=$STATUS_FILE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$(uname)" = Darwin ]; then
	screencapture -x "$GOLDEN_RUN_DIR/01-collapsed.png" >/dev/null 2>&1 || true
fi

before_tabs=$(status_number rail_tab_count)
press_key "t" "command down"
if ! wait_for_at_least_window_count "$(primary_session)" $((before_tabs + 1)); then
	record_golden_evidence "02-cmd-t-failed"
	echo "Cmd+T did not create an extra Newmux backend window" >&2
	echo "status_file=$STATUS_FILE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if ! wait_for_status_field rail_tab_count "$((before_tabs + 1))"; then
	record_golden_evidence "03-status-count-failed"
	echo "Newmux UI status did not observe the new rail tab count" >&2
	echo "expected=$((before_tabs + 1))" >&2
	echo "status_file=$STATUS_FILE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

expand_right_rail
if ! wait_for_status_field rail_expanded true; then
	record_golden_evidence "04-rail-expand-failed"
	echo "Right rail did not report expanded after pointer/click at right edge" >&2
	echo "status_file=$STATUS_FILE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$(uname)" = Darwin ]; then
	screencapture -x "$GOLDEN_RUN_DIR/05-expanded.png" >/dev/null 2>&1 || true
fi
cp "$STATUS_FILE" "$GOLDEN_RUN_DIR/final-ui-status.json"

echo "newmux ui-status hover test passed"
echo "  status_file=$STATUS_FILE"
echo "  evidence=$GOLDEN_RUN_DIR"
