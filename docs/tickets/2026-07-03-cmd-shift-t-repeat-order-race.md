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

## 2026-07-04 Fast Restore Update

Symptom: holding `Cmd+Shift+T` across multiple dirty tabs still felt slow
because restore was backend-first: Ghostty waited for Newmux restore/attach work
before the native tab intent existed.

Diagnosis: restore needed the same invariant as fast create, but with server
ownership: reserve a closed item first, render a pending native tab only when an
item exists, then let the pending tab claim/attach that reserved sequence. Empty
repeat events should be cheap no-ops, not ghost native tabs.

Fix: added a server reserved-release command, moved pending restore claim/attach
into `scripts/start-newmux-fresh.sh`, mirrored successful claims to the Python
diagnostic runtime asynchronously, and taught `newmux-create-window` an explicit
native insertion index so backend/native order stays aligned after restores.

Verification added:

- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-repeat-order-guard.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-restore-runtime-lifo.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-left-tab-position.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-noop-empty.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-t-new-tab-same-server.json`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-w-ui-tab-sync.json`
- `python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json`

## 2026-07-04 Fast Create Update

Symptom: `Cmd+T` still had parent-side backend work after the native tab intent
was posted. Ghostty created the Newmux window in a background subprocess, then
the spawned tab waited for a token file before it could attach.

Fix: changed `Cmd+T` to post only visual intent plus create metadata. The
spawned tab now owns `newmux-create-window`, writes its resolved window id for
bookkeeping, and attaches directly. The obsolete pending-window wait strategy
and unused create mutation helpers were removed.

Verification added:

- `sh -n scripts/start-newmux-fresh.sh`
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-t-new-tab-same-server.json`
