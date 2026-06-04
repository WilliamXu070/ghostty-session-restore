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
fi
