#!/bin/sh

normalize_layout()
{
	printf '%s\n' "$1" | sed -E \
		-e 's/^[0-9a-f][0-9a-f][0-9a-f][0-9a-f],//' \
		-e 's/,[0-9]+([]},>]?$)/,P\1/g' \
		-e 's/,[0-9]+([]},>])/,P\1/g'
}

setup_golden_run_dir()
{
	test_name=${1:-golden}
	GOLDEN_RUN_DIR=${GOLDEN_RUN_DIR:-"$ROOT/.local/newmux-golden-runs/$test_name-$$"}
	mkdir -p "$GOLDEN_RUN_DIR"
}

newmux_cmd()
{
	if [ -n "${NEWMUX_SOCKET_PATH:-}" ]; then
		"$NEWMUX" -S "$NEWMUX_SOCKET_PATH" "$@"
		return
	fi
	"$NEWMUX" -L "$SOCKET_NAME" "$@"
}

golden_background_input()
{
	[ "${NEWMUX_GOLDEN_BACKGROUND_INPUT:-1}" != 0 ]
}

open_background_ghostty_surface()
{
	window_id=$(NEWMUX_SOCKET="$SOCKET_NAME" \
	NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-}" \
	NEWMUX_STARTER_ASSUME_CLIENTS=1 \
	NEWMUX_STARTER_PRINT_WINDOW=1 \
		"$ROOT/scripts/start-newmux-fresh.sh" 2>/dev/null || true)
	if [ -n "$window_id" ]; then
		session=$(primary_session 2>/dev/null || true)
		if [ -n "$session" ]; then
			newmux_cmd select-window -t "$session:$window_id" \
				>/dev/null 2>&1 || true
		fi
	fi
}

request_background_restore_tab()
{
	recent=$(newmux_cmd newmux-list-recently-closed 2>/dev/null || true)
	[ -n "$recent" ] || return 0
	recent_type=$(printf '%s\n' "$recent" | awk 'NR == 1 { print $2 }')
	NEWMUX_SOCKET="$SOCKET_NAME" \
	NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-}" \
	NEWMUX_RESTORE_OPEN_TAB=0 \
		"$ROOT/scripts/request-newmux-restore-tab.sh" \
		"${NEWMUX_SOCKET_PATH:-}" >/dev/null 2>&1 || true
	if [ "$recent_type" = pane ]; then
		return 0
	fi
	NEWMUX_SOCKET="$SOCKET_NAME" \
	NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-}" \
	NEWMUX_STARTER_ASSUME_CLIENTS=1 \
	NEWMUX_STARTER_PRINT_WINDOW=1 \
		"$ROOT/scripts/start-newmux-fresh.sh" >/dev/null 2>&1 || true
}

