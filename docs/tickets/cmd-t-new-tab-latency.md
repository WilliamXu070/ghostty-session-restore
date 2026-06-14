## Symptom

`Cmd+T` creates a fresh Newmux window/tab, but the user-visible new tab feels extremely slow.

## Expected behavior

Pressing `Cmd+T` should create a fresh Newmux window tied to the base server and attach a new Ghostty tab quickly.

## Diagnosis

The Newmux-side work is not the bottleneck: headless `request-newmux-new-tab.sh` took about 0.14s, and startup marker claim took about 0.16s. The slow path is the script's AppleScript tab-open step, specifically targeting `new tab in front window`, which measured about 2.39s and can fail after a slow front-window lookup.

## Plan

1. Keep `Cmd+T` sending the Newmux user-key request.
2. Add Ghostty `chain=new_tab` so Ghostty opens the tab natively instead of through shell AppleScript.
3. Run `request-newmux-new-tab.sh` with tab opening disabled from the tmux binding.
4. Move event logging after marker creation so it cannot delay the attach marker.
5. Add a short startup wait for the marker to cover the race between Ghostty's text send and native new-tab startup.
6. Verify headless request/claim timing and the exact `Cmd+T` UI workflow.

## Verification

- Before fix: `osascript ... new tab in front window` measured about 2.39s and failed on front-window lookup in the diagnostic run.
- Headless Newmux request after fix: marker written about 65ms after script entry.
- Headless startup claim after fix: claimed the requested window id in about 0.23s total.
- Real UI probe: actual `Cmd+T` opened/attached windows through the new native-chain path; per-window trace showed marker claim and attach completing roughly within 70-170ms after the key event. The synthetic `osascript keystroke` repeated the shortcut multiple times during focus changes, so it was useful for timing but not treated as a single-press behavioral regression result.
- Config validation: `./scripts/test-ghostty-config.sh` passed, with Ghostty's existing `SentryInitFailed` stderr noise.

## Status

Fixed locally; GitHub issue creation was blocked because `gh` is not authenticated.
