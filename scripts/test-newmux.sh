#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
NEWMUX="$ROOT/bin/newmux"
CONF="$ROOT/config/newmux-dev.tmux.conf"
SOCKET_NAME="newmux-test-$$"

if [ ! -x "$NEWMUX" ]; then
	"$ROOT/scripts/build-newmux.sh"
fi

cleanup()
{
	"$NEWMUX" -L "$SOCKET_NAME" kill-server >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

VERSION=$("$NEWMUX" -V)
case "$VERSION" in
	*"newmux-dev"*) ;;
	*)
		echo "unexpected version: $VERSION" >&2
		exit 1
		;;
esac

"$NEWMUX" -L "$SOCKET_NAME" -f "$CONF" new-session -d -s smoke -n main \
	'sleep 10'

SERVER_VERSION=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p '#{version}')
case "$SERVER_VERSION" in
	*"newmux-dev"*) ;;
	*)
		echo "server did not report newmux version: $SERVER_VERSION" >&2
		exit 1
		;;
esac

STATUS_LEFT=$("$NEWMUX" -L "$SOCKET_NAME" show-options -gqv status-left)
case "$STATUS_LEFT" in
	*"newmux"*) ;;
	*)
		echo "dev config did not load status-left: $STATUS_LEFT" >&2
		exit 1
		;;
esac

COPY_COMMAND=$("$NEWMUX" -L "$SOCKET_NAME" show-options -sqv copy-command)
case "$COPY_COMMAND" in
	*"newmux-copy-to-clipboard.sh"*) ;;
	*)
		echo "copy-command should use newmux copy filter: $COPY_COMMAND" >&2
		exit 1
		;;
esac

FILTERED_COPY=$(printf 'left            right\nkeep two  spaces\n' |
	NEWMUX_COPY_TO_STDOUT=1 "$ROOT/scripts/newmux-copy-to-clipboard.sh")
case "$FILTERED_COPY" in
	*"left
right
keep two  spaces"*) ;;
	*)
		echo "copy filter did not normalize large visual gaps" >&2
		printf '%s\n' "$FILTERED_COPY" >&2
		exit 1
		;;
esac

SCROLL_MODE=$("$NEWMUX" -L "$SOCKET_NAME" show-options -gwqv \
	newmux-scroll-mode)
case "$SCROLL_MODE" in
	1|2) ;;
	*)
		echo "newmux scroll mode should be 1 or 2: $SCROLL_MODE" >&2
		exit 1
		;;
esac

SCROLL_MAX_UP=$("$NEWMUX" -L "$SOCKET_NAME" show-options -gwqv \
	newmux-scroll-single-line-max-up)
SCROLL_MAX_DOWN=$("$NEWMUX" -L "$SOCKET_NAME" show-options -gwqv \
	newmux-scroll-single-line-max-down)
if [ "$SCROLL_MAX_UP" -lt 1 ] || [ "$SCROLL_MAX_UP" -gt 2000 ] ||
    [ "$SCROLL_MAX_DOWN" -lt 1 ] || [ "$SCROLL_MAX_DOWN" -gt 2000 ]; then
	echo "unexpected single-line scroll caps: up=$SCROLL_MAX_UP down=$SCROLL_MAX_DOWN" >&2
	exit 1
fi

RESTORE_BIND=$("$NEWMUX" -L "$SOCKET_NAME" list-keys -T prefix | grep 'prefix T ')
case "$RESTORE_BIND" in
	*"newmux-reopen-latest-closed"*) ;;
	*)
		echo "restore binding missing: $RESTORE_BIND" >&2
		exit 1
		;;
esac

COPY_MODE_BIND=$("$NEWMUX" -L "$SOCKET_NAME" list-keys -T prefix | grep 'prefix H ')
case "$COPY_MODE_BIND" in
	*"copy-mode -HLe"*|*"copy-mode -LHe"*) ;;
	*)
		echo "copy-mode binding missing: $COPY_MODE_BIND" >&2
		exit 1
		;;
esac

CLIPBOARD_COPY_BIND=$("$NEWMUX" -L "$SOCKET_NAME" list-keys -T copy-mode |
	grep 'MouseDragEnd1Pane')
case "$CLIPBOARD_COPY_BIND" in
	*"copy-pipe-no-clear"*"newmux-copy-to-clipboard.sh"*"cancel"*) ;;
	*"copy-pipe-no-clear"*"newmux-copy-to-clipboard.sh"*) ;;
	*)
		echo "mouse clipboard binding missing: $CLIPBOARD_COPY_BIND" >&2
		exit 1
		;;
esac

WHEEL_BIND=$("$NEWMUX" -L "$SOCKET_NAME" list-keys -T root | grep 'WheelUpPane')
case "$WHEEL_BIND" in
	*"#{>:#{history_size},0}"*"copy-mode -HLe"*|*"#{>:#{history_size},0}"*"copy-mode -LHe"*) ;;
	*)
		echo "wheel binding does not guard empty history: $WHEEL_BIND" >&2
		exit 1
		;;
