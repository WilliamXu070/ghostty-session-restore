## Symptom

`Command + Shift + T` sometimes leaks a literal capital `M` into the shell.

## Expected behavior

The shortcut should trigger Newmux restore as soon as the key-down event is handled. It should never send printable fallback text into the pane.

## Diagnosis

The old Ghostty binding sent `Ctrl-B` followed by `M` (`text:\x02M`). If the two-byte prefix sequence was delivered at the wrong moment, the printable `M` could reach the shell. Ghostty's macOS surface handles key equivalents on `.keyDown`, so the timing path is already key-down; the fragile part was the printable trailing byte.

The first private sequence attempt used `ESC [99;7788u`. That looked valid in config and appeared in `list-keys`, but it failed in a real attached client because tmux checks CSI-u extended keys before the user-key tree. The sequence was consumed as an extended-key candidate path and never reached `User0`.

## Plan

- Replace the `Ctrl-B M` binding with a private tmux `User0` escape sequence that does not collide with tmux's extended-key parser.
- Bind `User0` in Newmux's root key table to the restore router.
- Keep prefix `M` only as a manual fallback, not as the Ghostty shortcut path.
- Add tests that assert Ghostty emits the private sequence, Newmux binds `User0`, and a real attached PTY client restores a soft-deleted pane when those bytes are received.

## Verification

- `./testing/test-ghostty-config.sh`
- `./testing/test-newmux.sh`
- `xcodebuild test -project ghostty-src/macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/MenuShortcutManagerTests -quiet`

## Status

Fixed locally. GitHub issue creation was blocked because `gh` is not authenticated.

Implemented:

- `Command + Shift + T` now sends `text:\x1b[5;7788~`.
- Newmux maps that private sequence through `user-keys[0]` to `User0`.
- `User0` is bound in the root table to `request-newmux-restore-tab.sh`.
- The old `text:\x02M` route is explicitly rejected by `test-ghostty-config.sh`.
- `test-newmux.sh` now opens a real attached client through a PTY, writes the exact restore sequence, and verifies the soft-deleted pane returns.

Verified:

- `./testing/test-ghostty-config.sh`
- `./testing/test-newmux.sh`
- Live Ghostty after config reload: `Cmd+Shift+T` popped the top item from the `newmux-dev` recovery stack.

Remaining caveat:

- Existing Ghostty windows need a config reload or restart before they use the new sequence.
