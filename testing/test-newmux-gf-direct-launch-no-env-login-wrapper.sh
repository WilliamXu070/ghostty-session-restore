#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
SOCKET_PATH="$ROOT/.local/nm-sock/gf-direct-no-env-$$.sock"
XDG_HOME="$ROOT/.local/newmux-tmp/gf-direct-no-env-$$/xdg"
LOG_FILE="$ROOT/.local/newmux-golden-runs/gf-direct-launch-no-env-login-wrapper-$$.log"

cleanup()
{
	osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
	pkill -f "Ghostty.app/Contents/MacOS/ghostty .*gf-direct-no-env-$$" \
		>/dev/null 2>&1 || true
	"$NEWMUX" -S "$SOCKET_PATH" kill-server >/dev/null 2>&1 || true
	rm -rf "$XDG_HOME" "$SOCKET_PATH"
}
trap cleanup EXIT INT TERM

if [ "$(uname)" != Darwin ]; then
	echo "newmux direct no-env launch test requires macOS" >&2
	exit 77
fi
if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi
if [ ! -x /Applications/Ghostty.app/Contents/MacOS/ghostty ]; then
	echo "Ghostty.app executable not found" >&2
	exit 77
fi

mkdir -p "$XDG_HOME/ghostty" "$(dirname "$SOCKET_PATH")" "$(dirname "$LOG_FILE")"
: > "$XDG_HOME/ghostty/config"
rm -f "$SOCKET_PATH"

(
	exec env -u NEWMUX_GHOSTTY_SKIP_LOGIN \
		XDG_CONFIG_HOME="$XDG_HOME" \
		PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
		NEWMUX_ROOT="$ROOT" \
		NEWMUX_SOCKET="gf-direct-no-env-$$" \
		NEWMUX_SOCKET_PATH="$SOCKET_PATH" \
		/Applications/Ghostty.app/Contents/MacOS/ghostty \
		--config-file="$ROOT/ghostty-config/newmux.config"
) >"$LOG_FILE" 2>&1 &

i=1
while [ "$i" -le 100 ]; do
	client_pid=$("$NEWMUX" -S "$SOCKET_PATH" list-clients \
		-F '#{client_pid}' 2>/dev/null | tail -1 || true)
	[ -n "$client_pid" ] && break
	sleep 0.05
	i=$((i + 1))
done

if [ -z "${client_pid:-}" ]; then
	echo "Newmux client did not attach" >&2
	echo "log=$LOG_FILE" >&2
	exit 1
fi

parent_pid=$(ps -o ppid= -p "$client_pid" | tr -d ' ')
parent_cmd=$(ps -o command= -p "$parent_pid" 2>/dev/null || true)

case "$parent_cmd" in
	*/usr/bin/login*|*"/usr/bin/login "*)
		echo "Newmux direct command was launched through macOS login" >&2
		echo "client_pid=$client_pid" >&2
		echo "parent_pid=$parent_pid" >&2
		echo "parent_cmd=$parent_cmd" >&2
		echo "log=$LOG_FILE" >&2
		exit 1
		;;
esac

echo "newmux gf-direct-launch-no-env-login-wrapper UI test passed"
echo "  client_pid=$client_pid"
echo "  parent_pid=$parent_pid"
echo "  parent_cmd=$parent_cmd"
echo "  log=$LOG_FILE"
