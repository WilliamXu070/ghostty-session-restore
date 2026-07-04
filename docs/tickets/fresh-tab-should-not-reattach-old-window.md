## Symptom

Sometimes pressing `Cmd+T` opens a previously closed/deleted-looking terminal instead of a fresh terminal.

## Expected behavior

`Cmd+T` should always create a brand-new Newmux window and attach the new native Ghostty tab to it. Only `Cmd+Shift+T` should restore or reattach a previously soft-deleted window.

## Diagnosis

`scripts/start-newmux-fresh.sh` runs for every native Ghostty tab. In the active-client path it calls `find_unrepresented_window` before creating a new window. That helper looks for any Newmux window in the primary session that is not currently represented by an attached native tab client. This can include windows left behind by closed native tabs or stale tab sessions, so normal `Cmd+T` can attach one of those old windows instead of creating a fresh one.

The current runtime state showed multiple Newmux windows and stale/unattached `newmux-tab-*` sessions, which is exactly the state where this bug becomes visible.

GitHub CLI is unavailable because `gh` is not authenticated, so this local ticket is standing in for the GitHub issue until auth is available.

## Plan

1. Split normal tab creation from restore attachment in `scripts/start-newmux-fresh.sh`.
2. In the active-client path, only attach an existing/restored window when an explicit restore marker exists.
3. Make normal `Cmd+T` create a fresh `new-window` immediately.
4. Keep the no-client attach path for first attach/reconnect behavior, where there is no active native tab context.
5. Add a regression that seeds an unrepresented old window, runs the starter as if a new native tab was opened, and verifies it creates/attaches a fresh window instead of the old one.
6. Run config, Newmux, and bridge tests.

## Verification

- Ran `./testing/test-newmux-start-router.sh`; it seeds an old unrepresented window, simulates the active-client Newmux starter path, and verifies the routed window is fresh rather than the old one.
- Ran `./testing/test-ghostty-config.sh`.
- Ran `./testing/test-newmux-ui-bridge.sh`.
- Ran `./testing/test-newmux.sh`.
- Ran a live Ghostty path check:
  - Started a clean Newmux/Ghostty dev session.
  - Seeded old unrepresented window `@1`.
  - Pressed `Cmd+T`.
  - Verified the newest native tab client attached to fresh window `@2`, not old `@1`.

## Status

Fixed locally. GitHub issue creation is still blocked because `gh` is not authenticated.
