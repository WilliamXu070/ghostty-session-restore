## Symptom

Pressing Cmd+T, Cmd+W, or Cmd+Shift+T can leak helper JSON/text into Ghostty and corrupt the Python dashboard display.

## Expected behavior

Shortcut paths should mutate Newmux state only. No helper stdout/stderr should reach the pane or dashboard.

## Diagnosis

Tmux run-shell bindings redirect current commands, but helper scripts still have stdout-producing defaults. If a server has stale config or a path is invoked without redirection, `newmux-runtime.py delete` prints JSON. Older key-event paths also historically printed shortcut JSON.

## Plan

Make shortcut-oriented helper commands silent by default, keep JSON only behind explicit flags, and verify the exact launcher/dashboard workflow.

## Verification

- `request-newmux-new-tab.sh` produced no stdout/stderr when invoked without redirection.
- `newmux-runtime.py delete` produced no stdout/stderr when invoked without redirection.
- `newmux-ui-bridge.py key-event` produced no stdout/stderr.
- `python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json` passed.
- Dashboard render showed only active terminal and LIFO state, with no raw shortcut JSON.

## Status

Fixed.