esac
case "$WHEEL_BIND" in
	*"mouse_any_flag"*|*"alternate_on"*)
		echo "wheel binding still forwards upward scroll to apps: $WHEEL_BIND" >&2
		exit 1
		;;
esac

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n no-history \
	'sh -c "printf no-history; sleep 2"'
sleep 0.2
NO_HISTORY_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:no-history '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -L -t "$NO_HISTORY_PANE"
NO_HISTORY_CURSOR_BEFORE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$NO_HISTORY_PANE" '#{copy_cursor_y}')
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$NO_HISTORY_PANE" -X scroll-up
NO_HISTORY_SCROLL_AFTER=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$NO_HISTORY_PANE" '#{scroll_position}')
NO_HISTORY_CURSOR_AFTER=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$NO_HISTORY_PANE" '#{copy_cursor_y}')
if [ "$NO_HISTORY_SCROLL_AFTER" != 0 ] ||
    [ "$NO_HISTORY_CURSOR_AFTER" != "$NO_HISTORY_CURSOR_BEFORE" ]; then
	echo "live copy-mode moved on empty history scroll" >&2
	echo "scroll=$NO_HISTORY_SCROLL_AFTER before=$NO_HISTORY_CURSOR_BEFORE after=$NO_HISTORY_CURSOR_AFTER" >&2
	exit 1
fi

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live \
	'sh -c "printf \"before-live\\n\"; sleep 0.2; printf \"after-live\\n\"; sleep 2"'
sleep 0.1
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -L -t smoke:live
sleep 0.5
LIVE_CAPTURE=$("$NEWMUX" -L "$SOCKET_NAME" capture-pane -p -t smoke:live)
case "$LIVE_CAPTURE" in
	*"after-live"*) ;;
	*)
		echo "live copy-mode did not render new output after entry" >&2
		echo "$LIVE_CAPTURE" >&2
		exit 1
		;;
esac

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live-anim \
	"env NEWMUX='$NEWMUX' SOCKET_NAME='$SOCKET_NAME' sh -c 'i=1; while [ \$i -le 80 ]; do printf \"anim-history-%03d\\n\" \"\$i\"; i=\$((i + 1)); done; printf \"anim-frame-000\\nanim-padding-1\\nanim-padding-2\\nanim-padding-3\\nanim-padding-4\\nanim-padding-5\\nanim-padding-6\\n\"; \"\$NEWMUX\" -L \"\$SOCKET_NAME\" wait-for -S live-anim-ready; \"\$NEWMUX\" -L \"\$SOCKET_NAME\" wait-for live-anim-go; i=1; while [ \$i -le 20 ]; do printf \"\\033[7A\\ranim-frame-%03d\\033[7B\" \"\$i\"; i=\$((i + 1)); sleep 0.03; done; \"\$NEWMUX\" -L \"\$SOCKET_NAME\" wait-for -S live-anim-done; sleep 2'"
"$NEWMUX" -L "$SOCKET_NAME" wait-for live-anim-ready
LIVE_ANIM_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:live-anim '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -LH -t "$LIVE_ANIM_PANE"
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_ANIM_PANE" -N 3 \
	-X scroll-up
"$NEWMUX" -L "$SOCKET_NAME" wait-for -S live-anim-go
"$NEWMUX" -L "$SOCKET_NAME" wait-for live-anim-done
LIVE_ANIM_CAPTURE=$("$NEWMUX" -L "$SOCKET_NAME" capture-pane -p \
	-t "$LIVE_ANIM_PANE")
case "$LIVE_ANIM_CAPTURE" in
	*"anim-frame-020"*) ;;
	*)
		echo "live copy-mode did not refresh visible in-place animation" >&2
		echo "$LIVE_ANIM_CAPTURE" >&2
		exit 1
		;;
esac

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live-resize \
	'sh -c "awk '\''BEGIN { for (i = 1; i <= 80; i++) printf \"resize-line-%03d\\n\", i }'\''; sleep 2"'
sleep 0.5
LIVE_RESIZE_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:live-resize '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -L -t "$LIVE_RESIZE_PANE"
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_RESIZE_PANE" -X page-up
RESIZE_SCROLL_BEFORE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_RESIZE_PANE" '#{scroll_position}')
case "$RESIZE_SCROLL_BEFORE" in
	0|"")
		echo "live copy-mode did not scroll before resize" >&2
		exit 1
		;;
esac
"$NEWMUX" -L "$SOCKET_NAME" resize-window -t smoke:live-resize -x 100 -y 30
RESIZE_SCROLL_AFTER=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_RESIZE_PANE" '#{scroll_position}')
case "$RESIZE_SCROLL_AFTER" in
	0|"")
		echo "live copy-mode lost scroll position after resize" >&2
		exit 1
		;;
