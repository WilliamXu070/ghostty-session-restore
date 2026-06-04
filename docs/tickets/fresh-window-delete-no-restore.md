## Symptom

Closing a brand-new/fresh terminal page can add it to the recovery stack, so `Command + Shift + T` later restores an empty terminal.

## Expected behavior

Deleting a fresh untouched page should close it normally and should not add it to the recovery stack. A later restore should do nothing if there are no meaningful deleted items.

## Diagnosis

`newmux-soft-delete-window` currently pushes every non-last window into the live recovery stack, even when the pane has no scrollback and only prompt-level visible content.

## Plan

- Add a conservative freshness check for single-pane windows.
- Treat windows with no history, no alternate screen, no modes, and only prompt-level visible lines as fresh.
- Close fresh windows normally without pushing a recovery item.
- Verify that restoring after closing a fresh window is a no-op, while non-fresh windows remain recoverable.

## Verification

- `./testing/test-newmux.sh`

## Status

Fixed locally. GitHub issue creation was blocked because `gh` is not authenticated.

Implemented:

- Fresh windows are detected conservatively: single pane, default shell spawn, shell current command, no scrollback, no alternate screen, no tmux mode, and only prompt-level visible content.
- Fresh windows close normally with `server_kill_window` and are not pushed to `newmux_closed_stack`.

Verified:

- `./testing/test-newmux.sh` now closes a fresh default-shell window, confirms `newmux-list-recently-closed` is empty, and confirms restore after that is a no-op.
