#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-codex-resume-test}
TARGET=${1:-newmux-codex-resume:main}
START_DELAY=${CODEX_RESUME_START_DELAY:-0.8}
STEP_DELAY=${CODEX_RESUME_STEP_DELAY:-0.5}
SEED_FILE=${CODEX_RESUME_SEED_FILE:-"$ROOT/.local/codex-resume-scroll-test/latest/seeded"}

send_text()
{
	"$NEWMUX" -L "$SOCKET_NAME" send-keys -l -t "$PANE" "$1"
}

send_enter()
{
	"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$PANE" Enter
}

wait_for_shell()
{
	i=1
	while [ "$i" -le 80 ]; do
		if "$NEWMUX" -L "$SOCKET_NAME" display-message -p -t "$TARGET" \
		    '#{pane_id}' >/dev/null 2>&1; then
			return
		fi
		sleep 0.1
		i=$((i + 1))
	done
	echo "target pane is not ready: $TARGET" >&2
	exit 1
}

wait_for_shell
PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p -t "$TARGET" '#{pane_id}')

sleep "$START_DELAY"
send_text "codex"
sleep "$STEP_DELAY"
send_enter
sleep "$STEP_DELAY"
send_text "/resume"
sleep "$STEP_DELAY"
send_enter
sleep "$STEP_DELAY"
send_enter
sleep "$STEP_DELAY"

mkdir -p "$(dirname "$SEED_FILE")"
: > "$SEED_FILE"
"$NEWMUX" -L "$SOCKET_NAME" wait-for -S codex-resume-seeded
