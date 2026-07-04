#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
SOCKET_NAME=${NEWMUX_SOCKET:-newmux-codex-resume-test}
TARGET=${1:-newmux-codex-resume:main}
SCROLL_LINES=${SCROLL_LINES:-6}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-45}
CAPTURE_FILE="${TMPDIR:-/tmp}/newmux-codex-resume-stage-$$.txt"
SEED_FILE=${CODEX_RESUME_SEED_FILE:-"$ROOT/.local/codex-resume-scroll-test/latest/seeded"}

wait_for_codex_resume()
{
	i=0
	limit=$((TIMEOUT_SECONDS * 2))
	while [ "$i" -lt "$limit" ]; do
		if [ -f "$SEED_FILE" ]; then
			return
		fi
		sleep 0.5
		i=$((i + 1))
	done

	echo "Codex /resume keystroke seed did not finish within ${TIMEOUT_SECONDS}s" >&2
	exit 1
}

stage_scroll()
{
	"$NEWMUX" -L "$SOCKET_NAME" copy-mode -LH -t "$TARGET"
	i=0
	while [ "$i" -lt 20 ]; do
		mode=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
			-t "$TARGET" '#{pane_in_mode}')
		if [ "$mode" = 1 ]; then
			break
		fi
		sleep 0.05
		i=$((i + 1))
	done
	"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$TARGET" -X history-bottom
	"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$TARGET" -N "$SCROLL_LINES" \
		-X scroll-up
}

wait_for_codex_resume
stage_scroll

i=0
while [ "$i" -lt 10 ]; do
	mode=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p -t "$TARGET" \
		'#{pane_in_mode}')
	scroll=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p -t "$TARGET" \
		'#{scroll_position}')
	if [ "$mode" = 1 ] && [ "$scroll" = "$SCROLL_LINES" ]; then
		"$NEWMUX" -L "$SOCKET_NAME" capture-pane -p -t "$TARGET" \
			>"$CAPTURE_FILE"
		line=$(grep -E 'OpenAI Codex|/resume|Resume|codex' \
			"$CAPTURE_FILE" | tail -1 || true)
		"$NEWMUX" -L "$SOCKET_NAME" display-message -t "$TARGET" \
			"codex resume scroll test ready: scroll=$scroll"
		echo "codex resume scroll test ready"
		echo "  socket=$SOCKET_NAME target=$TARGET scroll=$scroll mode=$mode"
		echo "  marker=${line:-none}"
		rm -f "$CAPTURE_FILE"
		exit 0
	fi
	stage_scroll
	sleep 0.2
	i=$((i + 1))
done

echo "failed to stage Codex resume scroll test" >&2
echo "  mode=$mode scroll=$scroll expected_scroll=$SCROLL_LINES" >&2
exit 1
