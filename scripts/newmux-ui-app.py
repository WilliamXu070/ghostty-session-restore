#!/usr/bin/env python3
"""Windowed Newmux dashboard backed by the existing UI bridge snapshot API."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "scripts" / "newmux-ui-bridge.py"
LATEST_STATUS_FILE = ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status-path"


def load_bridge() -> Any:
    spec = importlib.util.spec_from_file_location("newmux_ui_bridge", BRIDGE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load bridge module: {BRIDGE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bridge = load_bridge()

try:
    import customtkinter as ctk
except Exception as exc:  # noqa: BLE001 - GUI import fallback is user-facing.
    raise SystemExit(f"customtkinter is required for the windowed dashboard: {exc}") from exc


def compact_path(path: str, max_len: int = 42) -> str:
    return bridge._compact_path(path, max_len=max_len)


def age(seconds: float) -> str:
    return bridge._age(seconds)


def default_status_path() -> Path:
    try:
        value = LATEST_STATUS_FILE.read_text().strip()
    except OSError:
        value = ""
    if value:
        return Path(value)
    return ROOT / ".local" / "newmux-ghostty" / "latest" / "ui-status.json"


def read_ghostty_status(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None


def visible_state(state: dict[str, Any], show_internal: bool) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, Any]]]:
    return (
        bridge._visible_sessions(state, show_internal),
        bridge._visible_windows(state, show_internal),
        bridge._visible_panes(state, show_internal),
    )


class NewmuxDashboard(ctk.CTk):
    def __init__(self, socket_name: str, socket_path: str | None, poll_interval: float, status_path: Path):
        super().__init__()
        self.socket_name = socket_name
        self.socket_path = socket_path
        self.poll_ms = max(100, int(poll_interval * 1000))
        self.newmux = bridge.Newmux(socket_name, socket_path)
        self.status_path = status_path
        self.known_windows: set[str] = set()
        self.new_until: dict[str, float] = {}
        self.show_internal = ctk.BooleanVar(value=False)
        self.running = True
        self.spinner_index = 0
        self.title("Newmux Dashboard")
        self.geometry("980x680")
        self.minsize(780, 480)
        ctk.set_appearance_mode("dark")
        ctk.set_default_color_theme("blue")
        self._build()
        self.after(60, self.refresh)

    def _build(self) -> None:
        self.grid_columnconfigure(0, weight=1)
        self.grid_rowconfigure(2, weight=1)

        top = ctk.CTkFrame(self, corner_radius=0)
        top.grid(row=0, column=0, sticky="ew")
        top.grid_columnconfigure(1, weight=1)

        self.title_label = ctk.CTkLabel(top, text="Newmux Dashboard", font=ctk.CTkFont(size=20, weight="bold"))
        self.title_label.grid(row=0, column=0, padx=18, pady=(14, 2), sticky="w")
        self.status_label = ctk.CTkLabel(top, text="connecting", text_color="#9ca3af")
        self.status_label.grid(row=1, column=0, padx=18, pady=(0, 14), sticky="w")

        controls = ctk.CTkFrame(top, fg_color="transparent")
        controls.grid(row=0, column=1, rowspan=2, padx=14, pady=12, sticky="e")
        self.internal_toggle = ctk.CTkCheckBox(
            controls,
            text="show internal",
            variable=self.show_internal,
            command=self.refresh_now,
        )
        self.internal_toggle.grid(row=0, column=0, padx=8)
        self.pause_button = ctk.CTkButton(controls, text="Pause", width=86, command=self.toggle_running)
        self.pause_button.grid(row=0, column=1, padx=8)
        self.refresh_button = ctk.CTkButton(controls, text="Refresh", width=86, command=self.refresh_now)
        self.refresh_button.grid(row=0, column=2, padx=8)

        stats = ctk.CTkFrame(self, corner_radius=8)
        stats.grid(row=1, column=0, padx=14, pady=12, sticky="ew")
        stats.grid_columnconfigure((0, 1, 2, 3, 4), weight=1)
        self.active_stat = self._stat(stats, 0, "Active Windows", "0")
        self.pane_stat = self._stat(stats, 1, "Panes", "0")
        self.lifo_stat = self._stat(stats, 2, "Deleted LIFO", "0")
        self.ghostty_stat = self._stat(stats, 3, "Ghostty Tabs", "-")
        self.sync_stat = self._stat(stats, 4, "UI Sync", "unknown")

        body = ctk.CTkFrame(self, corner_radius=8)
        body.grid(row=2, column=0, padx=14, pady=(0, 14), sticky="nsew")
        body.grid_columnconfigure(0, weight=3)
        body.grid_columnconfigure(1, weight=2)
        body.grid_rowconfigure(1, weight=1)
        body.grid_rowconfigure(3, weight=0)

        ctk.CTkLabel(body, text="Active Terminals", font=ctk.CTkFont(size=16, weight="bold")).grid(
            row=0, column=0, padx=14, pady=(12, 6), sticky="w"
        )
        ctk.CTkLabel(body, text="Deleted LIFO", font=ctk.CTkFont(size=16, weight="bold")).grid(
            row=0, column=1, padx=14, pady=(12, 6), sticky="w"
        )

        self.active_list = ctk.CTkScrollableFrame(body, corner_radius=6)
        self.active_list.grid(row=1, column=0, padx=(14, 7), pady=(0, 14), sticky="nsew")
        self.lifo_list = ctk.CTkScrollableFrame(body, corner_radius=6)
        self.lifo_list.grid(row=1, column=1, padx=(7, 14), pady=(0, 14), sticky="nsew")

        ctk.CTkLabel(body, text="UI Reader", font=ctk.CTkFont(size=16, weight="bold")).grid(
            row=2, column=0, columnspan=2, padx=14, pady=(0, 6), sticky="w"
        )
        self.sync_panel = ctk.CTkFrame(body, corner_radius=6)
        self.sync_panel.grid(row=3, column=0, columnspan=2, padx=14, pady=(0, 14), sticky="ew")
        self.sync_panel.grid_columnconfigure((0, 1, 2), weight=1)
        self.backend_label = ctk.CTkLabel(self.sync_panel, text="Backend: -", anchor="w", justify="left")
        self.backend_label.grid(row=0, column=0, padx=12, pady=10, sticky="ew")
        self.ghostty_label = ctk.CTkLabel(self.sync_panel, text="Ghostty: -", anchor="w", justify="left")
        self.ghostty_label.grid(row=0, column=1, padx=12, pady=10, sticky="ew")
        self.verdict_label = ctk.CTkLabel(self.sync_panel, text="Verdict: unknown", anchor="w", justify="left")
        self.verdict_label.grid(row=0, column=2, padx=12, pady=10, sticky="ew")

    def _stat(self, parent: ctk.CTkFrame, column: int, label: str, value: str) -> ctk.CTkLabel:
        box = ctk.CTkFrame(parent, corner_radius=6)
        box.grid(row=0, column=column, padx=8, pady=8, sticky="ew")
        ctk.CTkLabel(box, text=label, text_color="#9ca3af").pack(anchor="w", padx=12, pady=(10, 0))
        value_label = ctk.CTkLabel(box, text=value, font=ctk.CTkFont(size=26, weight="bold"))
        value_label.pack(anchor="w", padx=12, pady=(0, 10))
        return value_label

    def toggle_running(self) -> None:
        self.running = not self.running
        self.pause_button.configure(text="Pause" if self.running else "Resume")
        if self.running:
            self.refresh_now()

    def refresh_now(self) -> None:
        self.refresh(schedule=False)

    def refresh(self, schedule: bool = True) -> None:
        if self.running:
            try:
                state = self.newmux.snapshot()
                self.render(state)
            except Exception as exc:  # noqa: BLE001 - keep GUI alive while backend restarts.
                self.render_error(exc)
        if schedule:
            self.after(self.poll_ms, self.refresh)

    def render(self, state: dict[str, Any]) -> None:
        show_internal = bool(self.show_internal.get())
        sessions, windows, panes = visible_state(state, show_internal)
        workspaces = bridge._workspace_rows(sessions, windows, panes)
        window_ids = {window["id"] for workspace in workspaces for window in workspace["windows"].values()}
        pane_ids = {pane["id"] for workspace in workspaces for pane in workspace["panes"].values()}
        ghostty_status = read_ghostty_status(self.status_path)
        now = time.time()
        for window_id in window_ids - self.known_windows:
            self.new_until[window_id] = now + bridge.NEW_WINDOW_HIGHLIGHT_SECONDS
        self.known_windows = window_ids
        self.new_until = {wid: until for wid, until in self.new_until.items() if until > now and wid in window_ids}

        self.spinner_index = (self.spinner_index + 1) % 4
        spinner = "|/-\\"[self.spinner_index]
        stamp = time.strftime("%H:%M:%S", time.localtime(state["generated_at"]))
        self.status_label.configure(
            text=f"{spinner} live  socket={state['socket_name']}  rev={state['revision']}  updated={stamp}",
            text_color="#9ca3af",
        )
        self.active_stat.configure(text=str(len(window_ids)))
        self.pane_stat.configure(text=str(len(pane_ids)))
        self.lifo_stat.configure(text=str(len(state.get("recovery_stack", []))))
        self.render_sync(len(window_ids), len(pane_ids), len(state.get("recovery_stack", [])), ghostty_status)

        self._clear(self.active_list)
        self._clear(self.lifo_list)
        self.render_active(workspaces, panes)
        self.render_lifo(state.get("recovery_stack", []), now)

    def render_sync(self, backend_windows: int, backend_panes: int, lifo_count: int, ghostty_status: dict[str, Any] | None) -> None:
        self.backend_label.configure(
            text=f"Backend\nwindows={backend_windows}\npanes={backend_panes}\nlifo={lifo_count}"
        )
        if not ghostty_status:
            self.ghostty_stat.configure(text="-")
            self.sync_stat.configure(text="unknown", text_color="#f97316")
            self.ghostty_label.configure(text=f"Ghostty\nstatus unavailable\n{self.status_path}")
            self.verdict_label.configure(text="Verdict\nunknown\nGhostty status hook missing", text_color="#f97316")
            return

        native_tabs = int(ghostty_status.get("native_tab_count") or 0)
        rail_tabs = int(ghostty_status.get("rail_tab_count") or 0)
        active_index = ghostty_status.get("active_native_tab_index")
        updated_at = float(ghostty_status.get("updated_at") or 0)
        stale_seconds = max(0, time.time() - updated_at) if updated_at else 0
        self.ghostty_stat.configure(text=str(native_tabs))
        self.ghostty_label.configure(
            text=(
                "Ghostty\n"
                f"native_tabs={native_tabs}\n"
                f"rail_tabs={rail_tabs}\n"
                f"active_index={active_index}\n"
                f"age={age(stale_seconds)}"
            )
        )
        ok = backend_windows == native_tabs == rail_tabs
        if ok:
            self.sync_stat.configure(text="ok", text_color="#22c55e")
            self.verdict_label.configure(text="Verdict\nOK\nserver and UI agree", text_color="#22c55e")
            return
        reason = "stale UI tab" if backend_windows < native_tabs else "UI missing backend"
        self.sync_stat.configure(text="mismatch", text_color="#ef4444")
        self.verdict_label.configure(
            text=(
                "Verdict\nMISMATCH\n"
                f"{reason}\n"
                f"backend={backend_windows} native={native_tabs} rail={rail_tabs}"
            ),
            text_color="#ef4444",
        )

    def render_active(self, workspaces: list[dict[str, Any]], panes: list[dict[str, Any]]) -> None:
        panes_by_window: dict[str, list[dict[str, Any]]] = {}
        for pane in panes:
            panes_by_window.setdefault(pane["window_id"], []).append(pane)
        windows = [
            window
            for workspace in workspaces
            for window in workspace["windows"].values()
        ]
        windows.sort(key=lambda item: (item["index"], item["id"]))
        if not windows:
            self._empty(self.active_list, "No active terminals.")
            return
        for window in windows:
            window_panes = sorted(panes_by_window.get(window["id"], []), key=lambda item: item["index"])
            dirty = any(pane.get("dirty") for pane in window_panes)
            active = bool(window.get("active_views"))
            fresh = window["id"] in self.new_until
            primary = window_panes[0] if window_panes else {}
            title = f"{'* ' if active else ''}Window {window['index']}  {window['id']}"
            subtitle = (
                f"{len(window_panes)} pane{'s' if len(window_panes) != 1 else ''}  "
                f"{'dirty' if dirty else 'clean'}  "
                f"{primary.get('current_command') or '-'}  "
                f"{compact_path(primary.get('current_path') or '-')}"
            )
            self._card(self.active_list, title, subtitle, accent="#2563eb" if active else "#374151", fresh=fresh)
            if len(window_panes) > 1:
                for pane in window_panes:
                    pane_state = "dirty" if pane.get("dirty") else "clean"
                    detail = f"pane {pane['id']}  pid={pane['process_id']}  {pane_state}  {compact_path(pane['current_path'])}"
                    ctk.CTkLabel(self.active_list, text=detail, text_color="#9ca3af").pack(anchor="w", padx=20, pady=(0, 4))

    def render_lifo(self, items: list[dict[str, Any]], now: float) -> None:
        if not items:
            self._empty(self.lifo_list, "No deleted terminals.")
            return
        for item in items[:20]:
            panes = item.get("panes") or []
            dirty = any(pane.get("dirty") for pane in panes)
            deleted_at = float(item.get("deleted_at") or now)
            title = f"#{item.get('sequence', '-')}  {item.get('kind', '-')}  {item.get('window', '-')}"
            subtitle = (
                f"{item.get('mode', '-')}  {'dirty' if dirty else 'clean'}  "
                f"{len({pane.get('pane') for pane in panes if pane.get('pane')})} panes  "
                f"{age(max(0, now - deleted_at))} ago"
            )
            self._card(self.lifo_list, title, subtitle, accent="#7c2d12" if dirty else "#374151")

    def render_error(self, exc: Exception) -> None:
        self.spinner_index = (self.spinner_index + 1) % 4
        spinner = "|/-\\"[self.spinner_index]
        self.status_label.configure(text=f"{spinner} waiting for backend: {exc}", text_color="#f97316")
        self.active_stat.configure(text="-")
        self.pane_stat.configure(text="-")
        self.lifo_stat.configure(text="-")
        self.ghostty_stat.configure(text="-")
        self.sync_stat.configure(text="unknown", text_color="#f97316")
        self.backend_label.configure(text="Backend\nunavailable")
        self.ghostty_label.configure(text="Ghostty\nnot checked")
        self.verdict_label.configure(text=f"Verdict\nunknown\n{exc}", text_color="#f97316")
        self._clear(self.active_list)
        self._clear(self.lifo_list)
        self._empty(self.active_list, "Backend unavailable.")
        self._empty(self.lifo_list, "Recovery stack unavailable.")

    def _card(self, parent: ctk.CTkScrollableFrame, title: str, subtitle: str, *, accent: str, fresh: bool = False) -> None:
        card = ctk.CTkFrame(parent, corner_radius=6, border_width=1, border_color=accent)
        card.pack(fill="x", padx=6, pady=6)
        row = ctk.CTkFrame(card, fg_color="transparent")
        row.pack(fill="x", padx=12, pady=(10, 2))
        ctk.CTkLabel(row, text=title, font=ctk.CTkFont(size=14, weight="bold")).pack(side="left")
        if fresh:
            ctk.CTkLabel(row, text="new", text_color="#60a5fa").pack(side="right")
        ctk.CTkLabel(card, text=subtitle, text_color="#9ca3af", anchor="w", justify="left").pack(
            fill="x", padx=12, pady=(0, 10)
        )

    def _empty(self, parent: ctk.CTkScrollableFrame, text: str) -> None:
        ctk.CTkLabel(parent, text=text, text_color="#9ca3af").pack(anchor="w", padx=14, pady=14)

    def _clear(self, parent: ctk.CTkScrollableFrame) -> None:
        for child in parent.winfo_children():
            child.destroy()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket-name", default="newmux-dev")
    parser.add_argument("--socket-path")
    parser.add_argument("--poll-interval", type=float, default=0.3)
    parser.add_argument("--status-file", type=Path, default=default_status_path())
    args = parser.parse_args()
    app = NewmuxDashboard(args.socket_name, args.socket_path, args.poll_interval, args.status_file)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
