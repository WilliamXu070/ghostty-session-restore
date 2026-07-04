## Symptom

`Cmd+Shift+T` restore can visibly show shell startup noise such as `Last login`
before the recovered Newmux screen appears and becomes typeable.

## Expected behavior

Recovery should show the restored terminal state directly, with no login-shell
banner, and timing should be measured by user-visible readiness, not only backend
window counts.

## Diagnosis

The current lifecycle benchmark stops when backend/UI tab counts change, so it
misses the real visual gap. A controlled launch without
`NEWMUX_GHOSTTY_SKIP_LOGIN` shows the Newmux client parent as `/usr/bin/login`,
even for `command = direct:.../scripts/start-newmux-fresh.sh`. This matches the
reported `Last login` flash and can occur when Ghostty is launched outside the
script-provided environment, such as Spotlight.

## Plan

- Make Ghostty skip the Darwin login wrapper for this repo's Newmux direct
  command path based on command identity.
- Add a regression that launches without `NEWMUX_GHOSTTY_SKIP_LOGIN` and asserts
  the Newmux client is not parented by `/usr/bin/login`.
- Rebuild Ghostty, refresh `/Applications/Ghostty.app`, and run recovery golden
  flows plus lifecycle timing.

## Verification

- Controlled no-env pre-fix diagnosis showed the Newmux client parent as:
  `/usr/bin/login -flp williamxu .../scripts/start-newmux-fresh.sh`.
- `testing/test-newmux-gf-direct-launch-no-env-login-wrapper.sh` now passes
  without `NEWMUX_GHOSTTY_SKIP_LOGIN`; parent is
  `/Applications/Ghostty.app/Contents/MacOS/ghostty`.
- Spotlight-style `open -na /Applications/Ghostty.app` now starts Newmux with
  Ghostty as direct parent, not `/usr/bin/login`.
- `./scripts/run-correctness-gate.sh` passes.
- Recovery/order flows pass:
  `cmd-w-ui-tab-sync`, `cmd-shift-t-left-tab-position`,
  `cmd-shift-t-restore-local-order-complex`.
- Lifecycle sample:
  `.local/benchmarks/newmux-lifecycle-20260702-224839.json`
  reports restored-tab real UI input p50 around 68 ms and average around 87 ms.

## Status

Fixed locally.
