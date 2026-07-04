## Symptom

Restored tabs/windows can return at the end of the window list instead of the position they occupied before deletion.

## Expected behavior

Restored windows should go back to their original index. If another window now occupies that index, existing windows should shift right so the restored window still returns to its original place and order.

## Diagnosis

`newmux_restore_live_window` first tries to attach the live window at `item->window_index`, but if that index is occupied it falls back to `-1`, which appends to the end. That fallback causes the user-visible ordering bug.

## Plan

- Add a helper that attaches at the original index.
- If the index is occupied, use tmux's existing `winlink_shuffle_up` behavior to make room.
- Verify with a test that deletes a middle window, creates a replacement at that index, restores, and checks the restored window is back at the original index.

## Verification

- `./testing/test-newmux.sh`

## Status

Fixed locally. GitHub issue creation was blocked because `gh` is not authenticated.

Implemented:

- Window restore now shuffles existing winlinks upward when the original index is occupied.
- The restored live window attaches at its original index instead of falling back to append-at-end.

Verified:

- `./testing/test-newmux.sh` now deletes a middle window, creates an index conflict, restores, and asserts `0:left,1:middle,2:replacement,3:right`.
