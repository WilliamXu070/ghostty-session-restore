#!/usr/bin/env python3
"""Newmux UI bridge prototype.

This sidecar exposes Newmux/tmux state over a small JSON-lines Unix socket
protocol. It is deliberately outside the tmux server for now so the bridge
contract can be tested before moving it into C.
"""

from __future__ import annotations

import argparse
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


class NewmuxError(RuntimeError):
    pass


class Newmux:
    def __init__(self, socket_name: str, socket_path: str | None = None):
        self.socket_name = socket_name
        self.socket_path = socket_path

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
        out = self.run("newmux-list-recently-closed", check=False)
        items = []
        for line in out.splitlines():
            fields = line.split()
            if len(fields) < 2 or not fields[0].isdigit():
                continue
            item: dict[str, Any] = {
                "sequence": int(fields[0]),
                "kind": fields[1],
                "raw": line,
            }
            for field in fields[2:]:
                if "=" not in field:
                    continue
                key, value = field.split("=", 1)
                if key == "live":
                    item[key] = value == "1"
                else:
                    item[key] = value
            items.append(item)
        return items

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

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
