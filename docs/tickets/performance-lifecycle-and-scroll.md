## Symptom

Newmux/Ghostty performance needs a current baseline for UI responsiveness:
scrolling, new tab time to first command execution, tab deletion, and recovery.

## Expected Behavior

Normal tab lifecycle should feel native:

- `Cmd+T` creates a tab and reaches command-ready state quickly.
- `Cmd+W` removes a tab without visible stale state.
- `Cmd+Shift+T` restores a dirty tab with useful ordering and low latency.
- scroll input should produce visible motion without perceptible lag.

## Measurement Plan

- Use `scripts/benchmark-newmux-lifecycle.py` for physical shortcut lifecycle latency.
- Use `scripts/bench-current-newmux.sh` for tmux copy-mode command cost.
- Use `scripts/probe-scroll-latency-ui.py` and `scripts/probe-active-scroll-ui.py` for visible Ghostty scroll latency/FPS.

## Status

Benchmark harness added. Current measurements and diagnosis should be recorded
before implementing performance changes.

## Current Baseline

Installed app:

- `/Applications/Ghostty.app`
- Ghostty `ReleaseFast`
- version `1.3.2-experiment-scroll-jitter-boost-+9d8dbc4`

Physical lifecycle benchmark:

```sh
./scripts/benchmark-newmux-lifecycle.py --passes 3 --timeout 10
```

Results:

- startup to attached Newmux client: `590.96 ms`
- clean `Cmd+T` visible: avg `118.01 ms`, p50 `83.74 ms`, max `189.14 ms`
- clean `Cmd+W` visible: avg `188.35 ms`, p50 `189.20 ms`
- dirty `Cmd+W` visible: avg `186.44 ms`, p50 `186.88 ms`
- `Cmd+Shift+T` restore visible: avg `117.92 ms`, p50 `84.00 ms`
- first command echo after new tab: avg `11.42 ms`, p50 `11.71 ms`

Backend-only lifecycle benchmark on `newmux-perf-headless`:

- clean create: p50 `79.47 ms`
- clean delete: p50 `94.86 ms`
- dirty create: p50 `81.64 ms`
- command dirty mark: p50 `49.78 ms`
- dirty delete: p50 `120.91 ms`
- restore: p50 `72.16 ms`

Fixed process overhead measurements:

- `python3 -c pass`: p50 `16.88 ms`
- one `newmux display-message`: p50 `5.51 ms`
- `newmux-runtime.py stack`: p50 `48.73 ms`

Scroll:

- tmux-side live copy-mode batch, 900 lines: mostly `10-15 ms`, one `83.7 ms` spike
- headed animation pixel probe: pass, visible animation changes
- sequential scroll latency probe: avg `26.09 ms`, p50 `25.50 ms`, p95 `49.41 ms`
- active-FPS probe is currently unreliable unless run sequentially with a crop that avoids
  boundaries; parallel Quartz probes caused a false `30s` capture stall.

## Diagnosis

- Lifecycle latency is dominated by the Python runtime bridge and repeated tmux
  subprocess calls, not by Ghostty rendering alone.
- Clean delete is slower than create because delete computes pane state, order
  context, dirty state, and syncs the workspace ledger before closing.
- Dirty delete is slower again because it links into the recovery session, unlinks
  visible sessions, writes LIFO metadata, and syncs order.
- `Cmd+W` had a real user-path bug: app-target close could fall through to native
  Ghostty close without calling Newmux. Patched `newmux_close_tab` to resolve the
  focused surface for app targets.
- Scroll command cost is acceptable, but visual scroll fluidity is governed by
  event pacing, redraw cadence, selection invalidation, and probe overhead.

## Architecture Diagnosis

### Lifecycle Boundary

Current user path:

```text
Ghostty keybind
  -> Ghostty.App.swift newmux action
  -> synchronous /usr/bin/env python3 scripts/newmux-runtime.py
  -> many bin/newmux subprocess calls
  -> JSON parse in Swift
  -> native Ghostty tab mutation
  -> start-newmux-fresh.sh attach path for the new surface
```

Design decisions causing latency:

- Ghostty blocks the UI action while Python starts and completes.
- `newmux-runtime.py` treats every query/mutation as a separate `bin/newmux`
  subprocess.
- Runtime state is split between tmux's in-memory recovery stack and Python's
  JSON/LIFO/order-ledger files.
- Every native Ghostty tab is represented as a linked `newmux-tab-*` session,
  so attach/delete/restore must preserve extra tab-session mapping state.