wait_for_server()
{
	i=1
	while [ "$i" -le 500 ]; do
		if newmux_cmd display-message -p '#{version}' \
		    >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

active_client_session()
{
	newmux_cmd list-clients -F '#{client_session}' |
		tail -1
}

primary_session()
{
	newmux_cmd list-sessions -F '#{session_name}' |
		awk '$1 == "newmux" { print; found = 1 } END { if (!found) exit 1 }'
}

window_panes()
{
	newmux_cmd display-message -p -t "$1:" \
		'#{window_panes}'
}

window_layout()
{
	newmux_cmd display-message -p -t "$1:" \
		'#{window_layout}'
}

wait_for_panes()
{
	session=$1
	expected=$2
	i=1
	while [ "$i" -le 80 ]; do
		count=$(window_panes "$session")
		if [ "$count" -eq "$expected" ]; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

wait_for_window_count()
{
	session=$1
	expected=$2
	i=1
	while [ "$i" -le 80 ]; do
		count=$(newmux_cmd list-windows -t "$session" \
			-F '#{window_id}' | wc -l | tr -d ' ')
		if [ "$count" -eq "$expected" ]; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

wait_for_at_least_window_count()
{
	session=$1
	expected=$2
	i=1
	while [ "$i" -le 500 ]; do
		count=$(newmux_cmd list-windows -t "$session" \
			-F '#{window_id}' | wc -l | tr -d ' ')
		if [ "$count" -ge "$expected" ]; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

wait_for_recovery_count()
{
	expected=$1
	i=1
	while [ "$i" -le 100 ]; do
		count=$(newmux_cmd newmux-list-recently-closed \
			2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')
		if [ "$count" -eq "$expected" ]; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

current_window_id()
{
	session=$1
	newmux_cmd display-message -p -t "$session:" \
		'#{window_id}'
}

wait_for_no_ghostty()
{
	i=1
	while [ "$i" -le 80 ]; do
		if ! pgrep -f '/Applications/Ghostty.app/Contents/MacOS/ghostty|/newmux/ghostty-macos-build/.*/Ghostty.app/Contents/MacOS/ghostty' \
		    >/dev/null 2>&1; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

wait_for_ghostty_frontmost_window()
{
	i=1
	while [ "$i" -le 20 ]; do
		if osascript \
		    -e 'tell application "Ghostty" to activate' \
		    -e 'tell application "System Events" to tell process "Ghostty" to get frontmost and visible and ((count of windows) > 0)' \
		    2>/dev/null | grep -q true; then
			return 0
		fi
		sleep 0.02
		i=$((i + 1))
	done
	return 1
}

press_key()
{
	key=$1
	mods=$2
	key_code=
	case "$key" in
		d) key_code=2 ;;
		tab) key_code=48 ;;
		t) key_code=17 ;;
		w) key_code=13 ;;
	esac

	if golden_background_input; then
		session=$(active_client_session 2>/dev/null || true)
		case "$key:$mods" in
			t:"command down")
				open_background_ghostty_surface || true
				return 0
				;;
			t:"command down, shift down")
				request_background_restore_tab
				return 0
				;;
			w:"command down")
				if [ -n "$session" ]; then
					newmux_cmd newmux-soft-delete-window -t "$session:" \
						>/dev/null 2>&1 || true
				fi
				return 0
				;;
			w:"command down, option down")
				if [ -n "$session" ]; then
					newmux_cmd newmux-soft-delete-pane -t "$session:" \
						>/dev/null 2>&1 || true
				fi
				return 0
				;;
			d:"command down")
				if [ -n "$session" ]; then
					newmux_cmd split-window -h -c "#{pane_current_path}" \
						-t "$session:" >/dev/null 2>&1 || true
				fi
				return 0
				;;
			d:"command down, shift down")
				if [ -n "$session" ]; then
					newmux_cmd split-window -v -c "#{pane_current_path}" \
						-t "$session:" >/dev/null 2>&1 || true
				fi
				return 0
				;;
		esac
	fi

	if ! wait_for_ghostty_frontmost_window; then
		echo "Ghostty was not ready before shortcut $key using {$mods}" >&2
		return 1
	fi
	if [ -n "$key_code" ]; then
		osascript \
			-e 'tell application "Ghostty" to activate' \
			-e 'tell application "System Events" to tell process "Ghostty" to set frontmost to true' \
			-e 'tell application "System Events" to tell process "Ghostty" to set windowPosition to position of window 1' \
			-e 'tell application "System Events" to tell process "Ghostty" to set windowSize to size of window 1' \
			-e 'tell application "System Events" to click at {item 1 of windowPosition + (item 1 of windowSize div 2), item 2 of windowPosition + (item 2 of windowSize div 2)}' \
			-e "tell application \"System Events\" to key code $key_code using {$mods}"
	else
		osascript \
			-e 'tell application "Ghostty" to activate' \
			-e 'tell application "System Events" to tell process "Ghostty" to set frontmost to true' \
			-e 'tell application "System Events" to tell process "Ghostty" to set windowPosition to position of window 1' \
			-e 'tell application "System Events" to tell process "Ghostty" to set windowSize to size of window 1' \
			-e 'tell application "System Events" to click at {item 1 of windowPosition + (item 1 of windowSize div 2), item 2 of windowPosition + (item 2 of windowSize div 2)}' \
			-e "tell application \"System Events\" to keystroke \"$key\" using {$mods}"
	fi
}

type_terminal_line()
{
	text=$1

	if golden_background_input; then
		session=$(active_client_session 2>/dev/null || true)
		if [ -n "$session" ]; then
			newmux_cmd send-keys -t "$session:" "$text" Enter
		fi
		return 0
	fi

	if ! wait_for_ghostty_frontmost_window; then
		echo "Ghostty was not ready before typing terminal input" >&2
		return 1
	fi
	osascript \
		-e 'tell application "Ghostty" to activate' \
		-e 'tell application "System Events" to tell process "Ghostty" to set frontmost to true' \
		-e "tell application \"System Events\" to keystroke \"$text\"" \
		-e 'tell application "System Events" to key code 36'
}

type_terminal_line_in_pane()
{
	target=$1
	text=$2

	if golden_background_input; then
		newmux_cmd send-keys -t "$target" -l "$text"
		newmux_cmd send-keys -t "$target" Enter
		sleep 0.2
		return 0
	fi

	type_terminal_line "$text"
	sleep 0.2
}

