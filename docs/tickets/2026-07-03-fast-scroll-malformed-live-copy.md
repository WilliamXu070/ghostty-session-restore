## Symptom

Fast physical scroll-up in Ghostty/Newmux can leave the visible terminal structure malformed: repeated prompt fragments, large blank gaps, or shell-looking pauses while live copy-mode is active.

## Expected behavior

Rapid wheel/trackpad input should either use the live-scroll fast path cleanly or fall back to a full redraw. It should not apply incremental scroll writes on top of stale or partially flushed pane output.

## Diagnosis

The Newmux scroll path is:

`Ghostty scrollCallback -> private Newmux scroll packet + wheel events -> tmux tty-keys metadata -> window_copy_fast_live_scroll -> incremental copy-mode screen writes`.

Backend scroll command cost is not the likely issue. The correctness hazard is the incremental fast path running while the pane already has queued terminal output or a pending full-pane redraw. In that state, applying delete/insert-line scroll deltas can compose against an old screen image and produce visually malformed structure under burst input.

The pasted `ls'` plus `∙` is also zsh secondary-prompt state from an unmatched quote. The remaining bug to protect against is accidental visible corruption or input forwarding while fast scroll is active.

## Plan

1. Guard `window_copy_fast_live_scroll` so it only runs on a clean drawable pane/client.
2. If a full redraw is pending or the client tty output queue is non-empty, fall back to the normal tmux path.
3. Keep existing scroll pacing and live-copy behavior otherwise unchanged.
4. Verify with `scripts/test-newmux.sh` and a headed fast-scroll probe.

## Smoothness follow-up

The first smooth-scroll version still felt choppy because it accepted
high-resolution input but could emit too many lines per frame immediately. The
refactor now:

- resets wheel state through one helper
- tracks consecutive wheel emits
- starts at one-line scroll frames
- ramps to 2, then 4, then 8 lines per frame
- lowers sustained per-second and per-tick caps
- limits selection-active wheel frames to one line

## Verification

- `./scripts/build-newmux.sh` passed.
- `./scripts/test-newmux.sh` passed.
- Headed Ghostty fixture launched with `NEWMUX_USE_PATCHED_GHOSTTY=1 ./scripts/open-live-scroll-test-ghostty.sh`.
- Fast physical scroll probe ran against the real Ghostty window:
  `135` scroll events in `1.077s` through `scripts/probe-active-scroll-ui.py`.
- Backend state stayed valid after the probe:
  `mode=1 history=1059 scroll=0`.
- After the ramp refactor, `./scripts/build-newmux.sh` and
  `./scripts/test-newmux.sh` passed again. Synthetic Quartz scroll events did
  not move the headed fixture reliably enough to use as visual proof.

## Status

Fixed with conservative fast-path guard. Keep open only if the exact manual
trackpad repro still shows malformed visible structure.
