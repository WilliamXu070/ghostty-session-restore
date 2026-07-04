## Symptom

Need to verify whether restoring several recently closed native Ghostty/Newmux tabs remains correct and responsive. The user-reported repro is: open five tabs, put `hello<Enter>`, `bye`, `truth`, `codex<Enter>`, and `sudo` into them, delete them in the original open order using tab navigation, then recover all five.

## Expected behavior

All five tabs should be recoverable. Recovery should be LIFO: `sudo`, `codex`, `truth`, `bye`, `hello`. Each restored tab should show the correct prior state and should not attach to a stale or wrong Newmux window. Restore timing should be recorded so slow routing/rendering can be diagnosed.

## Diagnosis

Current confirmed architecture: `newmux-reopen-latest-closed -P` pops one item and prints its restored `window_id`; `request-newmux-restore-tab.sh` writes that exact id into a short-lived payload; `start-newmux-fresh.sh` claims the payload and attaches the new native tab to that window. Existing coverage proves three deleted windows restore LIFO by id. Missing coverage: a real five native-tab UI workflow, deletion in original open order via tab switching, mixed submitted and unsubmitted command text, screenshots, and per-restore timing.

Hypothesis to test: if unsubmitted prompt text is classified as an empty/fresh terminal, the `bye`, `truth`, and `sudo` tabs may be discarded rather than added to the recovery stack. That would be a recovery eligibility bug, not a slow-rendering bug.

## Plan

1. Add a golden UI regression for the exact five-tab workflow.
2. Drive real Ghostty shortcuts for tab creation, typing, Control+Tab navigation, Command+W deletion, and Command+Shift+T recovery.
3. Assert recovery stack count, restored order, restored content, native-tab/window identity, and per-restore latency.
4. Capture screenshots and pane logs after setup, delete, and every restore.
5. Register the regression in `scripts/regression-manifest.tsv`.
6. Run the new test plus the existing recovery regression suite.
7. If the exact workflow fails, separate content/recovery eligibility failure from latency/rendering failure before changing product code.

## Verification

Pending.

## Status

Open.
