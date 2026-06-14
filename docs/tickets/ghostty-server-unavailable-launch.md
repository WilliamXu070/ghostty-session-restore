# Ghostty Launch: Server Unavailable

## Symptom

Opening the Newmux Ghostty profile could show `server unavailable` and close or leave no reachable `newmux-dev` server.

## Root Cause

`ghostty-config/newmux.config` was using:

```text
command = direct:/Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh
```

On macOS this re-entered Ghostty's login-wrapper launch path for the script. That was less reliable than the known-good project profile shape documented in `AGENTS.md`: start `/bin/zsh`, then send startup input to `exec` the launcher script.

## Fix

Restored the profile to:

```text
command = /bin/zsh
input = raw:exec /Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh\r
```

## Verification

- `./scripts/test-ghostty-config.sh`
- Normal `./scripts/open-newmux-ghostty.sh` launch with trace.
- `bin/newmux -L newmux-dev list-sessions` returned one attached `newmux` session.
- `python3 scripts/newmux-ui-bridge.py dashboard --socket-name newmux-dev --once` showed one active `zsh` window.
