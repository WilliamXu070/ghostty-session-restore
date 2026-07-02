#!/usr/bin/env python3
"""Benchmark Newmux/Ghostty tab lifecycle latency with the real app path."""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
NEWMUX = ROOT / "bin" / "newmux"
SOCKET_INFO = ROOT / ".local" / "newmux-ghostty" / "latest" / "socket-path"
STATUS_INFO = ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status-path"


def now() -> float:
    return time.perf_counter()


def run(argv: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    proc = subprocess.run(argv, text=True, capture_output=True, env=merged, check=False)
    if check and proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or f"{argv[0]} exited {proc.returncode}")
    return proc


def socket_path() -> str:
    return SOCKET_INFO.read_text().strip()


def status_path() -> Path:
    value = STATUS_INFO.read_text().strip()
    return Path(value) if value else ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status.json"


def snapshot() -> dict[str, Any]:
    proc = run([
        "python3",
        str(ROOT / "scripts" / "newmux-ui-bridge.py"),
        "snapshot",
        "--socket-name",
        "newmux-dev",
        "--socket-path",
        socket_path(),
    ])
    return json.loads(proc.stdout)


def ghostty_status() -> dict[str, Any]:
    try:
        return json.loads(status_path().read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def visible_windows(state: dict[str, Any]) -> list[dict[str, Any]]:
    return [w for w in state.get("windows", []) if not w.get("internal")]


def active_window(state: dict[str, Any]) -> dict[str, Any]:
    windows = visible_windows(state)
    for window in windows:
        if window.get("active"):
            return window
    if not windows:
        raise RuntimeError("no visible Newmux window")
    return windows[-1]


def active_pane(state: dict[str, Any]) -> dict[str, Any]:
    window_id = active_window(state)["id"]
    panes = [p for p in state.get("panes", []) if p.get("window_id") == window_id]
    for pane in panes:
        if pane.get("active"):
            return pane
    if not panes:
        raise RuntimeError(f"no pane for active window {window_id}")
    return panes[0]


def counts(state: dict[str, Any]) -> dict[str, int]:
    return {
        "windows": len(visible_windows(state)),
        "panes": len([p for p in state.get("panes", []) if not p.get("internal")]),
        "lifo": len(state.get("recovery_stack", [])),
    }


def native_tab_count() -> int | None:
    status = ghostty_status()
    value = status.get("native_tab_count")
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def wait_for(label: str, predicate: Callable[[], bool], timeout: float) -> float:
    start = now()
    deadline = start + timeout
    last_error: Exception | None = None
    while now() < deadline:
        try:
            if predicate():
                return (now() - start) * 1000
        except Exception as exc:
            last_error = exc
        time.sleep(0.02)
    detail = f": {last_error}" if last_error else ""
    raise RuntimeError(f"timed out waiting for {label}{detail}")


def find_ghostty_pid() -> int:
    proc = run(["pgrep", "-f", r"Ghostty[.]app/Contents/MacOS/ghostty .*ghostty-config/newmux[.]config"])
    pids = [int(line) for line in proc.stdout.splitlines() if line.strip().isdigit()]
    if not pids:
        raise RuntimeError("no Newmux Ghostty process found")
    return max(pids)


def focus_pid(pid: int) -> None:
    run([
        "osascript",
        "-e",
        (
            'tell application "System Events"\n'
            f'  set targetProc to first process whose unix id is {pid}\n'
            '  set frontmost of targetProc to true\n'
            '  delay 0.15\n'
            'end tell'
        ),
    ])


def press(pid: int, key_code: int, modifiers: list[str]) -> float:
    mods = ", ".join(modifiers)
    key_script = f"key code {key_code} using {{{mods}}}" if mods else f"key code {key_code}"
    start = now()
    run([
        "osascript",
        "-e",
        (
            'tell application "System Events"\n'
            f'  set targetProc to first process whose unix id is {pid}\n'
            '  set frontmost of targetProc to true\n'
            '  set frontPid to unix id of first process whose frontmost is true\n'
            f'  if frontPid is not {pid} then error "frontmost pid mismatch"\n'
            f'  {key_script}\n'
            'end tell'
        ),
    ])
    return (now() - start) * 1000


def newmux(*args: str) -> str:
    return run([str(NEWMUX), "-S", socket_path(), *args]).stdout


def mark_dirty(pane_id: str) -> None:
    marker = f"NEWMUX_BENCH_DIRTY_{uuid.uuid4().hex[:8]}"
    run([
        "python3",
        str(ROOT / "scripts" / "newmux-runtime.py"),
        "command",
        "--socket-path",
        socket_path(),
        "--pane",
        pane_id,
        "--shell-command",
        marker,
        "--json",
    ])
    newmux("send-keys", "-t", pane_id, f"printf {marker}", "Enter")
    wait_for(
        "dirty marker capture",
        lambda: marker in newmux("capture-pane", "-p", "-J", "-t", pane_id),
        timeout=3,
    )


def launch(timeout: float) -> tuple[int, float]:
    start = now()
    run([str(ROOT / "scripts" / "open-newmux-ghostty.sh")])

    def ready() -> bool:
        state = snapshot()
        attached = sum(
            int(s.get("attached_clients") or 0)
            for s in state.get("sessions", [])
            if not s.get("internal")
        )
        return attached > 0 and len(visible_windows(state)) >= 1

    wait_for("initial attached client", ready, timeout)
    elapsed = (now() - start) * 1000
    pid = find_ghostty_pid()
    focus_pid(pid)
    return pid, elapsed


def pane_for_window(state: dict[str, Any], window_id: str) -> dict[str, Any]:
    panes = [p for p in state.get("panes", []) if p.get("window_id") == window_id]
    for pane in panes:
        if pane.get("active"):
            return pane
    if not panes:
        raise RuntimeError(f"no pane for window {window_id}")
    return panes[0]


def measure_cmd_t(pid: int, timeout: float, *, run_first_command: bool = False) -> dict[str, Any]:
    before = snapshot()
    before_counts = counts(before)
    before_tabs = native_tab_count()
    before_windows = {w["id"] for w in visible_windows(before)}
    send_ms = press(pid, 17, ["command down"])

    def appeared() -> bool:
        state = snapshot()
        status_tabs = native_tab_count()
        ok_backend = counts(state)["windows"] >= before_counts["windows"] + 1
        ok_ui = before_tabs is None or status_tabs is None or status_tabs >= before_tabs + 1
        return ok_backend and ok_ui

    state_ms = wait_for("Cmd+T backend/ui tab", appeared, timeout)
    after = snapshot()
    created = [w for w in visible_windows(after) if w["id"] not in before_windows]
    window = created[0] if created else active_window(after)
    pane = pane_for_window(after, window["id"])
    first_command_ms = None
    if run_first_command:
        marker = f"NEWMUX_BENCH_READY_{uuid.uuid4().hex[:8]}"
        command_start = now()
        newmux("send-keys", "-t", pane["id"], f"printf {marker}", "Enter")
        wait_for(
            "first command marker",
            lambda: marker in newmux("capture-pane", "-p", "-J", "-t", pane["id"]),
            timeout=3,
        )
        first_command_ms = (now() - command_start) * 1000
    return {
        "send_ms": send_ms,
        "visible_ms": state_ms,
        "first_command_ms": first_command_ms,
        "window": window["id"],
        "pane": pane["id"],
    }


def measure_cmd_w(pid: int, timeout: float) -> dict[str, Any]:
    before = snapshot()
    before_counts = counts(before)
    before_tabs = native_tab_count()
    send_ms = press(pid, 13, ["command down"])

    def disappeared() -> bool:
        state = snapshot()
        status_tabs = native_tab_count()
        ok_backend = counts(state)["windows"] <= before_counts["windows"] - 1
        ok_ui = before_tabs is None or status_tabs is None or status_tabs <= before_tabs - 1
        return ok_backend and ok_ui

    state_ms = wait_for("Cmd+W backend/ui tab", disappeared, timeout)
    return {"send_ms": send_ms, "visible_ms": state_ms}


def measure_dirty_delete_recover(pid: int, timeout: float) -> dict[str, Any]:
    new_tab = measure_cmd_t(pid, timeout, run_first_command=True)
    mark_dirty(new_tab["pane"])
    before_delete = snapshot()
    before_counts = counts(before_delete)
    before_tabs = native_tab_count()
    delete_send_ms = press(pid, 13, ["command down"])

    def soft_deleted() -> bool:
        state = snapshot()
        status_tabs = native_tab_count()
        current = counts(state)
        ok_backend = current["windows"] <= before_counts["windows"] - 1 and current["lifo"] >= before_counts["lifo"] + 1
        ok_ui = before_tabs is None or status_tabs is None or status_tabs <= before_tabs - 1
        return ok_backend and ok_ui

    delete_visible_ms = wait_for("dirty Cmd+W soft delete", soft_deleted, timeout)
    before_restore = snapshot()
    before_restore_counts = counts(before_restore)
    before_restore_tabs = native_tab_count()
    restore_send_ms = press(pid, 17, ["command down", "shift down"])

    def restored() -> bool:
        state = snapshot()
        status_tabs = native_tab_count()
        current = counts(state)
        ok_backend = current["windows"] >= before_restore_counts["windows"] + 1
        ok_ui = before_restore_tabs is None or status_tabs is None or status_tabs >= before_restore_tabs + 1
        return ok_backend and ok_ui

    restore_visible_ms = wait_for("Cmd+Shift+T restore", restored, timeout)
    return {
        "new_tab": new_tab,
        "delete_send_ms": delete_send_ms,
        "delete_visible_ms": delete_visible_ms,
        "restore_send_ms": restore_send_ms,
        "restore_visible_ms": restore_visible_ms,
    }


def summarize(values: list[float]) -> dict[str, float]:
    if not values:
        return {}
    ordered = sorted(values)
    return {
        "avg_ms": statistics.fmean(values),
        "p50_ms": statistics.median(ordered),
        "min_ms": min(values),
        "max_ms": max(values),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--passes", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--out", default=str(ROOT / ".local" / "benchmarks" / "newmux-lifecycle-latest.json"))
    args = parser.parse_args()

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    pid, startup_ms = launch(args.timeout)
    runs: list[dict[str, Any]] = []
    for index in range(1, args.passes + 1):
        clean_new = measure_cmd_t(pid, args.timeout)
        clean_delete = measure_cmd_w(pid, args.timeout)
        dirty_cycle = measure_dirty_delete_recover(pid, args.timeout)
        runs.append({
            "pass": index,
            "clean_cmd_t": clean_new,
            "clean_cmd_w": clean_delete,
            "dirty_delete_recover": dirty_cycle,
        })

    result = {
        "schema": "newmux.performance.lifecycle.v1",
        "generated_at": time.time(),
        "startup_ms": startup_ms,
        "runs": runs,
        "summary": {
            "clean_cmd_t_visible": summarize([r["clean_cmd_t"]["visible_ms"] for r in runs]),
            "cmd_t_first_command": summarize([
                r["dirty_delete_recover"]["new_tab"]["first_command_ms"]
                for r in runs
                if r["dirty_delete_recover"]["new_tab"]["first_command_ms"] is not None
            ]),
            "clean_cmd_w_visible": summarize([r["clean_cmd_w"]["visible_ms"] for r in runs]),
            "dirty_cmd_w_visible": summarize([r["dirty_delete_recover"]["delete_visible_ms"] for r in runs]),
            "cmd_shift_t_restore_visible": summarize([r["dirty_delete_recover"]["restore_visible_ms"] for r in runs]),
        },
        "final": {
            "snapshot_counts": counts(snapshot()),
            "native_tab_count": native_tab_count(),
        },
    }
    out_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result["summary"], indent=2, sort_keys=True))
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
