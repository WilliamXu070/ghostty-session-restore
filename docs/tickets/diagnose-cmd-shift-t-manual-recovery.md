## Symptom

Manual Ghostty `Command+Shift+T` was reported not to execute recovery,
especially after repeating input/output and recovery a second time.

## Expected behavior

With a recoverable deleted Newmux tab/window on the stack:

- Real Ghostty `Command+T` creates a fresh tab/window.
- Real Ghostty `Command+W` soft-deletes a non-empty tab/window.
- Real Ghostty `Command+Shift+T` restores that deleted tab/window.
- Repeating the input/delete/restore cycle should keep the original live
  window and pane identities.

## Diagnosis

Confirmed:

- The normal Ghostty config includes `ghostty-config/newmux.config`.
- The Newmux Ghostty profile binds `cmd+shift+t` to the private User0 escape.
- The Newmux tmux config binds User0 to `scripts/request-newmux-restore-tab.sh`.
- The request script must use the tmux socket path argument when
  `NEWMUX_SOCKET_PATH` is not exported; this was fixed.
- A deleted tab with only one or two visible lines can still be classified as
  fresh/empty by `newmux_window_looks_fresh`, so it is intentionally not added
  to the recovery stack.

Verified:

- A default `newmux-dev` socket workflow with real foreground Apple keyboard
  `Command+T`, `Command+W`, and `Command+Shift+T` restores successfully.
- The same default workflow succeeds twice in a row when the deleted tab has
  enough real output to avoid the empty/fresh heuristic.

## Plan

- Keep `testing/test-newmux-sanity-default-cmd-shift-t-recovery.sh` as the
  manual-parity regression for default socket recovery.
- Use enough output before delete in recovery tests so the deleted tab is not
  intentionally ignored as empty.
- If manual failure persists, compare the user-visible tab with the evidence
  snapshots to determine whether the deleted tab entered the recovery stack.

## Verification

Ran:

```sh
NEWMUX_GOLDEN_KEEP_OPEN=0 testing/test-newmux-sanity-default-cmd-shift-t-recovery.sh
```

Result:

```text
newmux sanity default real Cmd+Shift+T recovery test passed
window_id=@1
pane_id=%1
cycles=2
```

## Status

Current automated manual-parity repro passes. Remaining likely manual mismatch:
the deleted target may be classified as fresh/empty and therefore never enters
the recovery stack.
