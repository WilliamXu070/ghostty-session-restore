# AGENTS.md

## Project Vision

This project is an experiment in building a terminal environment that feels like a modern browser: fast, persistent, recoverable, and forgiving.

The core idea is a version of **Ghostty + tmux** with live terminal history and session recovery built in. If a user accidentally closes, deletes, detaches, kills, or loses a terminal pane/session, they should be able to bring it back with something as natural as:

```text
Command + Shift + T
```

Just like reopening a closed tab in Chrome.

The terminal should stop treating lost sessions as permanent damage. Instead, it should treat terminal state as recoverable history.

## Product Goal

Create a terminal/session system where users can:

- Scroll through live and historical terminal output without losing context.
- Recover recently closed terminal tabs, panes, windows, or tmux sessions.
- Reopen accidentally deleted terminal states with a familiar shortcut.
- Resume work from a prior terminal state with minimal friction.
- Move between active sessions and recoverable history as if terminal work were versioned.

The user experience should feel like:

> "I closed the wrong terminal. No problem. Command + Shift + T brings it back."

## Current Execution Plan

The current direction is to build a custom Ghostty + Newmux install rather than a generic tmux plugin only.

Newmux should start as a tmux fork that is easier to use every day and then grow into a recoverable terminal workspace engine. The first product surface should focus on these concrete problems:

- Improve scrolling and make fast history movement feel better than stock tmux.
- Fix copy and paste workflows so selection, clipboard, and mouse use feel natural inside Ghostty.
- Clean up keybindings for panes, windows, navigation, splitting, deleting, and restoring.
- Add delete-window and delete-pane behavior that can feed a recoverable stack instead of immediately losing state.
- Add restore behavior for recently deleted panes and windows.
- Explore live pane/live history capture that stays responsive under heavy output.
- Improve scroll-up UI so the user's active input/caret still feels anchored at the bottom instead of disorienting the workspace.

The bigger product is a terminal emulator/workspace "from another dimension": Ghostty's speed and polish, tmux's multiplexing power, and a Newmux recovery model that makes terminal work feel undoable.

## Why This Matters

Terminals are powerful but unforgiving. A browser assumes users make mistakes and gives them tools to recover. Terminals usually do not.

This project should make terminal work safer by preserving:

- Output history
- Pane layout
- Working directories
- Command context
- Session metadata
- Recently closed terminal states

The goal is not only to save scrollback. The goal is to recover the *shape of work*.

## Desired User Experience

The interface should feel close to Ghostty in speed and polish, with tmux-like power underneath.

Important behaviors:

- `Command + Shift + T` reopens the most recently closed terminal tab, pane, or session.
- Live history scroll remains available even after panes are rearranged or sessions are restored.
- Closed sessions enter a recoverable history stack instead of disappearing immediately.
- Users can browse prior sessions visually or through a command palette.
- Recovery should be fast enough that it feels native, not like loading an archive.
- The system should make it clear what can be restored and what cannot.

## Core Concepts

### Live History

Terminal output should be persisted as it happens. The user should be able to scroll backward through history even when the process, pane, or session has changed.

Live history is not just a static log. It should preserve enough structure to understand what happened:

- Timestamped output
- Prompt boundaries when detectable
- Commands that were run
- Exit codes when available
- Working directory changes
- Pane/session identity

Current prototype:

- `copy-mode -L` enters an opt-in live copy mode backed by the pane's real screen instead of a frozen clone.
- While live copy mode is active, new pane output triggers the copy-mode update hook immediately after tmux parses pane input.
- If the user is at the bottom, live copy mode follows new output and animations on the active screen.
- If the user is scrolled up, history growth adjusts the scroll offset so the visible viewport stays stable instead of jumping.
- The dev Ghostty/Newmux config binds scroll entry and prefix `H` to `copy-mode -Le` so normal testing uses the live path.

This is still a prototype, not the final persistent history architecture. It keeps current output live inside tmux's in-memory grid, but it does not yet persist PTY/event logs, keyframes, or closed-pane history to disk.

