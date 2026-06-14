## Symptom

Running `./scripts/open-newmux-ghostty.sh` opened Ghostty, asked macOS to allow `scripts/run-newmux.sh`, then exited with `no sessions`.

## Diagnosis

Startup ownership was split: the launcher prestarted Newmux, then forced Ghostty to run `run-newmux.sh attach-session -t newmux`. The Ghostty profile no longer had its own `command`, so a failed or mismatched prestart left Ghostty attaching to an empty socket.

## Plan

Restore Ghostty-owned startup with `command = direct:.../start-newmux-fresh.sh`; keep the launcher responsible only for cleanup, env, UI bridge, and opening Ghostty.

## Verification

Run `./scripts/open-newmux-ghostty.sh`, wait, then verify the `newmux-dev` socket has a `newmux` session and no `run-newmux.sh attach-session` launch path is active.

## Status

Implemented.