esac

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live-append \
	"env NEWMUX='$NEWMUX' SOCKET_NAME='$SOCKET_NAME' sh -c 'i=1; while [ \$i -le 160 ]; do printf \"history-line-%03d\\n\" \"\$i\"; i=\$((i + 1)); done; \"\$NEWMUX\" -L \"\$SOCKET_NAME\" wait-for -S live-append-initial; sleep 0.2; i=1; while [ \$i -le 40 ]; do printf \"append-line-%03d\\n\" \"\$i\"; i=\$((i + 1)); done; \"\$NEWMUX\" -L \"\$SOCKET_NAME\" wait-for -S live-append-done; sleep 2'"
"$NEWMUX" -L "$SOCKET_NAME" wait-for live-append-initial
LIVE_APPEND_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:live-append '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -LH -t "$LIVE_APPEND_PANE"
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_APPEND_PANE" -N 100 \
	-X scroll-up
APPEND_SCROLL_BEFORE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_APPEND_PANE" '#{scroll_position}')
case "$APPEND_SCROLL_BEFORE" in
	0|"")
		echo "live append test did not enter historical viewport" >&2
		exit 1
		;;
esac
"$NEWMUX" -L "$SOCKET_NAME" wait-for live-append-done
APPEND_SCROLL_AFTER=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_APPEND_PANE" '#{scroll_position}')
if [ "$APPEND_SCROLL_AFTER" -le "$APPEND_SCROLL_BEFORE" ]; then
	echo "live append did not preserve historical scroll anchor" >&2
	echo "before=$APPEND_SCROLL_BEFORE after=$APPEND_SCROLL_AFTER" >&2
	exit 1
fi

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live-input \
	'sh -c '"'"'i=1; while [ $i -le 100 ]; do printf "input-history-%03d\n" "$i"; i=$((i + 1)); done; printf "input-ready\n"; while IFS= read -r line; do printf "got:%s\n" "$line"; [ "$line" = typed-while-scrolled ] && break; done; sleep 2'"'"
sleep 0.5
LIVE_INPUT_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:live-input '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -LH -t "$LIVE_INPUT_PANE"
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_INPUT_PANE" -N 20 \
	-X scroll-up
INPUT_SCROLL_BEFORE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_INPUT_PANE" '#{scroll_position}')
case "$INPUT_SCROLL_BEFORE" in
	0|"")
		echo "live input test did not enter historical viewport" >&2
		exit 1
		;;
esac
"$NEWMUX" -L "$SOCKET_NAME" send-keys -l -t "$LIVE_INPUT_PANE" \
	typed-while-scrolled
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_INPUT_PANE" Enter
i=1
while [ "$i" -le 20 ]; do
	LIVE_INPUT_CAPTURE=$("$NEWMUX" -L "$SOCKET_NAME" capture-pane -p \
		-t "$LIVE_INPUT_PANE")
	case "$LIVE_INPUT_CAPTURE" in
		*"got:typed-while-scrolled"*) break ;;
	esac
	sleep 0.1
	i=$((i + 1))
done
LIVE_INPUT_MODE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_INPUT_PANE" '#{pane_in_mode}')
case "$LIVE_INPUT_CAPTURE" in
	*"got:typed-while-scrolled"*) ;;
	*)
		echo "typing in live scrollback did not reach pane" >&2
		echo "$LIVE_INPUT_CAPTURE" >&2
		exit 1
		;;
esac
if [ "$LIVE_INPUT_MODE" != 0 ]; then
	echo "typing in live scrollback did not leave copy mode: $LIVE_INPUT_MODE" >&2
	exit 1
fi

"$NEWMUX" -L "$SOCKET_NAME" new-window -t smoke: -n live-refresh \
	"sh -c 'i=1; while [ \$i -le 140 ]; do printf \"refresh-line-%03d %0200d\\n\" \"\$i\" 0; i=\$((i + 1)); done; sleep 2'"
sleep 0.5
LIVE_REFRESH_PANE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t smoke:live-refresh '#{pane_id}')
"$NEWMUX" -L "$SOCKET_NAME" copy-mode -LH -t "$LIVE_REFRESH_PANE"
"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_REFRESH_PANE" -N 8 \
	-X scroll-up
REFRESH_SCROLL_BEFORE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_REFRESH_PANE" '#{scroll_position}')
case "$REFRESH_SCROLL_BEFORE" in
	0|"")
		echo "live refresh test did not enter historical viewport" >&2
		exit 1
		;;
esac
i=1
while [ "$i" -le 20 ]; do
	"$NEWMUX" -L "$SOCKET_NAME" send-keys -t "$LIVE_REFRESH_PANE" r
	i=$((i + 1))
done
REFRESH_ALIVE=$("$NEWMUX" -L "$SOCKET_NAME" display-message -p \
	-t "$LIVE_REFRESH_PANE" '#{?pane_dead,dead,alive}')
if [ "$REFRESH_ALIVE" != alive ]; then
	echo "live refresh-from-pane killed pane/server" >&2
	exit 1
fi

echo "newmux smoke tests passed"
echo "  binary: $VERSION"
echo "  server: $SERVER_VERSION"