### Recoverable Sessions

When a terminal tab, pane, or tmux session closes, it should not be destroyed immediately.

Instead, it should become a recoverable object with metadata:

- Session ID
- Name/title
- Working directory
- Last command
- Process state if still recoverable
- Scrollback/output buffer
- Pane layout
- Close time
- Restore eligibility

### Terminal Undo Stack

The project should explore the idea of a terminal-level undo stack.

At minimum:

- Reopen last closed terminal
- Reopen multiple recently closed terminals in order
- Show a list of recently closed sessions
- Allow users to pin or preserve important sessions

Future versions may support richer rollback or branching behavior, but the first useful version should focus on reliable reopening.

## Possible Architecture

The project may combine ideas from:

- Ghostty-style terminal rendering and native app performance
- tmux-style multiplexed sessions, panes, and detach/attach workflows
- Persistent scrollback storage
- Session metadata snapshots
- A recovery manager that tracks recently closed terminal states

Potential components:

- **Terminal frontend**: native UI, keybindings, tabs, panes, scrollback rendering.
- **Session manager**: owns active and recoverable sessions.
- **History store**: persists terminal output and metadata.
- **Recovery stack**: tracks closed sessions in restore order.
- **tmux bridge**: integrates with tmux sessions where useful.
- **Command palette**: exposes restore, search, and navigation actions.

## MVP

The first meaningful version should prove the central promise:

> Accidentally close a terminal, press `Command + Shift + T`, and get useful state back.

MVP scope:

- Track terminal tabs or panes.
- Capture scrollback/history for each session.
- On close, store the session in a recently closed stack.
- Implement `Command + Shift + T` to reopen the latest closed session.
- Restore working directory and visible history.
- Show restored sessions clearly so users know they are viewing recovered state.

If full process resurrection is not possible at first, the MVP can restore the terminal history and working directory, then explain that the process itself cannot be resumed.

## Non-Goals For Now

Avoid getting stuck on these too early:

- Perfect process resurrection across every shell/program.
- Reimplementing all of tmux immediately.
- Building a full terminal emulator before validating the recovery model.
- Complex distributed sync.
- Cloud backup.
- AI features before the core recovery workflow feels solid.

## Design Principles

- **Forgiving by default**: closing something should rarely mean losing it forever.
- **Fast recovery**: reopening a terminal should feel instant.
- **Respect terminal power users**: shortcuts, pane layouts, and shell workflows matter.
- **Make state visible**: users should understand what is active, closed, restorable, or expired.
- **Do not fake resurrection**: if a process cannot be restored, say so clearly and restore everything else.
- **Start useful, then get deeper**: scrollback and working directory recovery are already valuable.

## Open Questions

- Should this wrap tmux, replace parts of tmux, or integrate with tmux as an optional backend?
- How much process state can realistically be restored on macOS?
- Should closed sessions expire after time, count, disk usage, or explicit deletion?
- What is the right storage format for scrollback and session metadata?
- Should recovery happen at the terminal app level, tmux level, or both?
- How should restored-but-not-running processes be represented in the UI?

## Current Repository Setup

This repository currently vendors an upstream tmux checkout in:

```text
tmux/
```

The first test alteration is intentionally small: `tmux/core/tmux.c` appends `-newmux-dev` to the reported version string. This lets us prove that local builds, scripts, Ghostty profiles, and smoke tests are using the fork rather than the system `tmux`.

The tmux source tree has been reorganized from a flat upstream layout into responsibility folders such as `commands/`, `server/`, `terminal/`, `screen/`, and `windows/`. See `tmux/SOURCE_LAYOUT.md` for the navigation map. This was a file-move-only modularization pass; behavior should remain the same.

Source and development layout:

- `tmux/`: vendored tmux fork used to build `bin/newmux`.
- `ghostty-src/`: vendored Ghostty source for frontend/protocol work such as richer macOS scroll events.
- `ghostty-config/`: Ghostty profiles that launch Newmux builds.

