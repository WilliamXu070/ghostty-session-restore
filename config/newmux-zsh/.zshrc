# Newmux zsh shim.
#
# Keep first prompt fast: do not source the full user ~/.zshrc by default.
# Recreate the pieces Newmux needs with lazy/cached setup so new tabs become
# visually ready before heavier user shell work runs.

if [[ -o interactive ]]; then
	export CONDA_CHANGEPS1=false
	export VIRTUAL_ENV_DISABLE_PROMPT=1
	unset NO_COLOR

	# Keep user's app bins available without running full ~/.zshrc.
	case ":$PATH:" in
		*":$HOME/.opencode/bin:"*) ;;
		*) export PATH="$HOME/.opencode/bin:$PATH" ;;
	esac
	export PATH="$HOME/.local/bin:$PATH"

	newmux_lazy_conda() {
		unset -f conda
		local hook
		if [[ -x /opt/anaconda3/bin/conda ]]; then
			hook="$('/opt/anaconda3/bin/conda' 'shell.zsh' 'hook' 2>/dev/null)"
			if [[ $? -eq 0 && -n "$hook" ]]; then
				eval "$hook"
			elif [[ -f /opt/anaconda3/etc/profile.d/conda.sh ]]; then
				source /opt/anaconda3/etc/profile.d/conda.sh
			else
				export PATH="/opt/anaconda3/bin:$PATH"
			fi
		fi
		conda "$@"
	}
	conda() {
		newmux_lazy_conda "$@"
	}

	if [[ -r "$ZDOTDIR/ls-colors.zsh" ]]; then
		source "$ZDOTDIR/ls-colors.zsh"
	elif command -v vivid >/dev/null 2>&1; then
		LS_COLORS="$(vivid generate lava 2>/dev/null)"
		export LS_COLORS
	fi

	if command -v lsd >/dev/null 2>&1; then
		alias ls='lsd --color always --icon always'
	fi

	newmux_disable_rprompt() {
		unset RPROMPT RPS1
		typeset -g RPROMPT=
		typeset -g RPS1=
		typeset -g ZLE_RPROMPT_INDENT=0
	}

	newmux_starship_precmd() {
		STARSHIP_CMD_STATUS=$?
		STARSHIP_PIPE_STATUS=(${pipestatus[@]})
		STARSHIP_JOBS_COUNT="${#jobstates[*]}"
		if (( ${+STARSHIP_START_TIME} )); then
			if (( ${+EPOCHREALTIME} )); then
				(( STARSHIP_CAPTURED_TIME = int(rint(EPOCHREALTIME * 1000)) ))
			else
				STARSHIP_CAPTURED_TIME="$(starship time 2>/dev/null)"
			fi
			STARSHIP_DURATION=$(( STARSHIP_CAPTURED_TIME - STARSHIP_START_TIME ))
			unset STARSHIP_START_TIME
		else
			unset STARSHIP_DURATION STARSHIP_CMD_STATUS STARSHIP_PIPE_STATUS
		fi
		newmux_disable_rprompt
	}

	newmux_starship_preexec() {
		if (( ${+EPOCHREALTIME} )); then
			(( STARSHIP_START_TIME = int(rint(EPOCHREALTIME * 1000)) ))
		else
			STARSHIP_START_TIME="$(starship time 2>/dev/null)"
		fi
	}

	zmodload zsh/datetime 2>/dev/null || true
	zmodload zsh/mathfunc 2>/dev/null || true
	zmodload zsh/parameter 2>/dev/null || true
	autoload -Uz add-zsh-hook

	export STARSHIP_SHELL="zsh"
	export STARSHIP_SESSION_KEY="${RANDOM}${RANDOM}${RANDOM}${RANDOM}0000000000000000"
	export STARSHIP_SESSION_KEY="${STARSHIP_SESSION_KEY:0:16}"
	setopt promptsubst
	PROMPT='$(starship prompt --terminal-width="$COLUMNS" --keymap="${KEYMAP:-}" --status="${STARSHIP_CMD_STATUS:-}" --pipestatus="${STARSHIP_PIPE_STATUS[*]:-}" --cmd-duration="${STARSHIP_DURATION:-}" --jobs="$STARSHIP_JOBS_COUNT")'
	PROMPT2="$(starship prompt --continuation 2>/dev/null)"

	newmux_disable_rprompt
	add-zsh-hook precmd newmux_starship_precmd
	add-zsh-hook preexec newmux_starship_preexec

	if [[ -n ${NEWMUX_SOURCE_USER_ZSHRC:-} && \
	    -z ${NEWMUX_USER_ZSHRC_SOURCED:-} && \
	    -r "$HOME/.zshrc" && "$HOME/.zshrc" != "$ZDOTDIR/.zshrc" ]]; then
		export NEWMUX_USER_ZSHRC_SOURCED=1
		source "$HOME/.zshrc"
		newmux_disable_rprompt
	fi

	newmux_mark_command_entered() {
		[[ -n ${TMUX_PANE:-} ]] || return 0
		local socket_path=""
		if [[ -n ${TMUX:-} ]]; then
			socket_path="${TMUX%%,*}"
		fi
		command python3 /Users/williamxu/Desktop/Projects/newmux/scripts/newmux-runtime.py command \
			--socket-path "$socket_path" \
			--pane "$TMUX_PANE" \
			--shell-command "$1" >/dev/null 2>&1 &!
	}
	add-zsh-hook preexec newmux_mark_command_entered
fi
