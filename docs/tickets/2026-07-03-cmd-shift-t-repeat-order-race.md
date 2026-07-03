## Symptom

Holding `Cmd+Shift+T` can lag while restored tabs are created. After that lag,
new `Cmd+T` tabs can appear on the left instead of to the right of the active
tab.

## Expected Behavior

Repeated restore input must not overlap native Ghostty tab mutation. Normal
`Cmd+T` should create a new native tab to the right of the active Newmux tab.

## Diagnosis

The native Ghostty Newmux actions were doing blocking `bin/newmux` process calls
on the Ghostty UI thread. Under key repeat, that made tab creation/deletion feel
buffered. Moving the calls off the main thread exposed a second race: late
`Cmd+T` completions could still post tabs after `Cmd+W` started closing tabs,
creating fresh backend windows after the close burst.

## Plan

- Guard native Newmux tab mutations in `Ghostty.App.swift`.
- Explicitly insert normal `Cmd+T` to the right of the active native tab.
- Add a focused rapid-repeat flow that verifies one restore accepts and the next
  `Cmd+T` lands right of the restored tab.
- Move Newmux backend commands off the Ghostty main thread where possible.
- Add a generation guard so any close invalidates older pending create
  completions; stale create results delete their backend window instead of
  posting a new native tab.

## Verification

- `./scripts/refresh-spotlight-ghostty.sh`
- `./scripts/test-ghostty-config.sh`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-t-w-background-burst-no-buffer.json`
- `python3 scripts/benchmark-newmux-lifecycle.py --passes 1 --driver action --burst-interval 0 --out .local/benchmarks/newmux-lifecycle-held-action-zero-delay.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-t-new-tab-same-server.json`
- `python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-w-ui-tab-sync.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-noop-empty.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-restore-runtime-lifo.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-left-tab-position.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-repeat-order-guard.json`

Measured with the background Ghostty action driver:

- clean `Cmd+T` visible: 85.9 ms
- clean `Cmd+W` backend/UI visible: 83.0 ms
- immediate 18-action `Cmd+T` burst send: 642.0 ms, quiet: 546.9 ms
- immediate 48-action `Cmd+W` burst send: 1022.3 ms, back-to-one: 82.1 ms,
  quiet: 432.4 ms

## Status

Fixed and verified with the focused held-key flow plus recovery/order gates.