Generated development files:

- `scripts/build-newmux.sh`: configures, builds, installs, copies the fork to `bin/newmux`, and ad-hoc signs the copied binary on macOS.
- `scripts/build-ghostty.sh`: builds the patched Ghostty core and macOS app. The app bundle is written outside the Desktop-backed repo at `~/.cache/newmux/ghostty-macos-build/Debug/Ghostty.app` to avoid macOS File Provider extended attributes breaking codesign.
- `scripts/run-newmux.sh`: runs `bin/newmux` with an isolated socket and the dev tmux config.
- `scripts/start-newmux-fresh.sh`: kills stale `newmux-dev` processes/socket, then execs `run-newmux.sh`.
- `scripts/test-newmux.sh`: headless smoke test for the binary, server, config load, and placeholder key hooks.
- `scripts/open-newmux-ghostty.sh`: kills the existing dev socket, then opens normal `/Applications/Ghostty.app` with a fresh newmux test profile by default.
- `scripts/open-scroll-test-ghostty.sh`: opens normal `/Applications/Ghostty.app` with 1000 lines of generated sample output for scrolling experiments.
- `scripts/test-ghostty-config.sh`: validates the Ghostty profile without opening a terminal window, using normal Ghostty by default.
- `scripts/install-ghostty-newmux.sh`: adds the newmux Ghostty profile to the user's Ghostty config via `config-file`.
- `config/newmux-dev.tmux.conf`: dev tmux config with visible status branding and placeholder key bindings.
- `ghostty-config/newmux.config`: Ghostty profile that launches `/bin/zsh`, then uses startup input to exec `scripts/start-newmux-fresh.sh`.

Local build dependencies on macOS are:

```text
brew install autoconf automake pkg-config libevent ncurses utf8proc
```

The build script sets Homebrew include, library, and pkg-config paths for these dependencies. On macOS it also runs `codesign --force --sign - bin/newmux`; without this, a copied local Mach-O may be killed by macOS even though `tmux/tmux` runs directly from the build directory.

Patched Ghostty builds also require:

```text
brew install zig@0.15 nushell
xcodebuild -downloadComponent MetalToolchain
```

`zig@0.15` is keg-only, so `scripts/build-ghostty.sh` explicitly falls back to `/opt/homebrew/opt/zig@0.15/bin/zig`. Ghostty's macOS build uses `ghostty-src/macos/build.nu`; this repo adds `NEWMUX_GHOSTTY_SYMROOT` support so Xcode can write the app bundle to `~/.cache/newmux/ghostty-macos-build` instead of the Desktop-backed source tree.

## Build And Test

Build the local fork:

```sh
./scripts/build-newmux.sh
```

Build the patched Ghostty app:

```sh
./scripts/build-ghostty.sh
```

Run smoke tests:

```sh
./scripts/test-newmux.sh
./scripts/test-ghostty-config.sh
```

Run compact golden flows for backend/session behavior:

```sh
python3 scripts/newmux-flow-test.py tests/flows/cmd-t-new-tab-same-server.json
```

Golden flows are small JSON-defined regression flows. Run the relevant golden
flows whenever a significant feature is added or a bug is fixed, especially if
startup, key routing, tab/window creation, linked sessions, panes, recovery, or
dashboard state could be affected. Before adding a new golden flow, tell the
user what behavior it would protect and ask permission; keep the flow focused so
the suite does not become bloated.

When the user says `MAKE SURE BITCH`, run the required Newmux recovery golden
flow set before calling the work done:

```sh
python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json
python3 scripts/newmux-flow-test.py tests/flows/cmd-w-ui-tab-sync.json
```

These two flows are mandatory because they protect the current critical
recovery behavior:

- clean physical `Cmd+T` then `Cmd+W` hard-deletes and does not enter LIFO
- dirty terminal output then delete soft-stores into LIFO
- Ghostty visible tabs, Newmux backend windows, and the UI-sync reader agree
  after delete

