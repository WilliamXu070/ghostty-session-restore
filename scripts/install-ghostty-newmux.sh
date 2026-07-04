#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CACHE_HOME=${XDG_CACHE_HOME:-"$HOME/.cache"}
SPOTLIGHT_RUNTIME_ROOT=${NEWMUX_SPOTLIGHT_RUNTIME_ROOT:-"$CACHE_HOME/newmux/spotlight-runtime"}
GHOSTTY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty"
GHOSTTY_CONFIG="$GHOSTTY_DIR/config"
INCLUDE_LINE="config-file = $SPOTLIGHT_RUNTIME_ROOT/ghostty-config/newmux.config"
SOURCE_INCLUDE_LINE="config-file = $ROOT/ghostty-config/newmux.config"
OLD_INCLUDE_LINE="config-file = $ROOT/ghostty/newmux.config"

mkdir -p "$GHOSTTY_DIR"
touch "$GHOSTTY_CONFIG"

if grep -Fqx "$INCLUDE_LINE" "$GHOSTTY_CONFIG"; then
	echo "Ghostty config already includes newmux profile:"
	echo "  $INCLUDE_LINE"
	exit 0
fi

cp "$GHOSTTY_CONFIG" "$GHOSTTY_CONFIG.newmux-backup"

if grep -Fqx "$OLD_INCLUDE_LINE" "$GHOSTTY_CONFIG" || \
	grep -Fqx "$SOURCE_INCLUDE_LINE" "$GHOSTTY_CONFIG"; then
	tmp="$GHOSTTY_CONFIG.newmux-tmp"
	awk -v old="$OLD_INCLUDE_LINE" -v source="$SOURCE_INCLUDE_LINE" \
		'$0 != old && $0 != source { print }' "$GHOSTTY_CONFIG" > "$tmp"
	mv "$tmp" "$GHOSTTY_CONFIG"
fi

{
	echo ""
	echo "# newmux development profile"
	echo "$INCLUDE_LINE"
} >> "$GHOSTTY_CONFIG"

echo "Added newmux profile to $GHOSTTY_CONFIG"
echo "Backup written to $GHOSTTY_CONFIG.newmux-backup"
