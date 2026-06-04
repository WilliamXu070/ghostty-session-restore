#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-gf-direct-launch-$$"
GOLDEN_TEST_NAME="gf-direct-launch-no-login-wrapper"
UI_LOG="/tmp/newmux-gf-direct-launch-no-login-wrapper-$$.log"

. "$ROOT/testing/test-newmux-golden-ui-helpers.sh"

TMPDIR="$ROOT/.local/newmux-tmp/$GOLDEN_TEST_NAME-$$"
export TMPDIR
mkdir -p "$TMPDIR"
NEWMUX_SOCKET_PATH="$ROOT/.local/nm-sock/gf-direct-launch-$$.sock"
export NEWMUX_SOCKET_PATH
mkdir -p "$(dirname "$NEWMUX_SOCKET_PATH")"

cleanup()
{
	stop_golden_ui_session
	newmux_cmd -f "$CONF" kill-server >/dev/null 2>&1 || true
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

assert_direct_config()
{
	if ! grep -q '^command = direct:.*/scripts/start-newmux-fresh.sh$' \
	    "$ROOT/ghostty-config/newmux.config"; then
		echo "Newmux Ghostty profile must launch start-newmux-fresh.sh directly" >&2
		exit 1
	fi
	if grep -q '^input = raw:exec .*/scripts/start-newmux-fresh.sh' \
	    "$ROOT/ghostty-config/newmux.config"; then
		echo "Newmux Ghostty profile must not inject startup exec input" >&2
		exit 1
	fi
}

client_parent_command()
{
	client_pid=$(newmux_cmd -f "$CONF" list-clients -F '#{client_pid}' |
		tail -1)
	parent_pid=$(ps -o ppid= -p "$client_pid" | tr -d ' ')
	ps -o command= -p "$parent_pid" 2>/dev/null || true
}

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
require_golden_ui_environment
assert_direct_config

start_ms=$(now_ms)
if ! start_golden_ui_session "$UI_LOG"; then
	exit 1
fi
end_ms=$(now_ms)
startup_ms=$((end_ms - start_ms))
record_golden_evidence "01-after-direct-launch"

parent_cmd=$(client_parent_command)
case "$parent_cmd" in
	*/usr/bin/login*|*"/usr/bin/login "*)
		echo "Newmux Ghostty client was still launched through macOS login" >&2
		echo "parent_cmd=$parent_cmd" >&2
		echo "startup_ms=$startup_ms" >&2
		echo "evidence=$GOLDEN_RUN_DIR" >&2
		exit 1
		;;
esac

echo "newmux gf-direct-launch-no-login-wrapper UI test passed"
echo "  startup_ms=$startup_ms"
echo "  parent_cmd=$parent_cmd"
echo "  evidence=$GOLDEN_RUN_DIR"