When the user says `ADD BITCH`, treat it as explicit permission to add the
newly relevant golden flow to the required `MAKE SURE BITCH` set above. Keep the
set compact: only add flows that protect a critical, recently fixed regression
or an invariant the user explicitly wants guarded every time.

Treat the default manual testing platform as protected infrastructure:

- Do not change the default behavior of `scripts/open-newmux-ghostty.sh`,
  `scripts/newmux-ui-bridge.py dashboard`, `ghostty-config/newmux.config`, or
  the `newmux-dev` socket/profile just to test a new idea.
- New diagnostics, UI readers, headed checks, or experimental observers must be
  opt-in flags, separate commands, or new flow files.
- The user-facing baseline command must remain stable unless the user
  explicitly asks to change it:

```sh
./scripts/open-newmux-ghostty.sh && sleep 2 && python3 scripts/newmux-ui-bridge.py dashboard --socket-name newmux-dev
```

- If a test needs extra hooks, add those hooks behind explicit environment
  variables or test-only flags. Never make the dashboard launch a different UI
  by default, never redirect the launcher into a synthetic test bed, and never
  replace the baseline Ghostty/Newmux path with a new experiment.

UI sync tests should compare independent views of the same state, not only the
Newmux server. The backend source of truth is the `newmux-ui-bridge.py snapshot`
data: visible workspaces, windows, panes, dirty state, and LIFO recovery stack.
The frontend source of truth is the currently running Ghostty UI: native tab
count, selected tab/window, and the Newmux visual rail/dashboard representation.
A UI test is valid only when it proves the invariant:

```text
visible backend windows == visible Ghostty tabs == visible dashboard/rail items
```

Use the existing `newmux-dev` launcher path for these UI checks. Do not create a
separate socket, profile, or synthetic UI test bed unless the user explicitly
asks for isolation. UI tests should expose mismatches directly, for example:
backend says a window was deleted but Ghostty still renders a stale tab.

Expected test output includes:

```text
newmux smoke tests passed
binary: tmux next-3.7-newmux-dev
server: next-3.7-newmux-dev
```

Open a newmux development session directly:

```sh
./scripts/run-newmux.sh new-session -A -s newmux
```

Open through Ghostty, if the Ghostty CLI is installed:

```sh
./scripts/open-newmux-ghostty.sh
```

This intentionally deletes the previous `newmux-dev` tmux server before opening Ghostty, so each launcher run starts a fresh dev terminal. Manual reuse/attach behavior should go through `scripts/run-newmux.sh` instead. The launcher uses normal `/Applications/Ghostty.app` by default. To test the patched Ghostty app explicitly, set `NEWMUX_USE_PATCHED_GHOSTTY=1` or pass `NEWMUX_GHOSTTY_APP=/path/to/Ghostty.app`.

Open a scrolling test profile with generated sample output:

```sh
./scripts/open-scroll-test-ghostty.sh
```

The user's normal Ghostty config is also set up to include this repo's profile, so opening Ghostty from macOS Spotlight loads newmux automatically:

```text
~/.config/ghostty/config
config-file = /Users/williamxu/Desktop/Projects/newmux/ghostty-config/newmux.config
```

A backup of the prior config, if any, is written to:

```text
~/.config/ghostty/config.newmux-backup
```

The profile deliberately uses a normal shell command plus startup input:

```text
confirm-close-surface = false
command = /bin/zsh
input = raw:exec /Users/williamxu/Desktop/Projects/newmux/scripts/start-newmux-fresh.sh\r
```

This avoids Ghostty's macOS login wrapper trying to treat the newmux binary or shell scripts as login shells. `start-newmux-fresh.sh` gives each normal Spotlight launch a fresh `newmux-dev` server.

`confirm-close-surface = false` is intentional: the user does not want Ghostty's "Quit Ghostty? All terminal sessions will be terminated." confirmation dialog to appear for this development profile.

