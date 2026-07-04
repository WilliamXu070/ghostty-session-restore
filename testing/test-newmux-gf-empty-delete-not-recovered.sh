#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-empty-delete-$$"
GOLDEN_TEST_NAME="gf-empty-delete-not-recovered"
UI_LOG="/tmp/newmux-gf-empty-delete-not-recovered-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-empty-$$.sock"
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
WINDOWS_BEFORE=$(newmux_cmd -f "$CONF" list-windows \
	-t "$SESSION" -F '#{window_id}' | wc -l | tr -d ' ')
PANES_BEFORE=$(window_panes "$SESSION")
if [ "$PANES_BEFORE" -ne 1 ]; then
	echo "empty-delete scenario must begin with a single pane" >&2
	exit 1
fi
record_golden_evidence "01-before-empty-pane-delete"

press_key "w" "command down, option down"
record_golden_evidence "02-after-cmd-option-w-empty-pane"

PANES_AFTER_DELETE=$(window_panes "$SESSION")
if [ "$PANES_AFTER_DELETE" -ne 1 ]; then
	echo "Cmd+Option+W on the only pane should be blocked" >&2
	echo "panes_after=$PANES_AFTER_DELETE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ -n "$(newmux_cmd -f "$CONF" newmux-list-recently-closed)" ]; then
	echo "empty pane delete should not add anything to recovery stack" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

press_key "t" "command down, shift down"
record_golden_evidence "03-after-cmd-shift-t-empty-delete"

WINDOWS_AFTER=$(newmux_cmd -f "$CONF" list-windows \
	-t "$SESSION" -F '#{window_id}' | wc -l | tr -d ' ')
PANES_AFTER_RESTORE=$(window_panes "$SESSION")

if [ "$WINDOWS_AFTER" -ne "$WINDOWS_BEFORE" ]; then
	echo "Cmd+Shift+T after empty delete should not create a window" >&2
	echo "before=$WINDOWS_BEFORE after=$WINDOWS_AFTER" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

if [ "$PANES_AFTER_RESTORE" -ne 1 ]; then
	echo "Cmd+Shift+T after empty delete should not create a pane" >&2
	echo "panes_after=$PANES_AFTER_RESTORE" >&2
	echo "evidence=$GOLDEN_RUN_DIR" >&2
	exit 1
fi

echo "newmux gf-empty-delete-not-recovered UI test passed"
echo "  windows=$WINDOWS_AFTER panes=$PANES_AFTER_RESTORE"
echo "  evidence=$GOLDEN_RUN_DIR"
