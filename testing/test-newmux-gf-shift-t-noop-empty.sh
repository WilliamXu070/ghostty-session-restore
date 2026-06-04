#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-noop-$$"
GOLDEN_TEST_NAME="gf-shift-t-noop-empty"
UI_LOG="/tmp/newmux-gf-shift-t-noop-empty-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-noop-$$.sock"
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

PRIMARY=$(primary_session)
if [ -n "$(newmux_cmd -f "$CONF" newmux-list-recently-closed)" ]; then
	echo "Shift+T noop setup should start with empty recovery stack" >&2
	exit 1
fi

WINDOWS_BEFORE=$(newmux_cmd -f "$CONF" list-windows \
	-t "$PRIMARY" -F '#{window_id}' | wc -l | tr -d ' ')
PANES_BEFORE=$(newmux_cmd -f "$CONF" list-panes -a \
	-F '#{pane_id}' | wc -l | tr -d ' ')
record_golden_evidence "01-before-cmd-shift-t"

press_key "t" "command down, shift down"
record_golden_evidence "02-after-cmd-shift-t"

WINDOWS_AFTER=$(newmux_cmd -f "$CONF" list-windows \
	-t "$PRIMARY" -F '#{window_id}' | wc -l | tr -d ' ')
PANES_AFTER=$(newmux_cmd -f "$CONF" list-panes -a \
	-F '#{pane_id}' | wc -l | tr -d ' ')

if [ "$WINDOWS_AFTER" -ne "$WINDOWS_BEFORE" ]; then
	echo "Cmd+Shift+T with empty recovery stack changed window count" >&2
	echo "before=$WINDOWS_BEFORE after=$WINDOWS_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$PANES_AFTER" -ne "$PANES_BEFORE" ]; then
	echo "Cmd+Shift+T with empty recovery stack changed pane count" >&2
	echo "before=$PANES_BEFORE after=$PANES_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ -n "$(newmux_cmd -f "$CONF" newmux-list-recently-closed)" ]; then
	echo "Cmd+Shift+T with empty stack created recovery state" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-shift-t-noop-empty UI test passed"
echo "  windows=$WINDOWS_AFTER panes=$PANES_AFTER"
echo "  evidence=$GOLDEN_RUN_DIR"
