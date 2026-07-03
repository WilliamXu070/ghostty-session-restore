#!/usr/bin/env python3
"""Run compact JSON-defined Newmux golden flows.

The runner records backend snapshots and action events so failures explain
what changed, not only that a shell command failed.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
RUNS_DIR = ROOT / ".local" / "newmux-flow-runs"
LATEST_SOCKET_FILE = ROOT / ".local" / "newmux-ghostty" / "latest" / "socket-path"
LATEST_STATUS_FILE = ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status-path"


class FlowFailure(RuntimeError):
    pass


class FlowRunner:
    def __init__(self, flow_path: Path):
        self.flow_path = flow_path
        self.flow = json.loads(flow_path.read_text())
        self.name = self.flow.get("name") or flow_path.stem
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        self.run_dir = RUNS_DIR / f"{self.name}-{stamp}-{os.getpid()}"
        self.run_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = self.run_dir / "events.jsonl"
        self.snapshots_path = self.run_dir / "snapshots.jsonl"
        self.report_path = self.run_dir / "report.json"
        self.trace_path = self.run_dir / "startup-trace.tsv"
        self.states: dict[str, dict[str, Any]] = {}
        self.ui_states: dict[str, dict[str, Any]] = {}
        self.events: list[dict[str, Any]] = []
        self.ghostty_pid: int | None = None
        self.env = os.environ.copy()
        self.env["NEWMUX_RESTORE_TRACE_FILE"] = str(self.trace_path)

    def event(self, event_type: str, **fields: Any) -> None:
        event = {
            "type": event_type,
            "time": time.time(),
            **fields,
        }
        self.events.append(event)
        with self.events_path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n")

    def run_cmd(
        self,
        argv: list[str],
        *,
        check: bool = True,
        env_extra: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        env = self.env.copy()
        if env_extra:
            env.update(env_extra)
        self.event("command.start", argv=argv, env_extra=env_extra or {})
        proc = subprocess.run(
            argv,
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        self.event(
            "command.end",
            argv=argv,
            returncode=proc.returncode,
            stdout_tail=proc.stdout[-1000:],
            stderr_tail=proc.stderr[-1000:],
        )
        if check and proc.returncode != 0:
            raise FlowFailure(
                f"command failed ({proc.returncode}): {' '.join(argv)}\n"
                f"{proc.stderr or proc.stdout}"
            )
        return proc

    def socket_path(self) -> str:
        try:
            value = LATEST_SOCKET_FILE.read_text().strip()
        except OSError:
            value = str(ROOT / ".local" / "nm-sock" / "newmux-dev.sock")
        return value

    def setup(self) -> None:
        setup = self.flow.get("setup", {})
        if setup == "fresh-ghostty":
            setup = {"type": "fresh-ghostty"}
        setup_type = setup.get("type", "fresh-ghostty")
        if setup_type != "fresh-ghostty":
            raise FlowFailure(f"unknown setup type: {setup_type}")
        self.event("setup.start", setup=setup_type)
        env_extra = {
            str(key): str(value)
            for key, value in setup.get("env", {}).items()
        }
        self.run_cmd([str(ROOT / "scripts" / "open-newmux-ghostty.sh")], env_extra=env_extra)
        self.wait(float(setup.get("wait", 2)))
        self.wait_for_ready(float(setup.get("ready_timeout", 8)))
        self.ghostty_pid = self.find_test_ghostty_pid()
        self.event("setup.ghostty", pid=self.ghostty_pid)
        self.mark_runtime("newmux")
        self.event("setup.end", setup=setup_type, socket_path=self.socket_path())

    def find_test_ghostty_pid(self) -> int:
        pattern = r"Ghostty[.]app/Contents/MacOS/ghostty .*ghostty-config/newmux[.]config"
        proc = self.run_cmd(["pgrep", "-f", pattern], check=False)
        pids = [
            int(line)
            for line in proc.stdout.splitlines()
            if line.strip().isdigit()
        ]
        if not pids:
            raise FlowFailure("could not find the Ghostty process launched for this flow")
        return max(pids)

    def status_path(self) -> Path:
        try:
            value = LATEST_STATUS_FILE.read_text().strip()
        except OSError:
            value = ""
        if value:
            return Path(value)
        return ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status.json"

    def wait(self, seconds: float) -> None:
        self.event("wait.start", seconds=seconds)
        time.sleep(seconds)
        self.event("wait.end", seconds=seconds)

    def wait_for_ready(self, timeout: float) -> None:
        self.event("ready.start", timeout=timeout)
        deadline = time.time() + timeout
        last_error = ""
        while time.time() < deadline:
            proc = self.run_cmd(
                [
                    "python3",
                    str(ROOT / "scripts" / "newmux-ui-bridge.py"),
                    "snapshot",
                    "--socket-name",
                    self.flow.get("socket_name", "newmux-dev"),
                    "--socket-path",
                    self.socket_path(),
                ],
                check=False,
            )
            if proc.returncode == 0:
                try:
                    state = json.loads(proc.stdout)
                except json.JSONDecodeError:
                    state = {}
                attached = sum(
                    int(session.get("attached_clients") or 0)
                    for session in state.get("sessions", [])
                    if not session.get("internal")
                )
                if attached > 0:
                    self.event("ready.ok", attached_clients=attached)
                    return
                last_error = "server up but no attached Ghostty client yet"
                time.sleep(0.25)
                continue
            last_error = (proc.stderr or proc.stdout).strip()
            time.sleep(0.25)
        raise FlowFailure(f"Newmux did not become ready within {timeout}s: {last_error}")

    def snapshot(self, name: str) -> dict[str, Any]:
        proc = self.run_cmd(
            [
                "python3",
                str(ROOT / "scripts" / "newmux-ui-bridge.py"),
                "snapshot",
                "--socket-name",
                self.flow.get("socket_name", "newmux-dev"),
                "--socket-path",
                self.socket_path(),
            ]
        )
        snapshot = json.loads(proc.stdout)
        derived = self.derive(snapshot)
        record = {
            "type": "snapshot",
            "name": name,
            "time": time.time(),
            "socket_path": self.socket_path(),
            "raw": snapshot,
            "derived": derived,
        }
        self.states[name] = record
        with self.snapshots_path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        self.event("snapshot", name=name, derived=derived)
        return record

    def ui_snapshot(self, name: str) -> dict[str, Any]:
        path = self.status_path()
        try:
            raw = json.loads(path.read_text())
        except OSError as exc:
            raise FlowFailure(f"Ghostty UI status file unavailable at {path}: {exc}") from exc
        except json.JSONDecodeError as exc:
            raise FlowFailure(f"Ghostty UI status file is invalid JSON at {path}: {exc}") from exc
        derived = {
            "ui_enabled": bool(raw.get("ui_enabled")),
            "status_enabled": bool(raw.get("status_enabled")),
            "native_tabs": int(raw.get("native_tab_count") or 0),
            "native_tab_ids": [
                str(tab.get("id") or "")
                for tab in raw.get("native_tabs", [])
                if isinstance(tab, dict)
            ],
            "native_tab_titles": [
                str(tab.get("title") or "")
                for tab in raw.get("native_tabs", [])
                if isinstance(tab, dict)
            ],
            "rail_tabs": int(raw.get("rail_tab_count") or 0),
            "active_native_tab_index": int(raw.get("active_native_tab_index") or 0),
            "rail_expanded": bool(raw.get("rail_expanded")),
        }
        record = {
            "type": "ui_snapshot",
            "name": name,
            "time": time.time(),
            "path": str(path),
            "raw": raw,
            "derived": derived,
        }
        self.ui_states[name] = record
        with self.snapshots_path.open("a", encoding="utf-8") as file:
            file.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
        self.event("ui_snapshot", name=name, derived=derived)
        return record

    def derive(self, snapshot: dict[str, Any]) -> dict[str, Any]:
        sessions = [s for s in snapshot["sessions"] if not s.get("internal")]
        session_groups = {
            s["id"]: s.get("group") or s["name"]
            for s in sessions
        }
        workspaces: dict[str, dict[str, Any]] = {}
        for session in sessions:
            group = session.get("group") or session["name"]
            workspace = workspaces.setdefault(
                group,
                {
                    "group": group,
                    "sessions": [],
                    "windows": set(),
                    "panes": set(),
                    "attached_clients": 0,
                },
            )
            workspace["sessions"].append(session["name"])
            workspace["attached_clients"] += int(session.get("attached_clients") or 0)

        for window in snapshot["windows"]:
            if window.get("internal"):
                continue
            group = window.get("session_group") or session_groups.get(window["session_id"])
            if group is None:
                continue
            workspace = workspaces.setdefault(
                group,
                {"group": group, "sessions": [], "windows": set(), "panes": set(), "attached_clients": 0},
            )
            workspace["windows"].add(window["id"])

        for pane in snapshot["panes"]:
            if pane.get("internal"):
                continue
            group = session_groups.get(pane["session_id"])
            if group is None:
                continue
            workspace = workspaces.setdefault(
                group,
                {"group": group, "sessions": [], "windows": set(), "panes": set(), "attached_clients": 0},
            )
            workspace["panes"].add(pane["id"])

        dirty_panes = {
            pane["id"]
            for pane in snapshot["panes"]
            if not pane.get("internal") and pane.get("dirty")
        }
        dirty_windows = {
            pane["window_id"]
            for pane in snapshot["panes"]
            if not pane.get("internal") and pane.get("dirty")
        }
        primary_windows = sorted(
            [
                window for window in snapshot["windows"]
                if not window.get("internal") and window.get("session_name") == "newmux"
            ],
            key=lambda window: window["index"],
        )

        serial_workspaces = []
        for group in sorted(workspaces):
            workspace = workspaces[group]
            serial_workspaces.append(
                {
                    "group": group,
                    "sessions": sorted(set(workspace["sessions"])),
                    "windows": sorted(workspace["windows"]),
                    "panes": sorted(workspace["panes"]),
                    "attached_clients": workspace["attached_clients"],
                }
            )

        return {
            "workspaces": len(serial_workspaces),
            "windows": sum(len(workspace["windows"]) for workspace in serial_workspaces),
            "panes": sum(len(workspace["panes"]) for workspace in serial_workspaces),
            "lifo": len(snapshot.get("recovery_stack", [])),
            "raw_sessions": len(sessions),
            "raw_windows": len([w for w in snapshot["windows"] if not w.get("internal")]),
            "raw_panes": len([p for p in snapshot["panes"] if not p.get("internal")]),
            "dirty_windows": len(dirty_windows),
            "dirty_panes": len(dirty_panes),
            "primary_window_order": [window["id"] for window in primary_windows],
            "primary_window_names": [window["name"] for window in primary_windows],
            "workspace_details": serial_workspaces,
        }

    def choose_target_pane(self, state_name: str, target: str = "primary_active") -> str:
        state = self.states[state_name]["raw"]
        if target.startswith("window_index:"):
            index = int(target.split(":", 1)[1])
            candidates = [
                pane for pane in state["panes"]
                if pane.get("session_name") == "newmux" and pane.get("window_index") == index
            ]
            if candidates:
                return sorted(candidates, key=lambda pane: pane["index"])[0]["id"]
            raise FlowFailure(f"no pane for {target} in snapshot {state_name}")
        if target.startswith("window_name:"):
            window_name = target.split(":", 1)[1]
            window_ids = {
                window["id"]
                for window in state.get("windows", [])
                if window.get("session_name") == "newmux" and window.get("name") == window_name
            }
            candidates = [
                pane for pane in state["panes"]
                if pane.get("session_name") == "newmux" and pane.get("window_id") in window_ids
            ]
            if candidates:
                return sorted(candidates, key=lambda pane: (pane["window_index"], pane["index"]))[0]["id"]
            raise FlowFailure(f"no pane for {target} in snapshot {state_name}")
        if target == "latest_window":
            unique: dict[str, dict[str, Any]] = {}
            for pane in state["panes"]:
                if pane.get("session_name") != "newmux":
                    continue
                current = unique.get(pane["window_id"])
                if current is None or pane["index"] < current["index"]:
                    unique[pane["window_id"]] = pane
            if unique:
                return sorted(
                    unique.values(),
                    key=lambda pane: int(str(pane["window_id"]).lstrip("@") or "0"),
                )[-1]["id"]
        primary = [
            pane for pane in state["panes"]
            if pane.get("session_name") == "newmux" and pane.get("active")
        ]
        candidates = primary or [pane for pane in state["panes"] if pane.get("active")]
        if not candidates:
            raise FlowFailure(f"no active pane in snapshot {state_name}")
        return candidates[0]["id"]

    def pane_path(self, state_name: str, pane_id: str) -> str:
        state = self.states[state_name]["raw"]
        for pane in state["panes"]:
            if pane["id"] == pane_id:
                return pane.get("current_path") or str(Path.home())
        return str(Path.home())

    def pane_window(self, state_name: str, pane_id: str) -> str:
        state = self.states[state_name]["raw"]
        for pane in state["panes"]:
            if pane["id"] == pane_id:
                return str(pane["window_id"])
        raise FlowFailure(f"no window for pane {pane_id} in snapshot {state_name}")

    def newmux_cmd(self, *args: str) -> None:
        self.run_cmd([str(ROOT / "bin" / "newmux"), "-S", self.socket_path(), *args])

    def newmux_output(self, *args: str) -> str:
        proc = self.run_cmd([str(ROOT / "bin" / "newmux"), "-S", self.socket_path(), *args])
        return proc.stdout

    def mark_runtime(self, target: str) -> None:
        self.run_cmd(
            [
                "python3",
                str(ROOT / "scripts" / "newmux-runtime.py"),
                "mark",
                "--socket-path",
                self.socket_path(),
                "--target",
                target,
            ]
        )

    def cmd_t(self, from_state: str) -> None:
        pane_id = self.choose_target_pane(from_state)
        socket_path = self.socket_path()
        self.event("action.start", action="cmd_t", socket_path=socket_path, target_pane=pane_id)
        env = {
            "NEWMUX_SOCKET": self.flow.get("socket_name", "newmux-dev"),
            "NEWMUX_SOCKET_PATH": socket_path,
        }
        proc = self.run_cmd(
            [
                "python3",
                str(ROOT / "scripts" / "newmux-runtime.py"),
                "create-window",
                "--socket-path",
                socket_path,
                "--target",
                pane_id,
            ]
        )
        window_id = str(json.loads(proc.stdout)["window"])
        self.run_cmd(
            [str(ROOT / "scripts" / "start-newmux-fresh.sh")],
            env_extra={
                **env,
                "NEWMUX_ATTACH_WINDOW": window_id,
                "NEWMUX_STARTER_PRINT_WINDOW": "1",
            },
        )
        self.event("action.end", action="cmd_t", socket_path=socket_path, target_pane=pane_id, window=window_id)

    def cmd_d(self, from_state: str, target: str = "primary_active") -> None:
        pane_id = self.choose_target_pane(from_state, target)
        cwd = self.pane_path(from_state, pane_id)
        self.event("action.start", action="cmd_d", socket_path=self.socket_path(), target_pane=pane_id, cwd=cwd)
        self.newmux_cmd("split-window", "-h", "-c", cwd, "-t", pane_id)
        self.mark_runtime(pane_id)
        self.event("action.end", action="cmd_d", socket_path=self.socket_path(), target_pane=pane_id)

    def cmd_w(self, from_state: str, target: str = "primary_active") -> None:
        pane_id = self.choose_target_pane(from_state, target)
        window_id = self.pane_window(from_state, pane_id)
        self.event("action.start", action="cmd_w", socket_path=self.socket_path(), target_pane=pane_id)
        self.run_cmd(
            [
                "python3",
                str(ROOT / "scripts" / "newmux-runtime.py"),
                "delete-window",
                "--socket-path",
                self.socket_path(),
                "--target-window",
                window_id,
            ]
        )
        self.event("action.end", action="cmd_w", socket_path=self.socket_path(), target_pane=pane_id, window=window_id)

    def rename_window(self, from_state: str, target: str, name: str) -> None:
        pane_id = self.choose_target_pane(from_state, target)
        self.event("action.start", action="rename_window", target_pane=pane_id, name=name)
        self.newmux_cmd("rename-window", "-t", pane_id, name)
        self.event("action.end", action="rename_window", target_pane=pane_id, name=name)

    def cmd_w_binding(self, from_state: str, target: str = "primary_active") -> None:
        pane_id = self.choose_target_pane(from_state, target)
        socket_path = self.socket_path()
        self.event("action.start", action="cmd_w_binding", socket_path=socket_path, target_pane=pane_id)
        bindings = self.newmux_output("list-keys", "-T", "root")
        binding = ""
        for line in bindings.splitlines():
            if " User2 " in f" {line} ":
                binding = line.strip()
                break
        needle = "run-shell -b "
        if needle not in binding:
            raise FlowFailure(f"User2 binding is not run-shell -b: {binding}")
        command = binding.split(needle, 1)[1].strip()
        if command.startswith('"') and command.endswith('"'):
            command = command[1:-1]
        command = command.replace("#{socket_path}", socket_path).replace("#{pane_id}", pane_id)
        proc = self.run_cmd(["/bin/sh", "-c", command], check=False)
        if proc.returncode == 126:
            raise FlowFailure(f"cmd+w binding returned 126: {command}")
        if proc.returncode != 0:
            raise FlowFailure(
                f"cmd+w binding failed ({proc.returncode}): {command}\n"
                f"{proc.stderr or proc.stdout}"
            )
        self.event("action.end", action="cmd_w_binding", socket_path=socket_path, target_pane=pane_id)

    def press_ghostty_shortcut(self, key: str, modifiers: list[str]) -> None:
        key_codes = {
            "t": "17",
            "w": "13",
            "d": "2",
            "left_bracket": "33",
            "right_bracket": "30",
        }
        if key not in key_codes:
            raise FlowFailure(f"unsupported physical shortcut key: {key}")
        mods = ", ".join(modifiers)
        key_script = (
            f"key code {key_codes[key]} using {{{mods}}}"
            if mods
            else f"key code {key_codes[key]}"
        )
        self.event("action.start", action="press_ghostty_shortcut", key=key, modifiers=modifiers)
        proc = self.run_cmd(
            [
                "osascript",
                "-e",
                self.ghostty_focus_script() + f"  {key_script}\nend tell",
            ],
            check=False,
        )
        if proc.returncode != 0:
            raise FlowFailure(
                f"physical shortcut failed ({proc.returncode}) key={key} modifiers={modifiers}: "
                f"{proc.stderr or proc.stdout}"
            )
        self.event("action.end", action="press_ghostty_shortcut", key=key, modifiers=modifiers)

    def press_ghostty_shortcut_repeat(
        self,
        key: str,
        modifiers: list[str],
        count: int,
        interval: float,
    ) -> None:
        key_codes = {
            "t": "17",
            "w": "13",
            "d": "2",
            "left_bracket": "33",
            "right_bracket": "30",
        }
        if key not in key_codes:
            raise FlowFailure(f"unsupported physical shortcut key: {key}")
        if count < 1:
            raise FlowFailure(f"repeat count must be positive: {count}")
        mods = ", ".join(modifiers)
        key_script = (
            f"key code {key_codes[key]} using {{{mods}}}"
            if mods
            else f"key code {key_codes[key]}"
        )
        self.event(
            "action.start",
            action="press_ghostty_shortcut_repeat",
            key=key,
            modifiers=modifiers,
            count=count,
            interval=interval,
        )
        proc = self.run_cmd(
            [
                "osascript",
                "-e",
                (
                    self.ghostty_focus_script()
                    + f"  repeat {count} times\n"
                    + f"    {key_script}\n"
                    + f"    delay {interval:.3f}\n"
                    + "  end repeat\n"
                    + "end tell"
                ),
            ],
            check=False,
        )
        if proc.returncode != 0:
            raise FlowFailure(
                f"physical shortcut repeat failed ({proc.returncode}) key={key} "
                f"modifiers={modifiers}: {proc.stderr or proc.stdout}"
            )
        self.event(
            "action.end",
            action="press_ghostty_shortcut_repeat",
            key=key,
            modifiers=modifiers,
            count=count,
            interval=interval,
        )

    def perform_ghostty_action(self, action_name: str) -> None:
        self.event("action.start", action="perform_ghostty_action", name=action_name)
        proc = self.run_cmd(
            [
                "osascript",
                "-e",
                (
                    'tell application "Ghostty"\n'
                    "  set targetTerminal to focused terminal of selected tab of front window\n"
                    f'  perform action "{action_name}" on targetTerminal\n'
                    "end tell"
                ),
            ],
            check=False,
        )
        if proc.returncode != 0:
            raise FlowFailure(
                f"Ghostty action failed ({proc.returncode}) action={action_name}: "
                f"{proc.stderr or proc.stdout}"
            )
        self.event("action.end", action="perform_ghostty_action", name=action_name)

    def perform_ghostty_action_burst(self, action_name: str, count: int, interval: float) -> None:
        if count < 1:
            raise FlowFailure(f"action burst count must be positive: {count}")
        self.event(
            "action.start",
            action="perform_ghostty_action_burst",
            name=action_name,
            count=count,
            interval=interval,
        )
        proc = self.run_cmd(
            [
                "osascript",
                "-e",
                (
                    'tell application "Ghostty"\n'
                    f"  repeat {count} times\n"
                    "    set targetTerminal to focused terminal of selected tab of front window\n"
                    f'    perform action "{action_name}" on targetTerminal\n'
                    f"    delay {interval:.3f}\n"
                    "  end repeat\n"
                    "end tell"
                ),
            ],
            check=False,
        )
        if proc.returncode != 0:
            raise FlowFailure(
                f"Ghostty action burst failed ({proc.returncode}) action={action_name}: "
                f"{proc.stderr or proc.stdout}"
            )
        self.event(
            "action.end",
            action="perform_ghostty_action_burst",
            name=action_name,
            count=count,
            interval=interval,
        )

    def ghostty_focus_script(self) -> str:
        if self.ghostty_pid is None:
            raise FlowFailure("Ghostty PID is unavailable before physical shortcut")
        return (
            'tell application "Ghostty" to activate\n'
            'tell application "System Events"\n'
            f'  set targetPid to {self.ghostty_pid}\n'
            "  repeat 12 times\n"
            "    try\n"
            "      set targetProc to first process whose unix id is targetPid\n"
            "      set frontmost of targetProc to true\n"
            "    end try\n"
            "    delay 0.10\n"
            "    set frontPid to unix id of first process whose frontmost is true\n"
            "    if frontPid is targetPid then exit repeat\n"
            "  end repeat\n"
            "  set frontPid to unix id of first process whose frontmost is true\n"
            '  if frontPid is not targetPid then error "frontmost pid " & frontPid & " != expected " & targetPid\n'
        )

    def send_keys(self, from_state: str, keys: list[str], target: str = "primary_active") -> None:
        pane_id = self.choose_target_pane(from_state, target)
        self.event("action.start", action="send_keys", target_pane=pane_id, keys=keys)
        self.newmux_cmd("send-keys", "-t", pane_id, *keys)
        shell_command = self.submitted_shell_command(keys)
        if shell_command is not None:
            self.run_cmd(
                [
                    "python3",
                    str(ROOT / "scripts" / "newmux-runtime.py"),
                    "command",
                    "--socket-path",
                    self.socket_path(),
                    "--pane",
                    pane_id,
                    "--shell-command",
                    shell_command,
                    "--json",
                ]
            )
        self.event(
            "action.end",
            action="send_keys",
            target_pane=pane_id,
            keys=keys,
            shell_command=shell_command,
        )

    def submitted_shell_command(self, keys: list[str]) -> str | None:
        command_parts = []
        for key in keys:
            if key == "Enter":
                command = " ".join(command_parts).strip()
                return command or None
            command_parts.append(key)
        return None

    def run_steps(self) -> None:
        for index, step in enumerate(self.flow.get("steps", []), start=1):
            action = step.get("do")
            self.event("step.start", index=index, step=step)
            if action == "wait":
                self.wait(float(step.get("seconds", 1)))
            elif action == "snapshot":
                self.snapshot(step["as"])
            elif action == "ui_snapshot":
                self.ui_snapshot(step["as"])
            elif action == "cmd_t":
                self.cmd_t(step.get("from", "before"))
            elif action == "cmd_d":
                self.cmd_d(step.get("from", "before"), step.get("target", "primary_active"))
            elif action == "cmd_w":
                self.cmd_w(step.get("from", "before"), step.get("target", "primary_active"))
            elif action == "rename_window":
                self.rename_window(
                    step.get("from", "before"),
                    step.get("target", "primary_active"),
                    str(step["name"]),
                )
            elif action == "cmd_w_binding":
                self.cmd_w_binding(step.get("from", "before"), step.get("target", "primary_active"))
            elif action == "physical_shortcut":
                self.press_ghostty_shortcut(
                    str(step["key"]),
                    [str(modifier) for modifier in step.get("modifiers", [])],
                )
            elif action == "physical_shortcut_repeat":
                self.press_ghostty_shortcut_repeat(
                    str(step["key"]),
                    [str(modifier) for modifier in step.get("modifiers", [])],
                    int(step.get("count", 1)),
                    float(step.get("interval", 0.05)),
                )
            elif action == "ghostty_action":
                self.perform_ghostty_action(str(step["action"]))
            elif action == "ghostty_action_burst":
                self.perform_ghostty_action_burst(
                    str(step["action"]),
                    int(step.get("count", 1)),
                    float(step.get("interval", 0.05)),
                )
            elif action == "send_keys":
                self.send_keys(
                    step.get("from", "before"),
                    list(step.get("keys", [])),
                    step.get("target", "primary_active"),
                )
            else:
                raise FlowFailure(f"unknown step action: {action}")
            self.event("step.end", index=index, step=step)

    def assert_expectations(self) -> None:
        for expectation in self.flow.get("expect", []):
            self.assert_one(expectation)

    def assert_one(self, expectation: dict[str, Any]) -> None:
        if "state" in expectation:
            name = expectation["state"]
            if name not in self.states:
                raise FlowFailure(f"missing state for expectation: {name}")
            derived = self.states[name]["derived"]
            labels = {
                "workspaces": "workspaces",
                "windows": "windows",
                "windows_min": "windows",
                "windows_max": "windows",
                "panes": "panes",
                "panes_min": "panes",
                "panes_max": "panes",
                "raw_sessions": "raw_sessions",
                "raw_sessions_min": "raw_sessions",
                "raw_sessions_max": "raw_sessions",
                "lifo": "lifo",
                "dirty_windows": "dirty_windows",
                "dirty_panes": "dirty_panes",
            }
            for key, field in labels.items():
                if key not in expectation:
                    continue
                actual = derived[field]
                expected = expectation[key]
                if key.endswith("_min"):
                    ok = actual >= expected
                elif key.endswith("_max"):
                    ok = actual <= expected
                else:
                    ok = actual == expected
                if not ok:
                    raise FlowFailure(
                        f"{name}.{key} expected {expected}, got {actual}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            if "primary_window_names" in expectation:
                actual_names = derived["primary_window_names"]
                expected_names = expectation["primary_window_names"]
                if actual_names != expected_names:
                    raise FlowFailure(
                        f"{name}.primary_window_names expected {expected_names}, got {actual_names}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            return

        if "ui_state" in expectation:
            name = expectation["ui_state"]
            if name not in self.ui_states:
                raise FlowFailure(f"missing UI state for expectation: {name}")
            derived = self.ui_states[name]["derived"]
            labels = {
                "native_tabs": "native_tabs",
                "native_tabs_min": "native_tabs",
                "native_tabs_max": "native_tabs",
                "rail_tabs": "rail_tabs",
                "rail_tabs_min": "rail_tabs",
                "rail_tabs_max": "rail_tabs",
                "ui_enabled": "ui_enabled",
                "status_enabled": "status_enabled",
                "active_native_tab_index": "active_native_tab_index",
            }
            for key, field in labels.items():
                if key not in expectation:
                    continue
                actual = derived[field]
                expected = expectation[key]
                if key.endswith("_min"):
                    ok = actual >= expected
                elif key.endswith("_max"):
                    ok = actual <= expected
                else:
                    ok = actual == expected
                if not ok:
                    raise FlowFailure(
                        f"{name}.{key} expected {expected}, got {actual}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            if "native_tab_titles" in expectation:
                actual_titles = derived.get("native_tab_titles", [])
                expected_titles = expectation["native_tab_titles"]
                if actual_titles != expected_titles:
                    raise FlowFailure(
                        f"{name}.native_tab_titles expected {expected_titles}, got {actual_titles}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            for comparison in expectation.get("native_tab_id_matches", []):
                actual_ids = derived.get("native_tab_ids", [])
                source_name = str(comparison.get("ui_state"))
                if source_name not in self.ui_states:
                    raise FlowFailure(f"{name}.native_tab_id_matches source missing: {source_name}")
                source_ids = self.ui_states[source_name]["derived"].get("native_tab_ids", [])
                index = int(comparison["index"])
                source_index = int(comparison["source_index"])
                if index >= len(actual_ids) or source_index >= len(source_ids):
                    raise FlowFailure(
                        f"{name}.native_tab_id_matches out of range: actual={actual_ids}, "
                        f"source={source_ids}, comparison={comparison}"
                    )
                if actual_ids[index] != source_ids[source_index]:
                    raise FlowFailure(
                        f"{name}.native_tab_ids[{index}] expected {source_name}[{source_index}] "
                        f"{source_ids[source_index]}, got {actual_ids[index]}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            for comparison in expectation.get("native_tab_id_differs", []):
                actual_ids = derived.get("native_tab_ids", [])
                left = int(comparison["left"])
                right = int(comparison["right"])
                if left >= len(actual_ids) or right >= len(actual_ids):
                    raise FlowFailure(
                        f"{name}.native_tab_id_differs out of range: actual={actual_ids}, "
                        f"comparison={comparison}"
                    )
                if actual_ids[left] == actual_ids[right]:
                    raise FlowFailure(
                        f"{name}.native_tab_ids[{left}] unexpectedly equals index {right}; "
                        f"derived={json.dumps(derived, sort_keys=True)}"
                    )
            return

        if "delta" in expectation:
            delta = expectation["delta"]
            start = self.states[delta["from"]]["derived"]
            end = self.states[delta["to"]]["derived"]
            for key in ("workspaces", "windows", "panes", "raw_sessions"):
                if key not in expectation:
                    continue
                actual = end[key] - start[key]
                expected = expectation[key]
                if actual != expected:
                    raise FlowFailure(
                        f"delta {delta['from']}->{delta['to']} {key} "
                        f"expected {expected}, got {actual}; before={start}; after={end}"
                    )
            return

        raise FlowFailure(f"unknown expectation: {expectation}")

    def write_report(self, ok: bool, error: str | None = None) -> None:
        report = {
            "ok": ok,
            "name": self.name,
            "flow": str(self.flow_path),
            "run_dir": str(self.run_dir),
            "error": error,
            "states": {name: state["derived"] for name, state in self.states.items()},
            "ui_states": {name: state["derived"] for name, state in self.ui_states.items()},
            "events": len(self.events),
        }
        self.report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")

    def run(self) -> int:
        try:
            self.event("flow.start", name=self.name, flow=str(self.flow_path))
            self.setup()
            self.run_steps()
            self.assert_expectations()
            self.event("flow.pass", name=self.name)
            self.write_report(True)
            print(f"PASS {self.name}")
            print(f"run_dir={self.run_dir}")
            return 0
        except Exception as exc:  # noqa: BLE001 - report all failure detail.
            self.event("flow.fail", name=self.name, error=str(exc))
            self.write_report(False, str(exc))
            print(f"FAIL {self.name}", file=sys.stderr)
            print(str(exc), file=sys.stderr)
            print(f"run_dir={self.run_dir}", file=sys.stderr)
            return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("flow", type=Path)
    args = parser.parse_args()
    return FlowRunner(args.flow).run()


if __name__ == "__main__":
    raise SystemExit(main())