The Ghostty profile binds:

```text
Command + Shift + T
```

to send tmux `Ctrl-B` followed by `T`, which currently triggers a placeholder restore message. In the future, that binding should call the real "reopen latest soft-closed pane/window/session" command.

## Current Scroll Bridge

The current Ghostty + Newmux scroll bridge is wired end to end:

- `ghostty-src/src/Surface.zig` sends a private Newmux CSI packet before normal mouse wheel reporting when mouse reporting is active.
- `tmux/terminal/tty-keys.c` consumes that CSI packet and attaches precise scroll metadata to the next wheel event.
- `tmux/tmux.h` carries the pending scroll metadata on `struct client` and per-event fields on `struct mouse_event`.
- `tmux/windows/window-copy.c` uses the same smoothing algorithm for fallback wheel events and precise Ghostty scroll events.

The main tuning constants are in `tmux/windows/window-copy.c`:

```text
NEWMUX_WHEEL_RESET_US
NEWMUX_WHEEL_FRAME_US
NEWMUX_WHEEL_SENSITIVITY_MILLI
NEWMUX_WHEEL_MAX_UP_LINES_PER_SECOND
NEWMUX_WHEEL_MAX_DOWN_LINES_PER_SECOND
NEWMUX_WHEEL_MAX_UP_LINES_PER_TICK
NEWMUX_WHEEL_MAX_DOWN_LINES_PER_TICK
```

## Implementation Direction

The cleanest architecture remains:

1. Fork tmux and keep it buildable as `bin/newmux`.
2. Add persistent visual history capture inside the tmux server.
3. Add soft-close recovery for panes, windows, and sessions.
4. Add replay/scrub APIs through tmux commands or control mode.
5. Let Ghostty remain the fast frontend and renderer.

The first serious tmux changes should avoid recording full rendered video frames. Prefer:

- Append-only PTY byte logs or parsed terminal event logs.
- Periodic grid snapshots as keyframes.
- Compressed cell diffs between keyframes.
- Retention limits by time, byte size, and user pinning.
- Explicit handling for alternate-screen programs such as `vim`, `less`, `top`, and `htop`.
- Playback using tmux's existing terminal parser and grid machinery where possible.

Live copy-mode implementation notes:

- `tmux/commands/cmd-copy-mode.c` owns the `copy-mode -L` flag.
- `tmux/windows/window-copy.c` owns the live/frozen backing choice, copy-mode redraws, and viewport stabilization.
- `tmux/windows/window.c` calls the active copy-mode update hook after `input_parse_pane(wp)` so live copy mode reflects new output without waiting for manual refresh.
- `scripts/test-newmux.sh` includes a smoke test that enters `copy-mode -L`, lets later process output arrive, and verifies the mode screen renders that later output.

## Working Name

Possible names:

- Newmux
- Ghostmux
- Term Rewind
- Shellback
- Terminal Undo

The current repository name, `newmux`, fits the early direction well.

## Guidance For Future Agents

When working on this project, preserve the central promise:

> Terminal work should be recoverable like browser tabs.

When asked to make a plan, keep it concise. Focus on:

- the main idea
- the technical mechanism and why it works
- the data sources, ownership boundaries, and state transitions
- the invariants that prove correctness
- the concrete files, hooks, APIs, or systems involved
- the failure modes and the simplest way to detect them

Do not answer planning requests with generic execution checklists, UI feature
lists, or obvious implementation chores. For example, if the user asks how an
observer should visualize state, explain the observer architecture: which source
is authoritative, how backend and frontend state are normalized, how mismatches
are classified, which hook is fastest or least flaky, and what evidence proves a
stale UI. Avoid bloated planning, repeated product motivation, obvious filler,
and long speculative branches unless the user explicitly asks for depth.

Prefer small prototypes that validate recovery behavior over broad rewrites. The most important user story is not "build a better tmux." It is:

> "I accidentally closed something important, and this tool helped me get it back."

Every architecture decision should serve that moment.
