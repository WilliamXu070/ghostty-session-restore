# Newmux zsh shim.
#
# Source the user's normal interactive config, then enforce a no-right-prompt
# policy. Right prompts are terminal-grid text; after pane resize they can be
# stranded in scrollback at stale columns, so Newmux keeps dev panes left-prompt
# only until it has a richer prompt-aware renderer.

if [[ -o interactive ]]; then
	if [[ -z ${NEWMUX_USER_ZSHRC_SOURCED:-} && \
	    -r "$HOME/.zshrc" && "$HOME/.zshrc" != "$ZDOTDIR/.zshrc" ]]; then
		export NEWMUX_USER_ZSHRC_SOURCED=1
		source "$HOME/.zshrc"
	fi

	newmux_disable_rprompt() {
		unset RPROMPT RPS1
		typeset -g RPROMPT=
		typeset -g RPS1=
		typeset -g ZLE_RPROMPT_INDENT=0
	}

	newmux_disable_rprompt
	autoload -Uz add-zsh-hook
	add-zsh-hook precmd newmux_disable_rprompt

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
