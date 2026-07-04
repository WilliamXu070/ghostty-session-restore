## Symptom

In Ghostty, pressing Cmd+W shows the User2 run-shell command and `returned 126`. The tab does not close, and the Python UI does not register an active/LIFO state change.

## Expected behavior

Cmd+W should execute without helper output, close clean windows by hard delete, soft-hide dirty windows into LIFO, and update the Python UI snapshot.

## Diagnosis

`config/newmux-dev.tmux.conf` executes `scripts/newmux-runtime.py` directly from the User2 binding. That file is not executable (`-rw-r--r--`), so the shell returns 126. Redirection hides stdout/stderr but does not prevent tmux from reporting the failed job status.

## Plan

- Change tmux shortcut bindings to invoke Python helpers through `python3`.
- Add a golden-flow action that runs the configured User2 command path instead of bypassing it.
- Add a headed Ghostty flow that opens a tab and closes it through the configured Cmd+W binding path.
- Verify no 126 and active/LIFO counts update.

## Verification

- `python3 -m py_compile scripts/newmux-flow-test.py scripts/newmux-runtime.py scripts/newmux-ui-bridge.py scripts/newmux-ui-app.py` passed.
- `sh -n config/newmux-dev.tmux.conf scripts/open-newmux-ghostty.sh scripts/request-newmux-new-tab.sh` passed.
- `python3 scripts/newmux-flow-test.py tests/flows/cmd-w-binding-headed-clean-delete.json` passed.
  - `start.windows=1`
  - `after_cmd_t.windows=2`
  - `after_cmd_w.windows=1`
  - no `returned 126`
- `python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json` passed.
- Dashboard after the dirty flow showed `Active: 1 terminal windows, 1 panes` and `Deleted LIFO: 1 recoverable items`.

## Status

Fixed.
