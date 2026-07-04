## Symptom

`Command + Shift + T` can restore more than one recently deleted Newmux tab/window from a single user action. In the Ghostty native-tab path it can also create multiple attached copies that point at the same restored terminal.

## Expected Behavior

One shortcut request should consume at most one recoverable item. If there is no recoverable item, the shortcut should do nothing. Extra Ghostty startup surfaces from the same restore request must not pop additional recovery items or create fresh tabs.

## Diagnosis

The tmux-side `newmux-reopen-latest-closed` command already pops exactly one item from the in-memory recovery stack. The failure is in the Ghostty/Newmux routing bridge:

- `request-newmux-restore-tab.sh` writes a shared restore marker and asks Ghostty to open a native tab.
- Every new Ghostty tab runs `start-newmux-fresh.sh`.
- `start-newmux-fresh.sh` checked and removed the marker with normal file operations, not an atomic claim.

When two startup routers observed the marker at nearly the same time, both ran `newmux-reopen-latest-closed`. A headless race reproduction with two deleted windows showed `before=2 after=0`, proving one restore marker drained two recovery items.

## Plan

1. Add an atomic per-marker claim in `start-newmux-fresh.sh`.
2. Add a short completed-request marker so duplicate startup routers from the same native-tab request exit instead of creating fresh tabs after the real restore is already claimed.
3. Make `request-newmux-restore-tab.sh` create the restore marker with no-clobber semantics and skip duplicate pending requests.
4. Add a small per-socket helper debounce so duplicate shortcut helper invocations cannot direct-pop multiple panes.
5. Add a regression test that launches two startup routers concurrently against one marker and asserts exactly one deleted window is restored.
6. Run the targeted router test plus broader Newmux/Ghostty config tests.

## Verification

- Reproduced the pre-fix race with two deleted windows and two concurrent startup routers: `before=2 after=0`.
- Added `testing/test-newmux-start-router.sh` coverage for the same race; it now requires `after=1` and exactly one attached restored native tab.
- Reran the same one-off race after the fix: `before=2 after=1 out1= out2=@2 windows=base,delete-b`.
- Ran `./testing/test-newmux-start-router.sh`: passed.
- Ran `./testing/test-ghostty-config.sh`: passed.
- Ran `./testing/test-newmux.sh`: passed.
- Ran `NEWMUX_UI_TEST_BACKGROUND=1 NEWMUX_GHOSTTY_BACKGROUND=1 ./testing/test-newmux-pane-shortcuts-ui.sh`: passed.
- Ran one real Ghostty shortcut pass with actual `Command + Shift + T` after clicking the terminal body to avoid the native tab bar taking focus: `exact_ui_before=2 exact_ui_after=1 windows=zsh,zsh,zsh,exact-restore-f`.

## Status

Fixed locally. GitHub issue creation was blocked because `gh` is installed but not authenticated.
