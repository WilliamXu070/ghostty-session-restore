#!/usr/bin/env python3
"""Runtime metadata helpers for Newmux prototype flows."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
NEWMUX = ROOT / "bin" / "newmux"
FIELD_SEP = "\t"
INTERNAL_RECOVERY_SESSION = "__newmux-recovery"


def socket_name(socket_path: str | None, explicit: str | None = None) -> str:
    if explicit:
        return explicit.removesuffix(".sock")
    if socket_path:
        return Path(socket_path).name.removesuffix(".sock")
    return "newmux-dev"


def runtime_dir(socket_path: str | None, explicit_name: str | None = None) -> Path:
    name = socket_name(socket_path, explicit_name)
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "_", name)
    path = ROOT / ".local" / "newmux-runtime" / safe
    path.mkdir(parents=True, exist_ok=True)
    return path


def newmux(socket_path: str | None, socket_name_arg: str, *args: str, check: bool = True) -> str:
    if socket_path:
        argv = [str(NEWMUX), "-S", socket_path, *args]
    else:
        argv = [str(NEWMUX), "-L", socket_name_arg, *args]
    proc = subprocess.run(argv, text=True, capture_output=True, check=False)
    if check and proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout).strip() or f"newmux exited {proc.returncode}")
    return proc.stdout


def normalize_capture(text: str) -> str:
    return "\n".join(line.rstrip() for line in text.splitlines()).strip()


def capture_pane(socket_path: str | None, socket_name_arg: str, pane_id: str) -> str:
    return normalize_capture(
        newmux(socket_path, socket_name_arg, "capture-pane", "-p", "-J", "-t", pane_id, check=False)
    )


def hash_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def parse_newmux_fields(text: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for token in text.split():
        key, sep, value = token.partition("=")
        if sep:
            fields[key] = value
    return fields


def int_field(fields: dict[str, str], key: str) -> int | None:
    try:
        return int(fields[key])
    except (KeyError, TypeError, ValueError):
        return None


def window_id_field(fields: dict[str, str], key: str) -> str | None:
    value = fields.get(key)
    if value is None or value in ("", "none"):
        return None
    return value if value.startswith("@") else f"@{value}"


def prompt_only_after_empty_baseline(baseline: dict[str, Any] | None, line_count: int) -> bool:
    return bool(
        baseline
        and baseline.get("hash") == hash_text("")
        and line_count <= 2
    )


def baseline_path(run_dir: Path) -> Path:
    return run_dir / "pane-baselines.json"


def command_state_path(run_dir: Path) -> Path:
    return run_dir / "pane-commands.json"


def restored_stack_path(run_dir: Path) -> Path:
    return run_dir / "lifo-restored.json"


def order_ledger_path(run_dir: Path) -> Path:
    return run_dir / "window-order.json"


def tab_session_map_path(run_dir: Path) -> Path:
    return run_dir / "native-tab-sessions.json"


@contextlib.contextmanager
def tab_session_map_lock(run_dir: Path):
    lock_path = run_dir / "native-tab-sessions.lock"
    with lock_path.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def read_baselines(run_dir: Path) -> dict[str, Any]:
    try:
        return json.loads(baseline_path(run_dir).read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_baselines(run_dir: Path, baselines: dict[str, Any]) -> None:
    target = baseline_path(run_dir)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(baselines, indent=2, sort_keys=True) + "\n")
    tmp.replace(target)


def read_command_state(run_dir: Path) -> dict[str, Any]:
    try:
        return json.loads(command_state_path(run_dir).read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def write_command_state(run_dir: Path, state: dict[str, Any]) -> None:
    target = command_state_path(run_dir)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    tmp.replace(target)


def read_restored_sequences(run_dir: Path) -> set[int]:
    try:
        data = json.loads(restored_stack_path(run_dir).read_text())
    except (OSError, json.JSONDecodeError):
        return set()
    return {int(item) for item in data if str(item).isdigit()}


def write_restored_sequences(run_dir: Path, restored: set[int]) -> None:
    target = restored_stack_path(run_dir)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(sorted(restored), indent=2) + "\n")
    tmp.replace(target)


def read_order_ledger(run_dir: Path) -> dict[str, Any]:
    try:
        return json.loads(order_ledger_path(run_dir).read_text())
    except (OSError, json.JSONDecodeError):
        return {"workspaces": {}, "updated_at": None}


def write_order_ledger(run_dir: Path, ledger: dict[str, Any]) -> None:
    ledger["updated_at"] = time.time()
    target = order_ledger_path(run_dir)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n")
    tmp.replace(target)


def read_tab_session_map(run_dir: Path) -> dict[str, str]:
    try:
        data = json.loads(tab_session_map_path(run_dir).read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return {
        str(session): str(window)
        for session, window in data.items()
        if str(session) and str(window).startswith("@")
    }


def write_tab_session_map(run_dir: Path, mapping: dict[str, str]) -> None:
    target = tab_session_map_path(run_dir)
    tmp = target.with_name(f"{target.name}.{os.getpid()}.tmp")
    tmp.write_text(json.dumps(mapping, indent=2, sort_keys=True) + "\n")
    tmp.replace(target)


def kill_native_tab_session(socket_path: str | None, socket_name_arg: str, session: str) -> bool:
    if not session.startswith("newmux-tab-"):
        return False
    newmux(socket_path, socket_name_arg, "kill-session", "-t", session, check=False)
    return True


def restore_tab_session_windows(
    socket_path: str | None,
    socket_name_arg: str,
    run_dir: Path,
) -> dict[str, Any]:
    with tab_session_map_lock(run_dir):
        mapping = read_tab_session_map(run_dir)
        kept: dict[str, str] = {}
        restored: list[dict[str, str]] = []
        dropped: list[dict[str, str]] = []
        for session, window_id in mapping.items():
            exists = bool(
                newmux(
                    socket_path,
                    socket_name_arg,
                    "display-message",
                    "-p",
                    "-t",
                    session,
                    "#{session_name}",
                    check=False,
                ).strip()
            )
            if not exists:
                dropped.append({"session": session, "window": window_id})
                continue
            windows = {row["window"] for row in session_windows(socket_path, socket_name_arg, session)}
            if window_id not in windows:
                kill_native_tab_session(socket_path, socket_name_arg, session)
                dropped.append({"session": session, "window": window_id})
                continue
            newmux(socket_path, socket_name_arg, "select-window", "-t", f"{session}:{window_id}", check=False)
            restored.append({"session": session, "window": window_id})
            kept[session] = window_id
        if kept != mapping:
            write_tab_session_map(run_dir, kept)
    return {"restored": restored, "dropped": dropped}


def read_lifo_items(run_dir: Path, *, include_restored: bool = False) -> list[dict[str, Any]]:
    restored = read_restored_sequences(run_dir)
    items = []
    try:
        lines = (run_dir / "lifo.jsonl").read_text().splitlines()
    except OSError:
        return []
    for line in lines:
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except json.JSONDecodeError:
            continue
        sequence = int(item.get("sequence") or 0)
        if sequence in restored:
            item["restored"] = True
            if not include_restored:
                continue
        items.append(item)
    return items


def append_lifo_item_if_missing(run_dir: Path, item: dict[str, Any]) -> bool:
    sequence = int(item.get("sequence") or 0)
    if sequence <= 0:
        return False
    for existing in read_lifo_items(run_dir, include_restored=True):
        if int(existing.get("sequence") or 0) == sequence:
            return False
    append_jsonl(run_dir / "lifo.jsonl", item)
    return True


def session_windows(socket_path: str | None, socket_name_arg: str, session: str) -> list[dict[str, Any]]:
    fmt = FIELD_SEP.join(
        [
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{window_active}",
        ]
    )
    rows = []
    out = newmux(socket_path, socket_name_arg, "list-windows", "-t", session, "-F", fmt, check=False)
    for line in out.splitlines():
        fields = line.split(FIELD_SEP)
        if len(fields) < 4:
            continue
        wid, index, name, active = fields[:4]
        rows.append(
            {
                "window": wid,
                "index": int(index or "0"),
                "name": name,
                "active": active == "1",
            }
        )
    return sorted(rows, key=lambda row: row["index"])


def window_index(
    socket_path: str | None,
    socket_name_arg: str,
    session: str,
    window_id: str,
) -> int | None:
    for row in session_windows(socket_path, socket_name_arg, session):
        if row["window"] == window_id:
            return row["index"]
    return None


def window_position(
    socket_path: str | None,
    socket_name_arg: str,
    session: str,
    window_id: str,
) -> int | None:
    for position, row in enumerate(session_windows(socket_path, socket_name_arg, session)):
        if row["window"] == window_id:
            return position
    return None


def sync_workspace_order(
    socket_path: str | None,
    socket_name_arg: str,
    run_dir: Path,
    workspace: str,
) -> dict[str, Any]:
    rows = session_windows(socket_path, socket_name_arg, workspace)
    ledger = read_order_ledger(run_dir)
    workspaces = ledger.setdefault("workspaces", {})
    prior = workspaces.get(workspace, {})
    known = dict(prior.get("known", {}))
    for row in rows:
        known[row["window"]] = {
            "window": row["window"],
            "name": row["name"],
            "last_index": row["index"],
            "last_seen_at": time.time(),
        }
    workspaces[workspace] = {
        **prior,
        "order": [row["window"] for row in rows],
        "known": known,
        "active_window": next((row["window"] for row in rows if row["active"]), None),
    }
    write_order_ledger(run_dir, ledger)
    return workspaces[workspace]


def live_order_context(rows: list[dict[str, Any]], window_id: str) -> dict[str, Any]:
    order = [row["window"] for row in rows]
    try:
        original_index = order.index(window_id)
    except ValueError:
        original_index = None
    left = order[original_index - 1] if original_index is not None and original_index > 0 else None
    right = (
        order[original_index + 1]
        if original_index is not None and original_index + 1 < len(order)
        else None
    )
    names = {row["window"]: row["name"] for row in rows}
    return {
        "order": order,
        "names": names,
        "original_index": original_index,
        "left_neighbor": left,
        "right_neighbor": right,
    }


def link_window_at_region(
    socket_path: str | None,
    socket_name_arg: str,
    primary_session: str,
    window_id: str,
    item: dict[str, Any],
) -> str:
    rows = session_windows(socket_path, socket_name_arg, primary_session)
    by_id = {row["window"]: row for row in rows}
    left = item.get("left_neighbor")
    right = item.get("right_neighbor")
    original_index = item.get("original_index")
    max_index = max((row["index"] for row in rows), default=-1)

    if left in by_id:
        newmux(
            socket_path,
            socket_name_arg,
            "link-window",
            "-d",
            "-a",
            "-s",
            window_id,
            "-t",
            f"{primary_session}:{by_id[left]['index']}",
        )
        return "after_left_neighbor"

    if right in by_id:
        newmux(
            socket_path,
            socket_name_arg,
            "link-window",
            "-d",
            "-b",
            "-s",
            window_id,
            "-t",
            f"{primary_session}:{by_id[right]['index']}",
        )
        return "before_right_neighbor"

    if isinstance(original_index, int):
        index = min(max(original_index, 0), max_index + 1)
        try:
            newmux(
                socket_path,
                socket_name_arg,
                "link-window",
                "-d",
                "-s",
                window_id,
                "-t",
                f"{primary_session}:{index}",
            )
            return "original_index"
        except RuntimeError:
            pass

    newmux(
        socket_path,
        socket_name_arg,
        "link-window",
        "-d",
        "-s",
        window_id,
        "-t",
        f"{primary_session}:",
    )
    return "append"


def append_jsonl(path: Path, event: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as file:
        file.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")


def runtime_event(run_dir: Path, event_type: str, **fields: Any) -> dict[str, Any]:
    event = {
        "type": event_type,
        "time": time.time(),
        **fields,
    }
    append_jsonl(run_dir / "events.jsonl", event)
    return event


def pane_rows(socket_path: str | None, socket_name_arg: str, target: str) -> list[dict[str, Any]]:
    fmt = FIELD_SEP.join(
        [
            "#{session_id}",
            "#{session_name}",
            "#{session_group}",
            "#{window_id}",
            "#{window_index}",
            "#{pane_id}",
            "#{pane_index}",
            "#{pane_current_path}",
            "#{pane_current_command}",
            "#{pane_pid}",
            "#{pane_active}",
        ]
    )
    rows = []
    out = newmux(socket_path, socket_name_arg, "list-panes", "-t", target, "-F", fmt)
    for line in out.splitlines():
        fields = line.split(FIELD_SEP)
        if len(fields) < 10:
            continue
        sid, session, group, window, window_index, pane, pane_index, path, command, pid = fields[:10]
        active = fields[10] if len(fields) > 10 else "0"
        rows.append(
            {
                "session_id": sid,
                "session": session,
                "group": group or None,
                "window": window,
                "window_index": int(window_index or "0"),
                "pane": pane,
                "pane_index": int(pane_index or "0"),
                "path": path,
                "command": command,
                "pid": int(pid or "0"),
                "active": active == "1",
            }
        )
    return rows


def active_pane_row(rows: list[dict[str, Any]]) -> dict[str, Any]:
    return next((row for row in rows if row.get("active")), rows[0])


def window_links(socket_path: str | None, socket_name_arg: str, window_id: str) -> list[dict[str, Any]]:
    fmt = FIELD_SEP.join(
        [
            "#{session_id}",
            "#{session_name}",
            "#{session_group}",
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{window_active}",
        ]
    )
    rows = []
    out = newmux(socket_path, socket_name_arg, "list-windows", "-a", "-F", fmt)
    for line in out.splitlines():
        fields = line.split(FIELD_SEP)
        if len(fields) < 7:
            continue
        sid, session, group, wid, index, name, active = fields[:7]
        if wid != window_id:
            continue
        rows.append(
            {
                "session_id": sid,
                "session": session,
                "group": group or None,
                "window": wid,
                "window_index": int(index or "0"),
                "window_name": name,
                "active": active == "1",
                "internal": session == INTERNAL_RECOVERY_SESSION,
            }
        )
    return rows


def ensure_recovery_session(socket_path: str | None, socket_name_arg: str) -> None:
    newmux(
        socket_path,
        socket_name_arg,
        "new-session",
        "-d",
        "-s",
        INTERNAL_RECOVERY_SESSION,
        "-n",
        "__holder",
        check=False,
    )


def soft_hide_window(socket_path: str | None, socket_name_arg: str, run_dir: Path, window_id: str) -> list[dict[str, Any]]:
    ensure_recovery_session(socket_path, socket_name_arg)
    before = window_links(socket_path, socket_name_arg, window_id)
    linked_to_recovery = any(link["internal"] for link in before)
    if not linked_to_recovery:
        newmux(
            socket_path,
            socket_name_arg,
            "link-window",
            "-d",
            "-s",
            window_id,
            "-t",
            f"{INTERNAL_RECOVERY_SESSION}:",
        )

    active_links = [
        link for link in window_links(socket_path, socket_name_arg, window_id)
        if not link["internal"]
    ]
    for link in active_links:
        newmux(
            socket_path,
            socket_name_arg,
            "unlink-window",
            "-t",
            f"{link['session']}:{link['window_index']}",
            check=False,
        )
        runtime_event(
            run_dir,
            "window.soft_hide.unlink",
            session=link["session"],
            window=window_id,
        )
    remaining = [
        link for link in window_links(socket_path, socket_name_arg, window_id)
        if not link["internal"]
    ]
    if remaining:
        raise RuntimeError(f"window still visible after soft hide: {remaining}")
    return before


def pane_status(
    socket_path: str | None,
    socket_name_arg: str,
    run_dir: Path,
    pane_id: str,
) -> dict[str, Any]:
    baselines = read_baselines(run_dir)
    commands = read_command_state(run_dir)
    current = capture_pane(socket_path, socket_name_arg, pane_id)
    current_hash = hash_text(current)
    baseline = baselines.get(pane_id)
    command_state = commands.get(pane_id, {})
    command_count = int(command_state.get("command_count") or 0)
    dirty = command_count > 0
    reason = "command_entered" if dirty else "no_command_entered"
    return {
        "pane": pane_id,
        "dirty": dirty,
        "reason": reason,
        "hash": current_hash,
        "baseline_hash": baseline.get("hash") if baseline else None,
        "line_count": len([line for line in current.splitlines() if line.strip()]),
        "command_count": command_count,
        "last_command": command_state.get("last_command"),
        "last_command_at": command_state.get("last_command_at"),
    }


def mark_target(
    socket_path: str | None,
    socket_name_arg: str,
    run_dir: Path,
    target: str,
    workspace: str,
) -> list[str]:
    baselines = read_baselines(run_dir)
    commands = read_command_state(run_dir)
    rows = pane_rows(socket_path, socket_name_arg, target)
    capture_baseline = os.environ.get("NEWMUX_MARK_CAPTURE_BASELINE") not in (None, "", "0")
    for row in rows:
        capture = (
            capture_pane(socket_path, socket_name_arg, row["pane"])
            if capture_baseline
            else ""
        )
        baselines[row["pane"]] = {
            **row,
            "hash": hash_text(capture),
            "capture_skipped": not capture_baseline,
            "marked_at": time.time(),
        }
        previous = commands.get(row["pane"], {})
        previous_count = int(previous.get("command_count") or 0)
        commands[row["pane"]] = {
            **previous,
            "command_count": previous_count,
            "dirty": previous_count > 0,
            "marked_at": time.time(),
        }
        runtime_event(run_dir, "pane.baseline", **baselines[row["pane"]])
    write_baselines(run_dir, baselines)
    write_command_state(run_dir, commands)
    sync_workspace_order(
        socket_path,
        socket_name_arg,
        run_dir,
        workspace,
    )
    return [row["pane"] for row in rows]


def mark_panes(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    marked = mark_target(
        args.socket_path,
        socket_name(args.socket_path, args.socket_name),
        run_dir,
        args.target,
        args.workspace,
    )
    print(json.dumps({"ok": True, "marked": marked}, sort_keys=True))
    return 0


def cwd_from_target(
    socket_path: str | None,
    socket_name_arg: str,
    target: str | None,
) -> str | None:
    if not target:
        return None
    try:
        rows = pane_rows(socket_path, socket_name_arg, target)
    except RuntimeError:
        return None
    if not rows:
        return None
    return str(active_pane_row(rows).get("path") or "") or None


def create_window(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    out = newmux(
        args.socket_path,
        socket_name_arg,
        "newmux-create-window",
        "-P",
        "-s",
        args.primary_session,
        "-t",
        args.target or f"{args.primary_session}:",
    )
    fields = parse_newmux_fields(out)
    window_id = fields.get("window") or fields.get("window_id") or ""
    if not window_id:
        raise RuntimeError(f"newmux-create-window did not return a window: {out.strip()}")
    marked = mark_target(args.socket_path, socket_name_arg, run_dir, window_id, args.primary_session)
    target_index = int_field(fields, "target_index")
    if target_index is None:
        target_index = window_position(args.socket_path, socket_name_arg, args.primary_session, window_id)
    runtime_event(
        run_dir,
        "window.create",
        window=window_id,
        target=args.target,
        target_index=target_index,
        marked=marked,
    )
    print(
        json.dumps(
            {
                "ok": True,
                "window": window_id,
                "target_index": target_index,
                "marked": marked,
            },
            sort_keys=True,
        )
    )
    return 0


def command_entered(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    commands = read_command_state(run_dir)
    pane = args.pane
    previous = commands.get(pane, {})
    command_count = int(previous.get("command_count") or 0) + 1
    commands[pane] = {
        **previous,
        "command_count": command_count,
        "dirty": True,
        "last_command": args.shell_command,
        "last_command_at": time.time(),
    }
    write_command_state(run_dir, commands)
    newmux(args.socket_path, socket_name_arg, "set-option", "-p", "-q", "-t", pane, "@newmux-dirty", "1")
    runtime_event(
        run_dir,
        "pane.command_entered",
        pane=pane,
        command_count=command_count,
        shell_command=args.shell_command,
    )
    if args.json:
        print(json.dumps({"ok": True, "pane": pane, "command_count": command_count}, sort_keys=True))
    return 0


def status(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    rows = pane_rows(args.socket_path, socket_name_arg, args.target)
    result = {
        "ok": True,
        "target": args.target,
        "panes": [
            {**row, **pane_status(args.socket_path, socket_name_arg, run_dir, row["pane"])}
            for row in rows
        ],
    }
    result["dirty"] = any(pane["dirty"] for pane in result["panes"])
    print(json.dumps(result, sort_keys=True))
    return 0


def delete(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    target_row = pane_rows(args.socket_path, socket_name_arg, args.target_pane)[0]
    window_id = target_row["window"]
    workspace = target_row.get("group") or args.primary_session
    order_rows = session_windows(args.socket_path, socket_name_arg, workspace)
    order_context = live_order_context(order_rows, window_id)
    sync_workspace_order(args.socket_path, socket_name_arg, run_dir, workspace)
    rows = pane_rows(args.socket_path, socket_name_arg, window_id)
    pane_states = [
        {**row, **pane_status(args.socket_path, socket_name_arg, run_dir, row["pane"])}
        for row in rows
    ]
    out = newmux(
        args.socket_path,
        socket_name_arg,
        "newmux-delete-window",
        "-P",
        "-s",
        args.primary_session,
        "-t",
        window_id,
    )
    fields = parse_newmux_fields(out)
    mode = fields.get("mode") or "hard"
    event = runtime_event(
        run_dir,
        "window.delete.request",
        mode=mode,
        window=window_id,
        target_pane=args.target_pane,
        panes=pane_states,
    )
    if mode == "soft":
        sequence = int_field(fields, "sequence")
        if sequence is None:
            raise RuntimeError(f"newmux-delete-window did not return a sequence: {out.strip()}")
        original_index = int_field(fields, "target_position")
        if original_index is None:
            original_index = int_field(fields, "target_index")
        if original_index is None:
            original_index = order_context["original_index"]
        left_neighbor = (
            window_id_field(fields, "left_window_id")
            if "left_window_id" in fields
            else order_context["left_neighbor"]
        )
        right_neighbor = (
            window_id_field(fields, "right_window_id")
            if "right_window_id" in fields
            else order_context["right_neighbor"]
        )
        item = {
            "sequence": sequence,
            "kind": "window",
            "window": fields.get("window") or fields.get("window_id") or window_id,
            "workspace": workspace,
            "original_index": original_index,
            "left_neighbor": left_neighbor,
            "right_neighbor": right_neighbor,
            "order_before_delete": order_context["order"],
            "names_before_delete": order_context["names"],
            "target_pane": args.target_pane,
            "deleted_at": time.time(),
            "mode": mode,
            "panes": pane_states,
        }
        append_lifo_item_if_missing(run_dir, item)
        runtime_event(run_dir, "lifo.push", **item)
        sync_workspace_order(args.socket_path, socket_name_arg, run_dir, workspace)
    else:
        runtime_event(run_dir, "window.hard_delete", window=window_id, reason="clean")
        sync_workspace_order(args.socket_path, socket_name_arg, run_dir, workspace)

    if args.json:
        print(json.dumps({"ok": True, "mode": mode, "window": window_id, "event_time": event["time"]}, sort_keys=True))
    return 0


def delete_window(args: argparse.Namespace) -> int:
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    rows = pane_rows(args.socket_path, socket_name_arg, args.target_window)
    if not rows:
        raise RuntimeError(f"no panes found for window {args.target_window}")
    args.target_pane = active_pane_row(rows)["pane"]
    return delete(args)


def stack(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    items = read_lifo_items(run_dir, include_restored=args.include_restored)
    print(json.dumps({"ok": True, "items": items, "count": len(items)}, sort_keys=True))
    return 0


def restore_latest(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    restored = read_restored_sequences(run_dir)
    out = newmux(
        args.socket_path,
        socket_name_arg,
        "newmux-reopen-latest-closed",
        "-P",
        "-t",
        f"{args.primary_session}:",
    )
    fields = parse_newmux_fields(out)
    if fields.get("restored") == "0" or not (fields.get("window") or fields.get("window_id")):
        if args.json:
            print(json.dumps({"ok": True, "restored": False, "reason": "empty_stack"}, sort_keys=True))
        return 0

    window_id = fields.get("window") or fields.get("window_id") or ""
    sync_workspace_order(args.socket_path, socket_name_arg, run_dir, args.primary_session)
    target_index = int_field(fields, "target_index")
    if target_index is None:
        target_index = window_position(args.socket_path, socket_name_arg, args.primary_session, window_id)
    tab_restore = restore_tab_session_windows(args.socket_path, socket_name_arg, run_dir)
    sequence = int_field(fields, "sequence")
    if sequence is not None:
        restored.add(sequence)
    write_restored_sequences(run_dir, restored)
    runtime_event(
        run_dir,
        "lifo.restore",
        sequence=sequence,
        window=window_id,
        primary_session=args.primary_session,
        target_index=target_index,
        tab_session_restore=tab_restore,
    )
    result = {
        "ok": True,
        "restored": True,
        "sequence": sequence,
        "window": window_id,
        "target_index": target_index,
    }
    if args.json:
        print(json.dumps(result, sort_keys=True))
    return 0


def remember_tab_session(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    with tab_session_map_lock(run_dir):
        mapping = read_tab_session_map(run_dir)
        mapping[args.tab_session] = args.window_id
        write_tab_session_map(run_dir, mapping)
    runtime_event(
        run_dir,
        "native_tab_session.remember",
        session=args.tab_session,
        window=args.window_id,
    )
    if args.json:
        print(json.dumps({"ok": True, "session": args.tab_session, "window": args.window_id}, sort_keys=True))
    return 0


def forget_tab_window(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    socket_name_arg = socket_name(args.socket_path, args.socket_name)
    with tab_session_map_lock(run_dir):
        mapping = read_tab_session_map(run_dir)
        kept: dict[str, str] = {}
        forgotten: list[dict[str, str]] = []
        pruned: list[dict[str, str]] = []

        for session, window_id in mapping.items():
            if window_id == args.target_window:
                kill_native_tab_session(args.socket_path, socket_name_arg, session)
                forgotten.append({"session": session, "window": window_id})
                continue

            exists = bool(
                newmux(
                    args.socket_path,
                    socket_name_arg,
                    "display-message",
                    "-p",
                    "-t",
                    session,
                    "#{session_name}",
                    check=False,
                ).strip()
            )
            if not exists:
                pruned.append({"session": session, "window": window_id})
                continue

            windows = {row["window"] for row in session_windows(args.socket_path, socket_name_arg, session)}
            if window_id not in windows:
                kill_native_tab_session(args.socket_path, socket_name_arg, session)
                pruned.append({"session": session, "window": window_id})
                continue

            kept[session] = window_id

        if kept != mapping:
            write_tab_session_map(run_dir, kept)
    runtime_event(run_dir, "native_tab_session.forget", forgotten=forgotten, pruned=pruned)
    if args.json:
        print(json.dumps({"ok": True, "forgotten": forgotten, "pruned": pruned}, sort_keys=True))
    return 0


def restore_tab_sessions(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    result = restore_tab_session_windows(
        args.socket_path,
        socket_name(args.socket_path, args.socket_name),
        run_dir,
    )
    runtime_event(run_dir, "native_tab_session.restore", **result)
    if args.json:
        print(json.dumps({"ok": True, **result}, sort_keys=True))
    return 0


def mirror_native_delete(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    sequence = int(args.sequence)
    target_index = int(args.target_index) if args.target_index is not None else None
    left_neighbor = None if args.left_neighbor in (None, "", "none") else args.left_neighbor
    right_neighbor = None if args.right_neighbor in (None, "", "none") else args.right_neighbor
    item = {
        "sequence": sequence,
        "kind": "window",
        "window": args.target_window,
        "workspace": args.primary_session,
        "original_index": target_index,
        "left_neighbor": left_neighbor,
        "right_neighbor": right_neighbor,
        "order_before_delete": [],
        "names_before_delete": {},
        "target_pane": None,
        "deleted_at": time.time(),
        "mode": args.mode,
        "panes": [],
        "native_mirror": True,
    }
    appended = append_lifo_item_if_missing(run_dir, item)
    runtime_event(run_dir, "lifo.native_mirror_delete", appended=appended, **item)
    return 0


def mirror_native_restore(args: argparse.Namespace) -> int:
    run_dir = runtime_dir(args.socket_path, args.socket_name)
    restored = read_restored_sequences(run_dir)
    restored.add(int(args.sequence))
    write_restored_sequences(run_dir, restored)
    runtime_event(run_dir, "lifo.native_mirror_restore", sequence=int(args.sequence))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    def add_common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--socket-path")
        p.add_argument("--socket-name", default=None)

    mark_parser = subparsers.add_parser("mark")
    add_common(mark_parser)
    mark_parser.add_argument("--target", required=True)
    mark_parser.add_argument("--workspace", default="newmux")
    mark_parser.set_defaults(func=mark_panes)

    create_parser = subparsers.add_parser("create-window")
    add_common(create_parser)
    create_parser.add_argument("--primary-session", default="newmux")
    create_parser.add_argument("--target")
    create_parser.set_defaults(func=create_window)

    command_parser = subparsers.add_parser("command")
    add_common(command_parser)
    command_parser.add_argument("--pane", required=True)
    command_parser.add_argument("--shell-command", default="")
    command_parser.add_argument("--json", action="store_true")
    command_parser.set_defaults(func=command_entered)

    status_parser = subparsers.add_parser("status")
    add_common(status_parser)
    status_parser.add_argument("--target", required=True)
    status_parser.set_defaults(func=status)

    delete_parser = subparsers.add_parser("delete")
    add_common(delete_parser)
    delete_parser.add_argument("--target-pane", required=True)
    delete_parser.add_argument("--primary-session", default="newmux")
    delete_parser.add_argument("--json", action="store_true")
    delete_parser.set_defaults(func=delete)

    delete_window_parser = subparsers.add_parser("delete-window")
    add_common(delete_window_parser)
    delete_window_parser.add_argument("--target-window", required=True)
    delete_window_parser.add_argument("--primary-session", default="newmux")
    delete_window_parser.add_argument("--json", action="store_true")
    delete_window_parser.set_defaults(func=delete_window)

    stack_parser = subparsers.add_parser("stack")
    add_common(stack_parser)
    stack_parser.add_argument("--include-restored", action="store_true")
    stack_parser.set_defaults(func=stack)

    restore_parser = subparsers.add_parser("restore-latest")
    add_common(restore_parser)
    restore_parser.add_argument("--primary-session", default="newmux")
    restore_parser.add_argument("--json", action="store_true")
    restore_parser.set_defaults(func=restore_latest)

    remember_parser = subparsers.add_parser("remember-tab-session")
    add_common(remember_parser)
    remember_parser.add_argument("--tab-session", required=True)
    remember_parser.add_argument("--window-id", required=True)
    remember_parser.add_argument("--json", action="store_true")
    remember_parser.set_defaults(func=remember_tab_session)

    forget_parser = subparsers.add_parser("forget-tab-window")
    add_common(forget_parser)
    forget_parser.add_argument("--target-window", required=True)
    forget_parser.add_argument("--json", action="store_true")
    forget_parser.set_defaults(func=forget_tab_window)

    restore_tabs_parser = subparsers.add_parser("restore-tab-sessions")
    add_common(restore_tabs_parser)
    restore_tabs_parser.add_argument("--json", action="store_true")
    restore_tabs_parser.set_defaults(func=restore_tab_sessions)

    mirror_delete_parser = subparsers.add_parser("mirror-native-delete")
    add_common(mirror_delete_parser)
    mirror_delete_parser.add_argument("--primary-session", default="newmux")
    mirror_delete_parser.add_argument("--target-window", required=True)
    mirror_delete_parser.add_argument("--sequence", required=True)
    mirror_delete_parser.add_argument("--mode", default="soft")
    mirror_delete_parser.add_argument("--target-index")
    mirror_delete_parser.add_argument("--left-neighbor")
    mirror_delete_parser.add_argument("--right-neighbor")
    mirror_delete_parser.set_defaults(func=mirror_native_delete)

    mirror_restore_parser = subparsers.add_parser("mirror-native-restore")
    add_common(mirror_restore_parser)
    mirror_restore_parser.add_argument("--sequence", required=True)
    mirror_restore_parser.set_defaults(func=mirror_native_restore)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
