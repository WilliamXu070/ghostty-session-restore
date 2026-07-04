## Symptom

After deleting a left/middle Newmux tab and restoring with `Cmd+Shift+T`, the backend Newmux window returns to the correct left/right order, but Ghostty's native tab appears on the wrong side.

## Expected behavior

The restored native Ghostty tab should appear at the same visible position as the restored Newmux window.

## Diagnosis

Newmux stores `original_index`, `left_neighbor`, and `right_neighbor`, and backend restore re-links the window in the correct order. The failure is the native Ghostty tab layer: restore opens a new Ghostty tab with AppleScript, which inserts according to Ghostty/macOS policy, then attaches that tab to the restored backend window without moving the native tab.

## Plan

1. Keep backend Newmux restore order as source of truth.
2. Compute the restored window's sorted position in the primary Newmux session.
3. After opening the native Ghostty tab, move the selected Ghostty tab left/right through Ghostty's native `move_tab` action until its visible index matches Newmux.
4. Expose ordered native Ghostty tab IDs/titles in UI status.
5. Update the left-position flow to use real native Ghostty tabs, not the synthetic no-open path.

## Verification

- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-left-tab-position.json`
  - proves backend order restores to `left,right`
  - proves the surviving right native tab ID moves from index 0 after delete to index 1 after restore
  - proves the restored tab is active at native index 0
- `python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-w-ui-tab-sync.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-restore-runtime-lifo.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-restore-local-order-complex.json`
- `./scripts/test-newmux.sh`
- `./scripts/test-ghostty-config.sh`
- `NEWMUX_USE_PATCHED_GHOSTTY=1 ./scripts/test-ghostty-config.sh`

## Status

Fixed and verified locally.
