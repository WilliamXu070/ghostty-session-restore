## Symptom

Restoring a soft-deleted Newmux pane/window that is running Codex brings back the live Codex process, but the terminal output and commands visible before launching Codex disappear from scrollback after restore.

## Expected behavior

After `Cmd+W` followed by one `Cmd+Shift+T`, the same live process should be restored and the user should still be able to scroll/capture the pre-Codex command output that was visible before close.

## Diagnosis

The previous preservation path copied `screen.saved_grid` into history. That only covers true alternate-screen applications. Real Codex can be running with `#{alternate_on}=0` while repainting the normal screen. In that state, pre-Codex commands can exist only in the current visible grid, not in `history_size`. When Newmux parks/restores the window or pane, later redraw/resize activity replaces those visible rows, so they are lost unless the current visible grid is snapshotted into history before detach.

GitHub CLI is unavailable because `gh` is not authenticated, so this local ticket is standing in for the GitHub issue until auth is available.

## Plan

1. Add a visible-grid preservation helper in `tmux/commands/cmd-newmux-recovery.c`.
2. Deduplicate by checking whether the current visible grid already exists at the end of history.
3. Call the helper from pane and window soft-delete paths before moving panes/windows into recovery.
4. Add/strengthen a regression that starts a Codex-like normal-screen redraw process, soft-deletes/restores it, and checks pre-Codex visible rows are still in `capture-pane -S -`.
5. Build and run Newmux smoke tests plus the targeted regression.

## Verification

- Built Newmux successfully with `./scripts/build-newmux.sh`.
- Ran `./testing/test-newmux.sh`; the suite passed, including a new normal-screen redraw regression that soft-deletes/restores a live pane after hidden redraw and verifies pre-Codex visible rows remain in `capture-pane -S -`.
- Ran a targeted real-Codex recovery check against `bin/newmux`:
  - `#{alternate_on}` before close was `0`, matching the real Codex normal-screen failure mode.
  - Codex pane PID stayed the same across soft-delete/restore.
  - `history_size` grew from `9` to `33`.
  - The pre-Codex marker remained present after restore.
- The existing `testing/test-newmux-codex-ui-history.sh` did not reach the history assertion because its old `Cmd+W` driving logic no longer matches the current native-tab key routing; this is a separate UI test maintenance issue, not a history-preservation failure.
- Reopened: this was not sufficient. The required acceptance test is the exact user workflow: run `ls` repeatedly, start `codex`, delete through the current close path, restore through the current reopen path, then verify the earlier `ls` output is still accessible after restore.

## Status

Reopened. GitHub issue creation is still blocked because `gh` is not authenticated.