- Delete does full state discovery even when the only required decision is
  clean hard-delete vs dirty soft-delete.

Approximate process-boundary count:

- `Cmd+T`: one Swift-launched Python plus about five `bin/newmux` calls before
  the native tab is posted; attach adds more startup/mapper calls.
- clean `Cmd+W`: one Python plus about eight `bin/newmux` calls.
- dirty `Cmd+W`: one Python plus about fourteen `bin/newmux` calls.
- `Cmd+Shift+T`: one Python plus restore calls, then native tab startup/attach.

### Recovery State Ownership

Newmux already has native recovery commands in `tmux/commands/cmd-newmux-recovery.c`:

- `newmux-soft-delete-window`
- `newmux-reopen-latest-closed`
- `newmux-reserve-latest-closed`
- `newmux-claim-reserved-closed`
- `newmux-list-recently-closed`

The slow design issue is that Ghostty currently bypasses much of that native
path and relies on `scripts/newmux-runtime.py` to recreate recovery behavior
with JSON files, link/unlink commands, order ledgers, and tab-session maps.

The fastest architecture is: tmux owns recovery state; Ghostty asks tmux for
one compact result; Python remains dashboard/test tooling.

### Scroll Boundary

Current scroll path:

```text
Ghostty Surface.zig scrollCallback
  -> private Newmux CSI ?7777 metadata
  -> normal mouse wheel reports
  -> tmux tty-keys.c attaches metadata to next wheel event
  -> server-client fast live-scroll path
  -> window-copy.c pacing/redraw
```

Confirmed non-bottleneck:

- raw live copy-mode command movement is already fast.

Design decisions causing perceived scroll lag:

- input-event-paced scrolling can apply large logical movement between rendered
  frames, so fast scroll feels jumpy rather than smooth.
- Ghostty emits one metadata packet but still emits repeated ordinary wheel
  reports; tmux then skips synthetic duplicates.
- selection/highlight state can force broad redraw behavior; selection presence
  should not imply full viewport repaint.
- current active-FPS probes are useful but fragile; scroll latency probes are
  more reliable for now.

## Worktree Resolution Plan

Before creating implementation worktrees, commit or intentionally stage the
current baseline changes. The existing worktree
`.worktrees/native-newmux-ghostty-actions` is behind the current branch and
should not be used as-is.

### Workstream 1: Native Lifecycle Commands

- Branch: `codex/perf-native-lifecycle`
- Worktree: `.worktrees/perf-native-lifecycle`
- Goal: reduce `Cmd+T`, `Cmd+W`, and `Cmd+Shift+T` to one compact Newmux call
  per backend action.
- Owns:
  - `tmux/commands/cmd-newmux-recovery.c`
  - `tmux/commands/cmd-new-window.c` if a printed create helper is needed
  - `tmux/commands/cmd.c`
  - `ghostty-src/macos/Sources/Ghostty/Ghostty.App.swift`
  - minimal compatibility shim in `scripts/newmux-runtime.py`
- Non-goals:
  - no dashboard redesign
  - no scroll changes
  - no new recovery policy
- Target:
  - create/delete/restore backend p50 under `35 ms`
  - physical `Cmd+W` p50 under `100 ms`

### Workstream 2: Dirty State And Order Ownership

- Branch: `codex/perf-dirty-order-state`
- Worktree: `.worktrees/perf-dirty-order-state`
- Goal: stop recomputing dirty/order state through capture-pane and JSON
  ledgers on hot delete/restore.
- Owns:
  - `tmux/commands/cmd-newmux-recovery.c`
  - `config/newmux-zsh/.zshrc`
  - `scripts/newmux-runtime.py` only for compatibility/reporting
  - `scripts/newmux-ui-bridge.py` snapshot reporting
- Non-goals:
  - no Ghostty native tab behavior changes
  - no scroll changes
- Target:
  - dirty mark cost p50 below `10 ms`
  - dirty delete p50 below `70 ms`

### Workstream 3: Attach Path Simplification

- Branch: `codex/perf-tab-attach`
- Worktree: `.worktrees/perf-tab-attach`
- Goal: reduce per-tab `newmux-tab-*` session mapping and attach-time restore
  scans.
- Owns:
  - `scripts/start-newmux-fresh.sh`
  - `ghostty-config/newmux.config`
  - `ghostty-src/macos/Sources/Features/Terminal/TerminalController.swift`
  - `ghostty-src/macos/Sources/Ghostty/Ghostty.App.swift`
