# Newmux UI Bridge

The Newmux UI bridge is the interaction layer between the Newmux backend and
Ghostty's native UI. Newmux remains the source of truth; Ghostty renders a
projection of Newmux state.

## Ownership

- Newmux owns sessions, windows, panes, recovery state, names, order, and
  active selections.
- Ghostty owns native macOS windows/tabs and terminal rendering.
- Panes are rendered by Newmux/tmux inside the terminal grid for now. Ghostty
  receives pane metadata for labels, command palette entries, future pane UI,
  and diagnostics, but it should not duplicate pane layout rendering yet.
- Sessions should map to Ghostty workspace/window groups. Windows map to
  Ghostty top tabs. Panes remain inside the selected tab.

## Sidecar MVP

The current prototype is:

```text
scripts/newmux-ui-bridge.py
```

It exposes a JSON-lines Unix socket. The dev launcher starts it and exports:

```text
NEWMUX_UI_BRIDGE_SOCKET=/path/to/newmux-ui.sock
```

This sidecar queries the running Newmux server. It can later be replaced by an
in-server C bridge using the same JSON schema.

## Requests

Request a full snapshot:

```json
{"type":"get_snapshot"}
```

Subscribe to state changes:

```json
{"type":"subscribe"}
```

Run a command:

```json
{"type":"command","command":"new_window","session":"newmux","name":"api"}
```

Supported command names in the sidecar MVP:

- `new_window`
- `select_window`
- `rename_window`
- `split_window`
- `soft_close_window`
- `restore_latest`

## Snapshot

Snapshots have this shape:

```json
{
  "type": "snapshot",
  "schema": "newmux.ui.snapshot.v1",
  "revision": "sha-prefix",
  "sessions": [],
  "windows": [],
  "panes": [],
  "recovery_stack": []
}
```

The revision is derived from stable state. Ghostty should request a new
snapshot if it detects a missed event or reconnects.

## Ghostty Render Model

The test renderer is:

```text
scripts/newmux-ghostty-render-model.py
```

It converts a snapshot into the UI model Ghostty should render:

- session groups
- top tabs ordered by Newmux window index
- active window per session
- pane IDs and pane counts per tab
- recovery stack metadata

This is the contract for the future native Ghostty patch.

## Next Native Ghostty Patch

Ghostty should subscribe to `NEWMUX_UI_BRIDGE_SOCKET` and reconcile native tabs:

1. Create missing native tabs for Newmux windows.
2. Close or hide native tabs for soft-closed windows.
3. Rename native tabs when Newmux window names change.
4. Select native tabs when Newmux active window changes.
5. On `Cmd+Shift+T`, send `restore_latest`, then render the restored window as
   a top tab from the resulting snapshot.

Until this native reconciliation exists, Newmux can restore a backend window
without Ghostty automatically creating a matching top tab.