start_golden_ui_session()
{
	log_file=$1

	setup_golden_run_dir "${GOLDEN_TEST_NAME:-golden}"
	osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
	pkill -x ghostty >/dev/null 2>&1 || true
	pkill -x Ghostty >/dev/null 2>&1 || true
	pkill -f '/Applications/Ghostty.app/Contents/MacOS/ghostty' \
		>/dev/null 2>&1 || true
	pkill -f '/newmux/ghostty-macos-build/.*/Ghostty.app/Contents/MacOS/ghostty' \
		>/dev/null 2>&1 || true
	"$ROOT/scripts/start-newmux-fresh.sh" kill-only >/dev/null 2>&1 || true
	if [ -n "${NEWMUX_SOCKET_PATH:-}" ]; then
		rm -f "$NEWMUX_SOCKET_PATH"
	fi
	if ! wait_for_no_ghostty; then
		echo "Ghostty did not exit before UI test launch" >&2
		return 1
	fi

	attempt=1
	while [ "$attempt" -le 2 ]; do
		if golden_background_input; then
			NEWMUX_SOCKET="$SOCKET_NAME" \
			NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-}" \
			NEWMUX_GHOSTTY_BACKGROUND=1 \
			NEWMUX_USE_PATCHED_GHOSTTY="${NEWMUX_USE_PATCHED_GHOSTTY:-1}" \
				"$ROOT/scripts/open-newmux-ghostty.sh" \
				> "$log_file" 2>&1
		else
			NEWMUX_SOCKET="$SOCKET_NAME" \
			NEWMUX_SOCKET_PATH="${NEWMUX_SOCKET_PATH:-}" \
			NEWMUX_USE_PATCHED_GHOSTTY="${NEWMUX_USE_PATCHED_GHOSTTY:-1}" \
				"$ROOT/scripts/open-newmux-ghostty.sh" \
				> "$log_file" 2>&1
		fi
		if wait_for_server; then
			break
		fi
		if [ "$attempt" -eq 2 ]; then
			echo "newmux UI server did not start" >&2
			cat "$log_file" >&2 || true
			return 1
		fi
		stop_golden_ui_session
		attempt=$((attempt + 1))
	done

	if ! golden_background_input && ! wait_for_ghostty_frontmost_window; then
		echo "Ghostty did not become the frontmost window" >&2
		ps -axo pid,command | grep '[G]hostty' >&2 || true
		cat "$log_file" >&2 || true
		return 1
	fi
	return 0
}

stop_golden_ui_session()
{
	osascript -e 'tell application "Ghostty" to quit' >/dev/null 2>&1 || true
	pkill -x ghostty >/dev/null 2>&1 || true
	pkill -x Ghostty >/dev/null 2>&1 || true
	pkill -f '/Applications/Ghostty.app/Contents/MacOS/ghostty' \
		>/dev/null 2>&1 || true
	pkill -f '/newmux/ghostty-macos-build/.*/Ghostty.app/Contents/MacOS/ghostty' \
		>/dev/null 2>&1 || true
	wait_for_no_ghostty >/dev/null 2>&1 || true
}

record_golden_evidence()
{
	label=$1
	file_label=$(printf '%s\n' "$label" | sed 's/[^A-Za-z0-9_.-]/_/g')
	out="$GOLDEN_RUN_DIR/$file_label.log"
	{
		printf 'label=%s\n' "$label"
		printf 'socket=%s\n' "$SOCKET_NAME"
		printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		printf '\n== clients ==\n'
		newmux_cmd list-clients \
			-F '#{client_session} #{client_tty} #{client_pid}' 2>&1 || true
		printf '\n== sessions ==\n'
		newmux_cmd list-sessions \
			-F '#{session_name} attached=#{session_attached} windows=#{session_windows}' 2>&1 || true
		printf '\n== windows ==\n'
		newmux_cmd list-windows -a \
			-F '#{session_name}:#{window_index} #{window_id} #{window_name} panes=#{window_panes} active=#{window_active} layout=#{window_layout}' 2>&1 || true
		printf '\n== panes ==\n'
		newmux_cmd list-panes -a \
			-F '#{session_name}:#{window_index}.#{pane_index} #{pane_id} active=#{pane_active} command=#{pane_current_command} path=#{pane_current_path}' 2>&1 || true
		printf '\n== recently closed ==\n'
		newmux_cmd newmux-list-recently-closed 2>&1 || true
		printf '\n== active pane capture ==\n'
		active_session=$(active_client_session 2>/dev/null || true)
		if [ -n "$active_session" ]; then
			newmux_cmd capture-pane -epS - \
				-t "$active_session:" 2>&1 || true
		fi
	} > "$out"
	if [ "$(uname)" = Darwin ]; then
		screencapture -x "$GOLDEN_RUN_DIR/$file_label.png" >/dev/null 2>&1 || true
	fi
}

require_golden_ui_environment()
{
	if [ "$(uname)" != Darwin ]; then
		echo "newmux golden UI test requires macOS" >&2
		exit 77
	fi
	if [ ! -d /Applications/Ghostty.app ] && [ ! -d "${NEWMUX_GHOSTTY_APP:-}" ]; then
		echo "newmux golden UI test requires Ghostty.app" >&2
		exit 77
	fi
}