- Non-goals:
  - no recovery stack rewrite
  - no scroll changes
- Target:
  - startup attach under `350 ms`
  - no `/usr/bin/login` wrapper regression

### Workstream 4: Scroll Pacing And Selection Damage

- Branch: `codex/perf-scroll-pacing-selection`
- Worktree: `.worktrees/perf-scroll-pacing-selection`
- Goal: improve visible scroll latency and selection-active scroll by changing
  pacing/redraw policy, not the recovery system.
- Owns:
  - `ghostty-src/src/Surface.zig`
  - `tmux/terminal/tty-keys.c`
  - `tmux/server/server-client.c`
  - `tmux/windows/window-copy.c`
  - `tmux/tmux.h`
  - scroll probes/docs
- Non-goals:
  - no tab lifecycle changes
- Target:
  - no-selection scroll latency p50 near `20 ms`
  - selection-active latency no worse than no-selection plus one frame

### Workstream 5: Performance Test Harness

- Branch: `codex/perf-test-gates`
- Worktree: `.worktrees/perf-test-gates`
- Goal: make lifecycle benchmark and required flow suite easy to run after each
  integrated branch without changing the baseline manual launcher.
- Owns:
  - `scripts/benchmark-newmux-lifecycle.py`
  - `scripts/newmux-flow-test.py`
  - `scripts/run-regression.sh`
  - `scripts/regression-manifest.tsv`
  - `docs/tickets/performance-lifecycle-and-scroll.md`
- Non-goals:
  - no product behavior changes
- Target:
  - one command for correctness gate
  - one command for performance sampling
  - performance thresholds stay advisory until stable.

## Integration Gate

After each implementation branch merge:

```sh
./scripts/run-correctness-gate.sh
./scripts/sample-performance.sh
```

`run-correctness-gate.sh` runs:

```sh
./scripts/build-newmux.sh
./scripts/test-newmux.sh
./scripts/test-ghostty-config.sh
python3 scripts/newmux-flow-test.py tests/flows/delete-clean-hard-dirty-lifo.json
python3 scripts/newmux-flow-test.py tests/flows/cmd-w-ui-tab-sync.json
python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-noop-empty.json
python3 scripts/newmux-flow-test.py tests/flows/cmd-shift-t-restore-runtime-lifo.json
python3 scripts/newmux-flow-test.py tests/flows/cmd-t-new-tab-same-server.json
```

`sample-performance.sh` runs `benchmark-newmux-lifecycle.py` and writes a timestamped
JSON sample under `.local/benchmarks/`. Thresholds remain advisory until the
lifecycle numbers stabilize.

The same commands are registered in `scripts/regression-manifest.tsv`:

```sh
./scripts/run-regression.sh --test gate-correctness
./scripts/run-regression.sh --test perf-lifecycle-sample --include-manual
```

If Ghostty source changed:

```sh
./scripts/build-ghostty.sh
./scripts/refresh-spotlight-ghostty.sh
NEWMUX_USE_PATCHED_GHOSTTY=1 ./scripts/test-ghostty-config.sh
```

For scroll work, add:

```sh
NEWMUX_SOCKET=newmux-live-scroll-test PASSES=5 \
  ./scripts/bench-current-newmux.sh newmux-live-scroll:main
python3 scripts/probe-scroll-latency-ui.py --title "Newmux Live Scroll Test" \
  --owner Ghostty --out-dir .local/benchmarks/scroll-latency-after \
  --events 16 --timeout 0.25 --rest 0.06 --delta 1 --alternate \
  --threshold 500 --crop 120,220,800,220
```

## Speedup Direction

1. Move hot lifecycle actions out of short-lived Python:
   - first target: `create-window`, `delete-window`, `restore-latest`
   - implement as native Newmux/tmux commands or a persistent runtime daemon
   - keep Python as test/inspection tooling only

2. Reduce delete-path work:
   - avoid capture/hash work for clean panes
   - track dirty state in tmux/server memory instead of reading JSON files
   - update order ledger incrementally instead of resyncing full workspace each time

3. Make native UI optimistic:
   - after backend returns a valid window id, create/close the native tab immediately
   - write diagnostic metadata asynchronously

4. Improve scroll pacing:
   - keep tmux-side batch path
   - add frame-budgeted wheel coalescing so fast scroll advances smoothly per presented frame
   - optimize selection redraw separately; selection-active scroll remains the known risk.
