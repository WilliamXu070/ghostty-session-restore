#!/usr/bin/env python3
"""Newmux UI bridge prototype.

This sidecar exposes Newmux/tmux state over a small JSON-lines Unix socket
protocol. It is deliberately outside the tmux server for now so the bridge
contract can be tested before moving it into C.
"""

from __future__ import annotations

import argparse
import curses
import hashlib
import json
import os
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
NEWMUX = ROOT / "bin" / "newmux"
FIELD_SEP = "\t"
INTERNAL_SESSION = "__newmux-recovery"
NEW_WINDOW_HIGHLIGHT_SECONDS = 1.2
LATEST_STATUS_FILE = ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status-path"


class NewmuxError(RuntimeError):
    pass


def _hash_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()[:16]


def _prompt_only_after_empty_baseline(baseline: dict[str, Any] | None, line_count: int) -> bool:
    return bool(
        baseline
        and baseline.get("hash") == _hash_text("")
        and line_count <= 2
    )


class Newmux:
    def __init__(self, socket_name: str, socket_path: str | None = None):
        self.socket_name = socket_name
        self.socket_path = socket_path or os.environ.get("NEWMUX_SOCKET_PATH") or self._latest_socket_path()

    def _latest_socket_path(self) -> str | None:
        path_file = ROOT / ".local" / "newmux-ghostty" / "latest" / "socket-path"
        try:
            socket_path = path_file.read_text().strip()
        except OSError:
            return None
        return socket_path or None

    def _runtime_dir(self) -> Path:
        name = self.socket_name
        if self.socket_path:
            name = Path(self.socket_path).name.removesuffix(".sock")
        safe = "".join(ch if ch.isalnum() or ch in "_.-" else "_" for ch in name)
        path = ROOT / ".local" / "newmux-runtime" / safe
        path.mkdir(parents=True, exist_ok=True)
        return path

    def _runtime_baselines(self) -> dict[str, Any]:
        try:
            return json.loads((self._runtime_dir() / "pane-baselines.json").read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def _runtime_command_state(self) -> dict[str, Any]:
        try:
            return json.loads((self._runtime_dir() / "pane-commands.json").read_text())
        except (OSError, json.JSONDecodeError):
            return {}

    def _pane_capture_hash(self, pane_id: str) -> tuple[str, int]:
        out = self.run("capture-pane", "-p", "-J", "-t", pane_id, check=False)
        normalized = "\n".join(line.rstrip() for line in out.splitlines()).strip()
        nonempty = len([line for line in normalized.splitlines() if line.strip()])
        return _hash_text(normalized), nonempty

    def run(self, *args: str, check: bool = True) -> str:
        if self.socket_path:
            argv = [str(NEWMUX), "-S", self.socket_path, *args]
        else:
            argv = [str(NEWMUX), "-L", self.socket_name, *args]
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if check and proc.returncode != 0:
            detail = proc.stderr.strip() or proc.stdout.strip()
            raise NewmuxError(detail or f"newmux exited {proc.returncode}")
        return proc.stdout

    def rows(self, *args: str) -> list[list[str]]:
        out = self.run(*args)
        rows: list[list[str]] = []
        for line in out.splitlines():
            rows.append(line.split(FIELD_SEP))
        return rows

    def snapshot(self) -> dict[str, Any]:
        sessions = self._sessions()
        windows = self._windows()
        panes = self._panes()
        self._add_runtime_status(panes)
        recovery_stack = self._recovery_stack()

        state = {
            "type": "snapshot",
            "schema": "newmux.ui.snapshot.v1",
            "socket_name": self.socket_name,
            "generated_at": time.time(),
            "sessions": sessions,
            "windows": windows,
            "panes": panes,
            "recovery_stack": recovery_stack,
        }
        state["revision"] = self._revision(state)
        return state

    def _add_runtime_status(self, panes: list[dict[str, Any]]) -> None:
        baselines = self._runtime_baselines()
        commands = self._runtime_command_state()
        seen: set[str] = set()
        for pane in panes:
            pane_id = pane["id"]
            if pane_id in seen:
                command_state = commands.get(pane_id, {})
                command_count = int(command_state.get("command_count") or 0)
                pane["dirty"] = command_count > 0
                pane["dirty_reason"] = "command_entered" if command_count > 0 else "no_command_entered"
                pane["command_count"] = command_count
                pane["last_command"] = command_state.get("last_command")
                continue
            seen.add(pane_id)
            baseline = baselines.get(pane_id)
            current_hash, line_count = self._pane_capture_hash(pane_id)
            command_state = commands.get(pane_id, {})
            command_count = int(command_state.get("command_count") or 0)
            dirty = command_count > 0
            reason = "command_entered" if dirty else "no_command_entered"
            if baseline is not None:
                baseline["dirty"] = dirty
                baseline["dirty_reason"] = reason
            pane["dirty"] = dirty
            pane["dirty_reason"] = reason
            pane["command_count"] = command_count
            pane["last_command"] = command_state.get("last_command")
            pane["capture_hash"] = current_hash
            pane["capture_line_count"] = line_count

    def _revision(self, state: dict[str, Any]) -> str:
        stable = {
            "sessions": state["sessions"],
            "windows": state["windows"],
            "panes": state["panes"],
            "recovery_stack": state["recovery_stack"],
        }
        encoded = json.dumps(stable, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(encoded.encode()).hexdigest()[:16]

    def _sessions(self) -> list[dict[str, Any]]:
        fmt = FIELD_SEP.join(
            [
                "#{session_id}",
                "#{session_name}",
                "#{session_group}",
                "#{session_attached}",
                "#{session_windows}",
                "#{window_id}",
                "#{window_index}",
                "#{window_name}",
            ]
        )
        sessions = []
        for row in self.rows("list-sessions", "-F", fmt):
            if len(row) < 8:
                continue
            sid, name, group, attached, window_count, cur_id, cur_idx, cur_name = row[:8]
            sessions.append(
                {
                    "id": sid,
                    "name": name,
                    "group": group or None,
                    "attached_clients": int(attached or "0"),
                    "window_count": int(window_count or "0"),
                    "current_window_id": cur_id or None,
                    "current_window_index": int(cur_idx or "0"),
                    "current_window_name": cur_name,
                    "internal": name == INTERNAL_SESSION,
                }
            )
        return sessions

    def _windows(self) -> list[dict[str, Any]]:
        fmt = FIELD_SEP.join(
            [
                "#{session_id}",
                "#{session_name}",
                "#{session_group}",
                "#{window_id}",
                "#{window_index}",
                "#{window_name}",
                "#{window_active}",
                "#{window_panes}",
                "#{window_layout}",
            ]
        )
        windows = []
        for row in self.rows("list-windows", "-a", "-F", fmt):
            if len(row) < 9:
                continue
            sid, sname, group, wid, idx, name, active, panes, layout = row[:9]
            windows.append(
                {
                    "id": wid,
                    "session_id": sid,
                    "session_name": sname,
                    "session_group": group or None,
                    "index": int(idx or "0"),
                    "name": name,
                    "active": active == "1",
                    "pane_count": int(panes or "0"),
                    "layout": layout,
                    "internal": sname == INTERNAL_SESSION,
                }
            )
        return windows

    def _panes(self) -> list[dict[str, Any]]:
        fmt = FIELD_SEP.join(
            [
                "#{session_id}",
                "#{session_name}",
                "#{window_id}",
                "#{window_index}",
                "#{pane_id}",
                "#{pane_index}",
                "#{pane_active}",
                "#{pane_current_path}",
                "#{pane_current_command}",
                "#{pane_pid}",
                "#{pane_width}",
                "#{pane_height}",
            ]
        )
        panes = []
        for row in self.rows("list-panes", "-a", "-F", fmt):
            if len(row) < 12:
                continue
            (
                sid,
                sname,
                wid,
                widx,
                pid,
                pidx,
                active,
                path,
                command,
                process_id,
                width,
                height,
            ) = row[:12]
            panes.append(
                {
                    "id": pid,
                    "session_id": sid,
                    "session_name": sname,
                    "window_id": wid,
                    "window_index": int(widx or "0"),
                    "index": int(pidx or "0"),
                    "active": active == "1",
                    "current_path": path,
                    "current_command": command,
                    "process_id": int(process_id or "0"),
                    "width": int(width or "0"),
                    "height": int(height or "0"),
                    "internal": sname == INTERNAL_SESSION,
                }
            )
        return panes

    def _recovery_stack(self) -> list[dict[str, Any]]:
        try:
            restored_data = json.loads((self._runtime_dir() / "lifo-restored.json").read_text())
            restored = {int(item) for item in restored_data if str(item).isdigit()}
        except (OSError, json.JSONDecodeError):
            restored = set()
        items = []
        try:
            lines = (self._runtime_dir() / "lifo.jsonl").read_text().splitlines()
        except OSError:
            return []
        for line in lines:
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            if int(item.get("sequence") or 0) in restored:
                continue
            items.append(item)
        return list(reversed(items))

    def command(self, request: dict[str, Any]) -> dict[str, Any]:
        command = request.get("command")
        if command == "new_window":
            return self._command_new_window(request)
        if command == "select_window":
            target = _required(request, "target")
            self.run("select-window", "-t", str(target))
            return {"ok": True, "command": command}
        if command == "rename_window":
            target = _required(request, "target")
            name = _required(request, "name")
            self.run("rename-window", "-t", str(target), str(name))
            return {"ok": True, "command": command}
        if command == "split_window":
            target = _required(request, "target")
            self.run("split-window", "-d", "-t", str(target))
            return {"ok": True, "command": command}
        if command == "soft_close_window":
            target = _required(request, "target")
            self.run("newmux-soft-delete-window", "-t", str(target))
            return {"ok": True, "command": command}
        if command == "restore_latest":
            target = request.get("target")
            argv = ["newmux-reopen-latest-closed"]
            if target:
                argv.extend(["-t", str(target)])
            out = self.run(*argv)
            return {"ok": True, "command": command, "message": out.strip()}
        raise NewmuxError(f"unknown command: {command}")

    def _command_new_window(self, request: dict[str, Any]) -> dict[str, Any]:
        session = request.get("session", "newmux")
        name = request.get("name")
        argv = ["new-window", "-d", "-P", "-F", "#{window_id}", "-t", f"{session}:"]
        if name:
            argv.extend(["-n", str(name)])
        window_id = self.run(*argv).strip()
        return {"ok": True, "command": "new_window", "window_id": window_id}


def _required(request: dict[str, Any], key: str) -> Any:
    value = request.get(key)
    if value is None or value == "":
        raise NewmuxError(f"missing required field: {key}")
    return value


class BridgeServer(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, socket_path: str, newmux: Newmux, poll_interval: float):
        self.newmux = newmux
        self.poll_interval = poll_interval
        super().__init__(socket_path, BridgeHandler)


class BridgeHandler(socketserver.StreamRequestHandler):
    server: BridgeServer

    def handle(self) -> None:
        for raw in self.rfile:
            try:
                request = json.loads(raw.decode())
                if request.get("type") == "get_snapshot":
                    self.write(self.server.newmux.snapshot())
                elif request.get("type") == "command":
                    result = self.server.newmux.command(request)
                    result["type"] = "command_result"
                    result["snapshot"] = self.server.newmux.snapshot()
                    self.write(result)
                elif request.get("type") == "subscribe":
                    self.subscribe()
                    return
                else:
                    raise NewmuxError(f"unknown request type: {request.get('type')}")
            except Exception as exc:  # noqa: BLE001 - bridge replies with errors.
                self.write({"type": "error", "ok": False, "error": str(exc)})

    def subscribe(self) -> None:
        last_revision = None
        while True:
            snapshot = self.server.newmux.snapshot()
            if snapshot["revision"] != last_revision:
                self.write(snapshot)
                last_revision = snapshot["revision"]
            time.sleep(self.server.poll_interval)

    def write(self, message: dict[str, Any]) -> None:
        data = json.dumps(message, separators=(",", ":")).encode() + b"\n"
        self.wfile.write(data)
        self.wfile.flush()


def serve(args: argparse.Namespace) -> int:
    socket_path = args.bridge_socket
    parent = os.path.dirname(socket_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    server = BridgeServer(
        socket_path,
        Newmux(args.socket_name, args.socket_path),
        args.poll_interval,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()
        if os.path.exists(socket_path):
            os.unlink(socket_path)
    return 0


def request(args: argparse.Namespace) -> int:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(args.bridge_socket)
        sock.sendall(args.message.encode() + b"\n")
        if args.subscribe:
            while True:
                data = _recv_line(sock)
                if not data:
                    return 0
                print(data, flush=True)
        else:
            data = _recv_line(sock)
            if data:
                print(data)
    return 0


def snapshot(args: argparse.Namespace) -> int:
    print(
        json.dumps(
            Newmux(args.socket_name, args.socket_path).snapshot(),
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def key_event(args: argparse.Namespace) -> int:
    newmux = Newmux(args.socket_name, args.socket_path)
    fmt = FIELD_SEP.join(
        [
            "#{session_id}",
            "#{session_name}",
            "#{window_id}",
            "#{window_index}",
            "#{window_name}",
            "#{pane_id}",
            "#{pane_index}",
            "#{pane_current_path}",
            "#{pane_current_command}",
        ]
    )
    row = newmux.run(
        "display-message",
        "-p",
        "-t",
        args.target_pane,
        fmt,
        check=False,
    ).strip().split(FIELD_SEP)

    context: dict[str, Any] = {}
    if len(row) >= 9:
        (
            session_id,
            session_name,
            window_id,
            window_index,
            window_name,
            pane_id,
            pane_index,
            pane_path,
            pane_command,
        ) = row[:9]
        context = {
            "session_id": session_id,
            "session": session_name,
            "window": window_id,
            "window_index": int(window_index or "0"),
            "window_name": window_name,
            "pane": pane_id,
            "pane_index": int(pane_index or "0"),
            "pane_current_path": pane_path,
            "pane_current_command": pane_command,
        }

    event = {
        "type": "shortcut_event",
        "schema": "newmux.ui.key_event.v1",
        "key": args.key,
        "socket_name": args.socket_name,
        "socket_path": args.socket_path,
        "generated_at": time.time(),
        **context,
    }
    line = json.dumps(event, separators=(",", ":"))

    if args.log_file:
        log_path = Path(args.log_file)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8") as file:
            file.write(line + "\n")
    return 0


def _visible_sessions(state: dict[str, Any], show_internal: bool) -> list[dict[str, Any]]:
    sessions = state["sessions"]
    if show_internal:
        return sessions
    return [session for session in sessions if not session.get("internal")]


def _visible_windows(state: dict[str, Any], show_internal: bool) -> list[dict[str, Any]]:
    windows = state["windows"]
    if show_internal:
        return windows
    return [window for window in windows if not window.get("internal")]


def _visible_panes(state: dict[str, Any], show_internal: bool) -> list[dict[str, Any]]:
    panes = state["panes"]
    if show_internal:
        return panes
    return [pane for pane in panes if not pane.get("internal")]


def _compact_path(path: str, max_len: int = 48) -> str:
    home = str(Path.home())
    if path == home:
        path = "~"
    elif path.startswith(home + os.sep):
        path = "~" + path[len(home):]
    if len(path) <= max_len:
        return path
    return "..." + path[-(max_len - 3):]


def _age(seconds: float) -> str:
    if seconds < 60:
        return f"{int(seconds)}s"
    minutes = int(seconds // 60)
    if minutes < 60:
        return f"{minutes}m"
    hours = int(minutes // 60)
    return f"{hours}h"


def _default_status_path() -> Path:
    try:
        value = LATEST_STATUS_FILE.read_text().strip()
    except OSError:
        value = ""
    if value:
        return Path(value)
    return ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status.json"


def _read_ghostty_status(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    try:
        return json.loads(path.read_text()), None
    except OSError as exc:
        return None, str(exc)
    except json.JSONDecodeError as exc:
        return None, f"invalid JSON: {exc}"


def _workspace_name(session: dict[str, Any]) -> str:
    return session.get("group") or session["name"]


def _workspace_rows(
    sessions: list[dict[str, Any]],
    windows: list[dict[str, Any]],
    panes: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    session_groups = {
        session["id"]: _workspace_name(session)
        for session in sessions
    }
    by_workspace: dict[str, dict[str, Any]] = {}

    for session in sessions:
        group = _workspace_name(session)
        workspace = by_workspace.setdefault(
            group,
            {
                "name": group,
                "sessions": [],
                "clients": 0,
                "windows": {},
                "panes": {},
            },
        )
        workspace["sessions"].append(session)
        workspace["clients"] += session.get("attached_clients", 0)

    for pane in panes:
        group = session_groups.get(pane["session_id"])
        if group is None:
            continue
        workspace = by_workspace.setdefault(
            group,
            {"name": group, "sessions": [], "clients": 0, "windows": {}, "panes": {}},
        )
        workspace["panes"].setdefault(pane["id"], pane)

    for window in windows:
        group = window.get("session_group") or session_groups.get(window["session_id"])
        if group is None:
            continue
        workspace = by_workspace.setdefault(
            group,
            {"name": group, "sessions": [], "clients": 0, "windows": {}, "panes": {}},
        )
        existing = workspace["windows"].get(window["id"])
        if existing is None:
            existing = {
                **window,
                "active_views": [],
            }
            workspace["windows"][window["id"]] = existing
        if window["active"]:
            existing["active_views"].append(window["session_name"])

    return [
        by_workspace[name]
        for name in sorted(by_workspace)
    ]


def _dashboard_lines(
    state: dict[str, Any],
    *,
    show_internal: bool,
    new_window_ids: set[str],
) -> list[str]:
    sessions = _visible_sessions(state, show_internal)
    windows = _visible_windows(state, show_internal)
    panes = _visible_panes(state, show_internal)
    workspaces = _workspace_rows(sessions, windows, panes)
    panes_by_window: dict[str, list[dict[str, Any]]] = {}
    for pane in panes:
        panes_by_window.setdefault(pane["window_id"], []).append(pane)

    unique_windows = {
        window["id"]
        for workspace in workspaces
        for window in workspace["windows"].values()
    }
    unique_panes = {
        pane["id"]
        for workspace in workspaces
        for pane in workspace["panes"].values()
    }
    stamp = time.strftime("%H:%M:%S", time.localtime(state["generated_at"]))
    recovery = state["recovery_stack"]
    lines = [
        f"Newmux Dashboard  {stamp}  socket={state['socket_name']}  rev={state['revision']}",
        "q quit | * focused | + new | visible terminals only",
        "",
        f"Active: {len(unique_windows)} terminal windows, {len(unique_panes)} panes",
        f"Deleted LIFO: {len(recovery)} recoverable items",
        "",
        "ACTIVE TERMINALS",
        "focus new  #  id    panes  state   cmd       path",
        "----- --- -- ----- ------ ------- --------- ------------------------------",
    ]

    if not workspaces:
        lines.append("  none")
    for workspace in workspaces:
        workspace_windows = sorted(
            workspace["windows"].values(),
            key=lambda window: window["index"],
        )
        for window in workspace_windows:
            active = "*" if window["active_views"] else " "
            fresh = "+" if window["id"] in new_window_ids else " "
            panes_by_id = {
                pane["id"]: pane
                for pane in panes_by_window.get(window["id"], [])
            }
            window_panes = sorted(panes_by_id.values(), key=lambda item: item["index"])
            if not window_panes:
                lines.append(
                    f"  {active:^5} {fresh:^3} {window['index']:>2} {window['id']:<5} "
                    f"{0:>6} {'empty':<7} {'-':<9} -"
                )
                continue
            dirty = any(pane.get("dirty") for pane in window_panes)
            pane_state = "dirty" if dirty else "clean"
            primary = window_panes[0]
            path = _compact_path(primary["current_path"], max_len=30)
            command = primary["current_command"] or "-"
            lines.append(
                f"  {active:^5} {fresh:^3} {window['index']:>2} {window['id']:<5} "
                f"{len(window_panes):>6} {pane_state:<7} {command:<9.9} {path}"
            )
            for pane_index, pane in enumerate(window_panes):
                if len(window_panes) == 1:
                    continue
                pane_state = "dirty" if pane.get("dirty") else "clean"
                pane_path = _compact_path(pane["current_path"], max_len=30)
                pane_command = pane["current_command"] or "-"
                lines.append(
                    f"          pane {pane['id']:<5} {pane_state:<7} "
                    f"pid={pane['process_id']:<6} {pane_command:<9.9} {pane_path}"
                )

    lines.extend(["", "DELETED LIFO"])
    if not recovery:
        lines.append("  empty")
    now = time.time()
    for item in recovery[:8]:
        panes = item.get("panes") or []
        dirty = any(pane.get("dirty") for pane in panes)
        state_text = "dirty" if dirty else "clean"
        deleted_at = float(item.get("deleted_at") or state["generated_at"])
        age = _age(max(0, now - deleted_at))
        pane_count = len({pane.get("pane") for pane in panes if pane.get("pane")})
        lines.append(
            f"  #{item['sequence']:<3} {item.get('kind', '-'):<6} {item.get('window', '-'):<5} "
            f"{item.get('mode', '-'):<5} {state_text:<5} panes={pane_count:<2} age={age}"
        )
    return lines


def _visible_counts(state: dict[str, Any], show_internal: bool) -> dict[str, int]:
    sessions = _visible_sessions(state, show_internal)
    windows = _visible_windows(state, show_internal)
    panes = _visible_panes(state, show_internal)
    workspaces = _workspace_rows(sessions, windows, panes)
    unique_windows = {
        window["id"]
        for workspace in workspaces
        for window in workspace["windows"].values()
    }
    unique_panes = {
        pane["id"]
        for workspace in workspaces
        for pane in workspace["panes"].values()
    }
    return {
        "sessions": len(sessions),
        "workspaces": len(workspaces),
        "windows": len(unique_windows),
        "panes": len(unique_panes),
        "lifo": len(state.get("recovery_stack", [])),
    }


def _ghostty_counts(status: dict[str, Any]) -> dict[str, Any]:
    return {
        "native_tabs": int(status.get("native_tab_count") or 0),
        "rail_tabs": int(status.get("rail_tab_count") or 0),
        "active_native_tab_index": status.get("active_native_tab_index"),
        "active_rail_tab_id": status.get("active_rail_tab_id"),
        "rail_expanded": status.get("rail_expanded"),
        "updated_at": float(status.get("updated_at") or 0),
    }


def _ui_sync_verdict(backend: dict[str, int], ghostty: dict[str, Any] | None) -> tuple[str, str]:
    if ghostty is None:
        return "UNKNOWN", "Ghostty status hook unavailable"
    backend_windows = backend["windows"]
    native_tabs = int(ghostty["native_tabs"])
    rail_tabs = int(ghostty["rail_tabs"])
    if backend_windows == native_tabs == rail_tabs:
        return "OK", "backend, native tabs, and rail agree"
    if backend_windows < native_tabs:
        return "MISMATCH", "stale Ghostty tab: backend deleted a window but UI still shows it"
    if backend_windows > native_tabs:
        return "MISMATCH", "missing Ghostty tab: backend has a window that UI does not show"
    return "MISMATCH", "native tab count and Newmux rail count disagree"


def _ui_sync_lines(
    state: dict[str, Any],
    *,
    show_internal: bool,
    status_path: Path,
) -> list[str]:
    backend = _visible_counts(state, show_internal)
    status, error = _read_ghostty_status(status_path)
    ghostty = _ghostty_counts(status) if status else None
    verdict, reason = _ui_sync_verdict(backend, ghostty)
    lines = [
        "",
        "UI SYNC",
        "source       windows/tabs  panes  active        age",
        "-----------  ------------  -----  ------------  ---",
        (
            f"backend      {backend['windows']:<12}  "
            f"{backend['panes']:<5}  {'-':<12}  live"
        ),
    ]
    if ghostty is None:
        lines.append(f"ghostty      unavailable   -      -             {status_path}")
        lines.append(f"verdict      {verdict:<12} {reason}: {error or status_path}")
        return lines

    status_age = "-"
    if ghostty["updated_at"]:
        status_age = _age(max(0, time.time() - ghostty["updated_at"]))
    lines.append(
        f"ghostty      {ghostty['native_tabs']:<12}  "
        f"{'-':<5}  {str(ghostty['active_native_tab_index']):<12}  {status_age}"
    )
    lines.append(
        f"rail         {ghostty['rail_tabs']:<12}  "
        f"{'-':<5}  {str(ghostty['active_rail_tab_id']):<12}  {status_age}"
    )
    lines.append(f"verdict      {verdict:<12} {reason}")
    return lines


def _plain_dashboard(args: argparse.Namespace) -> int:
    state = Newmux(args.socket_name, args.socket_path).snapshot()
    lines = _dashboard_lines(state, show_internal=args.show_internal, new_window_ids=set())
    if args.ui_sync:
        lines.extend(
            _ui_sync_lines(
                state,
                show_internal=args.show_internal,
                status_path=args.status_file or _default_status_path(),
            )
        )
    for line in lines:
        print(line)
    return 0


def _curses_dashboard(stdscr: Any, args: argparse.Namespace) -> None:
    curses.curs_set(0)
    try:
        curses.use_default_colors()
    except curses.error:
        pass
    try:
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
    except curses.error:
        pass
    stdscr.nodelay(True)
    stdscr.keypad(True)
    newmux = Newmux(args.socket_name, args.socket_path)
    known_window_ids: set[str] = set()
    highlighted_until: dict[str, float] = {}
    last_error = ""
    scroll_offset = 0
    stick_to_bottom = False
    spinner = "|/-\\"

    while True:
        key = stdscr.getch()
        while key != -1:
            if key in (ord("q"), ord("Q")):
                return
            if key in (curses.KEY_UP, ord("k")):
                scroll_offset = max(0, scroll_offset - 1)
                stick_to_bottom = False
            elif key in (curses.KEY_DOWN, ord("j")):
                scroll_offset += 1
                stick_to_bottom = False
            elif key in (curses.KEY_PPAGE, ord("u")):
                scroll_offset = max(0, scroll_offset - 8)
                stick_to_bottom = False
            elif key in (curses.KEY_NPAGE, ord("d")):
                scroll_offset += 8
                stick_to_bottom = False
            elif key in (curses.KEY_HOME, ord("g")):
                scroll_offset = 0
                stick_to_bottom = False
            elif key in (curses.KEY_END, ord("G")):
                stick_to_bottom = True
            elif key == curses.KEY_MOUSE:
                try:
                    _, _, _, _, mouse_state = curses.getmouse()
                except curses.error:
                    mouse_state = 0
                if mouse_state & getattr(curses, "BUTTON4_PRESSED", 0):
                    scroll_offset = max(0, scroll_offset - 3)
                    stick_to_bottom = False
                elif mouse_state & getattr(curses, "BUTTON5_PRESSED", 0):
                    scroll_offset += 3
                    stick_to_bottom = False
            key = stdscr.getch()

        try:
            state = newmux.snapshot()
            current_ids = {window["id"] for window in _visible_windows(state, args.show_internal)}
            now = time.time()
            for window_id in current_ids - known_window_ids:
                highlighted_until[window_id] = now + NEW_WINDOW_HIGHLIGHT_SECONDS
            known_window_ids = current_ids
            highlighted_until = {
                window_id: until
                for window_id, until in highlighted_until.items()
                if until > now and window_id in current_ids
            }
            lines = _dashboard_lines(
                state,
                show_internal=args.show_internal,
                new_window_ids=set(highlighted_until),
            )
            if args.ui_sync:
                lines.extend(
                    _ui_sync_lines(
                        state,
                        show_internal=args.show_internal,
                        status_path=args.status_file or _default_status_path(),
                    )
                )
            lines[0] = f"{lines[0]}  live {spinner[int(now * 4) % len(spinner)]}"
            last_error = ""
        except Exception as exc:  # noqa: BLE001 - dashboard should keep running.
            lines = [
                f"Newmux Dashboard  socket={args.socket_name}  live {spinner[int(time.time() * 4) % len(spinner)]}",
                "q quit | waiting for backend",
                "",
                "Active: unavailable",
                "Deleted LIFO: unavailable",
                "",
                "ACTIVE TERMINALS",
                f"  backend unavailable: {exc}",
                "",
                "DELETED LIFO",
                "  unavailable",
            ]
            last_error = str(exc)

        stdscr.erase()
        height, width = stdscr.getmaxyx()
        body_height = max(0, height - 1)
        max_scroll = max(0, len(lines) - body_height)
        if stick_to_bottom:
            scroll_offset = max_scroll
        else:
            scroll_offset = min(scroll_offset, max_scroll)
        visible_lines = lines[scroll_offset:scroll_offset + body_height]
        for row, line in enumerate(visible_lines):
            attr = curses.A_NORMAL
            source_row = row + scroll_offset
            if source_row == 0:
                attr = curses.A_BOLD
            if " + new" in line:
                attr |= curses.A_REVERSE
            if line.lstrip().startswith("* window") or "  * window" in line:
                attr |= curses.A_BOLD
            stdscr.addnstr(row, 0, line, max(0, width - 1), attr)
        footer = (
            f"scroll {scroll_offset}/{max_scroll} | Up/Down PgUp/PgDn g/G mouse wheel | q quit"
        )
        if last_error:
            footer = f"{footer} | {last_error}"
        if height > 0:
            stdscr.addnstr(height - 1, 0, footer, max(0, width - 1), curses.A_REVERSE)
        stdscr.refresh()
        time.sleep(args.poll_interval)


def dashboard(args: argparse.Namespace) -> int:
    if args.once:
        return _plain_dashboard(args)
    if args.gui:
        argv = [
            sys.executable,
            str(ROOT / "scripts" / "newmux-ui-app.py"),
            "--socket-name",
            args.socket_name,
            "--poll-interval",
            str(args.poll_interval),
        ]
        if args.socket_path:
            argv.extend(["--socket-path", args.socket_path])
        return subprocess.run(argv, check=False).returncode
    curses.wrapper(_curses_dashboard, args)
    return 0


def _recv_line(sock: socket.socket) -> str:
    chunks = []
    while True:
        chunk = sock.recv(1)
        if not chunk:
            break
        if chunk == b"\n":
            break
        chunks.append(chunk)
    return b"".join(chunks).decode()


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="mode", required=True)

    serve_parser = subparsers.add_parser("serve")
    serve_parser.add_argument("--socket-name", default="newmux-dev")
    serve_parser.add_argument("--socket-path")
    serve_parser.add_argument("--bridge-socket", required=True)
    serve_parser.add_argument("--poll-interval", type=float, default=0.2)
    serve_parser.set_defaults(func=serve)

    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--bridge-socket", required=True)
    request_parser.add_argument("--subscribe", action="store_true")
    request_parser.add_argument("message")
    request_parser.set_defaults(func=request)

    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--socket-name", default="newmux-dev")
    snapshot_parser.add_argument("--socket-path")
    snapshot_parser.set_defaults(func=snapshot)

    key_event_parser = subparsers.add_parser("key-event")
    key_event_parser.add_argument("--socket-name", default="newmux-dev")
    key_event_parser.add_argument("--socket-path")
    key_event_parser.add_argument("--target-pane", required=True)
    key_event_parser.add_argument("--key", required=True)
    key_event_parser.add_argument(
        "--log-file",
        default="/tmp/newmux-ui-key-events.jsonl",
    )
    key_event_parser.set_defaults(func=key_event)

    dashboard_parser = subparsers.add_parser("dashboard")
    dashboard_parser.add_argument("--socket-name", default="newmux-dev")
    dashboard_parser.add_argument("--socket-path")
    dashboard_parser.add_argument("--poll-interval", type=float, default=0.2)
    dashboard_parser.add_argument("--show-internal", action="store_true")
    dashboard_parser.add_argument("--once", action="store_true")
    dashboard_parser.add_argument("--terminal", action="store_true")
    dashboard_parser.add_argument("--gui", action="store_true")
    dashboard_parser.add_argument("--ui-sync", action="store_true")
    dashboard_parser.add_argument("--status-file", type=Path)
    dashboard_parser.set_defaults(func=dashboard)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
