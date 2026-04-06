#!/usr/bin/env python3
from __future__ import annotations

import argparse
import curses
import os
import re
import shlex
import subprocess
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, List, Optional, Sequence


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
STATE_FILE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "gassianrobot_easy_autonomy_last_run"
DEFAULT_ITERS = "30000"
DEFAULT_PORT = "7007"
DEFAULT_DURATION = "20"
DEFAULT_DAYS = "30"


def detect_total_ram_gb() -> Optional[int]:
    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        page_count = os.sysconf("SC_PHYS_PAGES")
    except (AttributeError, ValueError, OSError):
        return None

    if page_size <= 0 or page_count <= 0:
        return None

    total_bytes = page_size * page_count
    gib = 1024 ** 3
    return max(1, (total_bytes + gib - 1) // gib)


def recommended_memory_profile(total_gb: Optional[int]) -> str:
    if total_gb is None or total_gb <= 12:
        return "low"
    if total_gb <= 24:
        return "medium"
    return "high"


def memory_profile_label(profile: str) -> str:
    return {
        "low": "Safer Fewer Frames (8 GB RAM or less)",
        "medium": "Balanced Memory And Quality (16 GB RAM)",
        "high": "Highest Detail And Memory Use (32 GB RAM or more)",
    }.get(profile, profile)


def memory_profile_downscale(profile: str) -> str:
    return {
        "low": "3",
        "medium": "2",
        "high": "1",
    }.get(profile, "2")


@dataclass
class RunInfo:
    path: Path
    rel: str
    badges: List[str]

    @property
    def label(self) -> str:
        if self.badges:
            return f"{self.rel} " + " ".join(f"[{badge}]" for badge in self.badges)
        return self.rel


@dataclass
class ViewerContainerInfo:
    name: str
    label: str


@dataclass
class MenuItem:
    label: str
    action: Callable[[], None]


class App:
    def __init__(self, stdscr: curses.window, safe_mode: bool, start_section: str) -> None:
        self.stdscr = stdscr
        self.safe_mode = safe_mode
        self.start_section = start_section
        self.status = "Ready"
        self.running = True
        self.guided_run_override: Optional[Path] = None
        self.total_ram_gb = detect_total_ram_gb()

    def run(self) -> None:
        curses.curs_set(0)
        self.stdscr.keypad(True)
        curses.use_default_colors()

        if self.start_section:
            handler = {
                "robot-scan": self.robot_scan_menu,
                "robot-tools": self.robot_tools_menu,
                "handheld": self.handheld_capture_menu,
                "gaussian": self.gaussian_menu,
                "runs": self.runs_menu,
                "builds": self.builds_menu,
                "diagnostics": self.diagnostics_menu,
            }.get(self.start_section)
            if handler is not None:
                handler()
            else:
                self.show_message("Unknown Section", f"Unknown start section: {self.start_section}")

        while self.running:
            self.menu_loop(
                "GassianRobot Master TUI",
                [
                    MenuItem("Scan A Room With The Robot (recommended)", self.robot_scan_menu),
                    MenuItem("Advanced Robot Tools", self.robot_tools_menu),
                    MenuItem("Capture With Handheld Camera", self.handheld_capture_menu),
                    MenuItem("Make A 3D Browser View From A Saved Run", self.gaussian_menu),
                    MenuItem("Saved Runs", self.runs_menu),
                    MenuItem("Build And Setup", self.builds_menu),
                    MenuItem("Troubleshooting", self.diagnostics_menu),
                    MenuItem("Toggle Preview Mode", self.toggle_safe_mode),
                    MenuItem("Simple Guide", self.show_master_quick_guide),
                    MenuItem("Exit", self.quit),
                ],
                subtitle="Arrow keys to move, Enter to select, q to back/quit.",
            )
            self.running = False

    def quit(self) -> None:
        self.running = False

    def toggle_safe_mode(self) -> None:
        self.safe_mode = not self.safe_mode
        mode = "SAFE MODE" if self.safe_mode else "LIVE"
        self.status = f"Mode changed to {mode}"

    def menu_loop(self, title: str, items: Sequence[MenuItem], subtitle: str = "") -> None:
        index = 0
        top = 0
        while self.running:
            height, width = self.stdscr.getmaxyx()
            visible_rows = max(5, height - 6)
            if index < top:
                top = index
            if index >= top + visible_rows:
                top = index - visible_rows + 1

            self.stdscr.erase()
            self.draw_header(title, subtitle)
            for row, item in enumerate(items[top : top + visible_rows], start=0):
                y = 2 + row
                attr = curses.A_REVERSE if top + row == index else curses.A_NORMAL
                self.stdscr.addnstr(y, 2, item.label, max(1, width - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(items)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(items)
            elif key in (10, 13, curses.KEY_ENTER):
                item = items[index]
                normalized = item.label.lower()
                if normalized in {"quit", "exit"}:
                    self.quit()
                    return
                if normalized == "back":
                    return
                item.action()
                if not self.running:
                    return
            elif key in (27, ord("q")):
                return

    def draw_header(self, title: str, subtitle: str) -> None:
        _, width = self.stdscr.getmaxyx()
        mode = "SAFE MODE" if self.safe_mode else "LIVE"
        header = f"{title} [{mode}]"
        self.stdscr.addnstr(0, 2, header, max(1, width - 4), curses.A_BOLD)
        if subtitle:
            self.stdscr.addnstr(1, 2, subtitle, max(1, width - 4))

    def draw_footer(self) -> None:
        height, width = self.stdscr.getmaxyx()
        footer = self.status
        if len(footer) > width - 4:
            footer = footer[: width - 7] + "..."
        self.stdscr.hline(height - 2, 0, "-", width)
        self.stdscr.addnstr(height - 1, 2, footer, max(1, width - 4))

    def show_message(self, title: str, message: str) -> None:
        lines: List[str] = []
        width = max(20, self.stdscr.getmaxyx()[1] - 6)
        for raw_line in message.splitlines() or [""]:
            wrapped = textwrap.wrap(raw_line, width=width) or [""]
            lines.extend(wrapped)

        index = 0
        while True:
            height, width = self.stdscr.getmaxyx()
            visible = max(4, height - 5)
            self.stdscr.erase()
            self.draw_header(title, "Up/down to scroll, Enter/q to close.")
            for row, line in enumerate(lines[index : index + visible], start=0):
                self.stdscr.addnstr(2 + row, 2, line, max(1, width - 4))
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.getch()
            if key in (10, 13, curses.KEY_ENTER, 27, ord("q")):
                return
            if key in (curses.KEY_UP, ord("k")) and index > 0:
                index -= 1
            elif key in (curses.KEY_DOWN, ord("j")) and index + visible < len(lines):
                index += 1

    def confirm(self, title: str, prompt: str) -> bool:
        wrapped: List[str] = []
        width = max(20, self.stdscr.getmaxyx()[1] - 10)
        for raw_line in prompt.splitlines() or [""]:
            wrapped.extend(textwrap.wrap(raw_line, width=width) or [""])

        while True:
            height, width = self.stdscr.getmaxyx()
            self.stdscr.erase()
            self.draw_header(title, "y = yes, n = no, Esc = cancel")
            for row, line in enumerate(wrapped[: max(4, height - 6)], start=0):
                self.stdscr.addnstr(2 + row, 2, line, max(1, width - 4))
            self.draw_footer()
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (ord("y"), ord("Y")):
                return True
            if key in (ord("n"), ord("N"), 27, ord("q")):
                return False

    def prompt_input(self, title: str, prompt: str, default: str) -> Optional[str]:
        curses.curs_set(1)
        value = default
        while True:
            self.stdscr.erase()
            self.draw_header(title, prompt)
            self.stdscr.addstr(3, 2, value)
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.get_wch()
            if key in ("\n", "\r"):
                curses.curs_set(0)
                return value.strip() or default
            if key == "\x1b":
                curses.curs_set(0)
                return None
            if key in ("\x7f", "\b") or key == curses.KEY_BACKSPACE:
                value = value[:-1]
            elif isinstance(key, str) and key.isprintable():
                value += key

    def run_command(
        self,
        cmd: Sequence[str],
        *,
        safe_behavior: str = "pass",
        extra_safe_args: Sequence[str] = (),
    ) -> None:
        command = list(cmd)
        if self.safe_mode:
            if safe_behavior == "preview":
                self.preview_command(command)
                return
            if safe_behavior == "append-dry-run":
                for arg in extra_safe_args:
                    if arg not in command:
                        command.append(arg)
        self.status = "Running: " + shlex.join(command)

        curses.def_prog_mode()
        curses.endwin()
        try:
            print(f"Repo: {REPO_ROOT}")
            print("Command:", shlex.join(command))
            print("")
            subprocess.run(command, cwd=REPO_ROOT, check=False)
            input("\nPress Enter to return to the ncurses UI...")
        finally:
            self.stdscr.refresh()
            curses.reset_prog_mode()
            curses.curs_set(0)
            self.stdscr.keypad(True)
            self.status = "Ready"

    def preview_command(self, cmd: Sequence[str]) -> None:
        self.show_message("Safe Mode Preview", "Command not executed:\n\n" + shlex.join(list(cmd)))

    def run_capture(self, cmd: Sequence[str]) -> str:
        result = subprocess.run(cmd, cwd=REPO_ROOT, text=True, capture_output=True, check=False)
        parts = []
        if result.stdout.strip():
            parts.append(result.stdout.strip())
        if result.stderr.strip():
            parts.append(result.stderr.strip())
        return "\n\n".join(parts).strip() or "(no output)"

    def list_runs(self) -> List[RunInfo]:
        runs_dir = REPO_ROOT / "runs"
        if not runs_dir.is_dir():
            return []
        candidates = [path for path in runs_dir.glob("*") if path.is_dir() and path.name not in {"_template", ".trash"}]
        candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
        return [RunInfo(path=path, rel=str(path.relative_to(REPO_ROOT)), badges=self.compute_badges(path)) for path in candidates]

    def compute_badges(self, run_dir: Path) -> List[str]:
        badges: List[str] = []
        if self.is_trainable(run_dir):
            badges.append("trainable")
        if self.is_jetson_gsplat_trainable(run_dir):
            badges.append("jetson-gsplat")
        if (run_dir / "rtabmap.db").is_file():
            badges.append("rtabmap-db")
        if self.is_viewer_ready(run_dir):
            badges.append("viewer-ready")
        if (run_dir / "exports" / "splat" / "splat.ply").is_file():
            badges.append("exported")
        if self.has_train_logs(run_dir):
            badges.append("train-logs")
        if (run_dir / "logs" / "train_job.pid").is_file():
            try:
                pid = int((run_dir / "logs" / "train_job.pid").read_text().strip())
                os.kill(pid, 0)
                badges.append("train-running")
            except Exception:
                pass
        status_file = run_dir / "logs" / "train_job.status"
        if status_file.is_file():
            state = self.read_status_value(status_file, "state")
            exit_code = self.read_status_value(status_file, "exit_code")
            if state == "exited":
                badges.append(f"train-exited:{exit_code}" if exit_code else "train-exited")
        return badges

    def read_status_value(self, status_file: Path, key: str) -> str:
        if not status_file.is_file():
            return ""
        prefix = f"{key}="
        for line in status_file.read_text().splitlines():
            if line.startswith(prefix):
                return line[len(prefix) :]
        return ""

    def is_trainable(self, run_dir: Path) -> bool:
        return any(
            [
                (run_dir / "raw" / "capture.mp4").is_file(),
                (run_dir / "gs_input.env").is_file(),
                (run_dir / "rtabmap.db").is_file(),
                (run_dir / "dataset" / "transforms.json").is_file(),
            ]
        )

    def is_jetson_gsplat_trainable(self, run_dir: Path) -> bool:
        return (run_dir / "rtabmap.db").is_file() or (run_dir / "dataset" / "transforms.json").is_file()

    def is_viewer_ready(self, run_dir: Path) -> bool:
        for config_path in (run_dir / "checkpoints").glob("**/config.yml"):
            if (config_path.parent / "nerfstudio_models").is_dir():
                return True
        return False

    def has_train_logs(self, run_dir: Path) -> bool:
        logs_dir = run_dir / "logs"
        return (logs_dir / "train_job.latest.log").exists() or any(logs_dir.glob("train_job_*.log"))

    def has_training_metadata(self, run_dir: Path) -> bool:
        logs_dir = run_dir / "logs"
        return (logs_dir / "train_job.pid").is_file() or (logs_dir / "train_job.status").is_file() or self.has_train_logs(run_dir)

    def guided_runs(self) -> List[RunInfo]:
        runs: List[RunInfo] = []
        for run in self.list_runs():
            if self.is_trainable(run.path) or self.is_viewer_ready(run.path) or (run.path / "rtabmap.db").is_file():
                runs.append(run)
        return runs

    def run_info_for_path(self, run_path: Path) -> Optional[RunInfo]:
        for run in self.list_runs():
            if run.path == run_path:
                return run
        return None

    def scan_history_entries(self) -> List[str]:
        entries: List[str] = []
        remembered_run = self.current_scan_run_label()
        count = 0
        for run in self.list_runs():
            log_file = run.path / "logs" / "auto_scan_mission.log"
            if not log_file.is_file():
                continue
            text = log_file.read_text(errors="ignore")
            mode = "dry-run" if re.search(r"^\[[0-9:]+\] dry_run=1$", text, flags=re.MULTILINE) else "live"
            result = "complete" if re.search(r"^\[[0-9:]+\] mission complete$", text, flags=re.MULTILINE) else "needs-review"
            suffix = " [last prepared run]" if run.path.name == remembered_run else ""
            count += 1
            entries.append(
                f"{count}. {run.rel}{suffix} | {mode} | {result} | "
                f"rtabmap_db={'yes' if (run.path / 'rtabmap.db').is_file() else 'no'} | "
                f"waypoints={'yes' if (run.path / 'live_scan_waypoints.tsv').is_file() else 'no'}"
            )
        if not entries:
            return ["No scan runs were found yet.", "", "A run appears here after a scan mission creates logs/auto_scan_mission.log."]
        entries.extend(["", f"Total scan runs: {count}"])
        return entries

    def select_run(self, context: str, title: str) -> Optional[RunInfo]:
        all_runs = self.list_runs()
        if context == "trainable":
            runs = [run for run in all_runs if self.is_trainable(run.path)]
        elif context == "jetson_gsplat_trainable":
            runs = [run for run in all_runs if self.is_jetson_gsplat_trainable(run.path)]
        elif context == "guided":
            runs = self.guided_runs()
        elif context == "viewer_ready":
            runs = [run for run in all_runs if self.is_viewer_ready(run.path)]
        elif context == "train_logs":
            runs = [run for run in all_runs if self.has_train_logs(run.path)]
        elif context == "train_metadata":
            runs = [run for run in all_runs if self.has_training_metadata(run.path)]
        else:
            runs = all_runs

        if not runs:
            self.show_message(title, f"No runs found for context: {context}")
            return None

        index = 0
        top = 0
        while True:
            height, width = self.stdscr.getmaxyx()
            visible_rows = max(5, height - 6)
            if index < top:
                top = index
            if index >= top + visible_rows:
                top = index - visible_rows + 1

            self.stdscr.erase()
            self.draw_header(title, "Enter to select, q to cancel.")
            for row, run in enumerate(runs[top : top + visible_rows], start=0):
                y = 2 + row
                attr = curses.A_REVERSE if top + row == index else curses.A_NORMAL
                self.stdscr.addnstr(y, 2, run.label, max(1, width - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(runs)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(runs)
            elif key in (10, 13, curses.KEY_ENTER):
                return runs[index]
            elif key in (27, ord("q")):
                return None

    def select_trash_entry(self) -> Optional[str]:
        trash_root = REPO_ROOT / "runs" / ".trash"
        if not trash_root.is_dir():
            self.show_message("Restore Run", f"No trash directory exists yet ({trash_root}).")
            return None
        entries = sorted((path.name for path in trash_root.iterdir() if path.is_dir()), reverse=True)
        if not entries:
            self.show_message("Restore Run", "No entries found in runs/.trash.")
            return None

        index = 0
        top = 0
        while True:
            height, width = self.stdscr.getmaxyx()
            visible_rows = max(5, height - 6)
            if index < top:
                top = index
            if index >= top + visible_rows:
                top = index - visible_rows + 1

            self.stdscr.erase()
            self.draw_header("Restore Run", "Enter to select a trash entry, q to cancel.")
            for row, entry in enumerate(entries[top : top + visible_rows], start=0):
                y = 2 + row
                attr = curses.A_REVERSE if top + row == index else curses.A_NORMAL
                self.stdscr.addnstr(y, 2, entry, max(1, width - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(entries)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(entries)
            elif key in (10, 13, curses.KEY_ENTER):
                return entries[index]
            elif key in (27, ord("q")):
                return None

    def viewer_container_name_for_run(self, run: RunInfo) -> str:
        run_slug = re.sub(r"[^A-Za-z0-9]+", "_", run.path.name)
        return f"gs_viewer_{run_slug}"

    def viewer_container_choices(self) -> List[ViewerContainerInfo]:
        choices: List[ViewerContainerInfo] = []
        try:
            result = subprocess.run(
                ["docker", "ps", "--format", "{{.Names}}"],
                cwd=REPO_ROOT,
                text=True,
                capture_output=True,
                check=False,
            )
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    name = line.strip()
                    if not name.startswith("gs_viewer_"):
                        continue
                    choices.append(ViewerContainerInfo(name=name, label=f"{name} [running browser view]"))
        except FileNotFoundError:
            pass

        if choices or not self.safe_mode:
            return choices

        for run in self.list_runs():
            if self.is_viewer_ready(run.path):
                name = self.viewer_container_name_for_run(run)
                choices.append(ViewerContainerInfo(name=name, label=f"{name} [{run.rel}]"))
        return choices

    def select_viewer_container(self, title: str) -> Optional[ViewerContainerInfo]:
        choices = self.viewer_container_choices()
        if not choices:
            self.show_message(title, "No running browser views were found.")
            return None

        index = 0
        top = 0
        while True:
            height, width = self.stdscr.getmaxyx()
            visible_rows = max(5, height - 6)
            if index < top:
                top = index
            if index >= top + visible_rows:
                top = index - visible_rows + 1

            self.stdscr.erase()
            self.draw_header(title, "Enter to select a browser view, q to cancel.")
            for row, choice in enumerate(choices[top : top + visible_rows], start=0):
                y = 2 + row
                attr = curses.A_REVERSE if top + row == index else curses.A_NORMAL
                self.stdscr.addnstr(y, 2, choice.label, max(1, width - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()

            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(choices)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(choices)
            elif key in (10, 13, curses.KEY_ENTER):
                return choices[index]
            elif key in (27, ord("q")):
                return None

    def default_scan_run_name(self) -> str:
        return subprocess.run(["date", "+%F-%H%M"], text=True, capture_output=True, check=False).stdout.strip() + "-easy-auto-scan"

    def load_last_scan_run(self) -> str:
        if STATE_FILE.is_file():
            return STATE_FILE.read_text().strip()
        return ""

    def save_last_scan_run(self, run_name: str) -> None:
        STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        STATE_FILE.write_text(run_name + "\n")

    def current_scan_run_label(self) -> str:
        return self.load_last_scan_run() or "none"

    def current_scan_run_path(self) -> Optional[Path]:
        run_name = self.load_last_scan_run()
        if not run_name:
            return None
        run_dir = REPO_ROOT / "runs" / run_name
        if run_dir.is_dir():
            return run_dir
        return None

    def selected_guided_run(self) -> Optional[RunInfo]:
        if self.guided_run_override is not None:
            run = self.run_info_for_path(self.guided_run_override)
            if run is not None:
                return run

        current_scan = self.current_scan_run_path()
        if current_scan is not None:
            run = self.run_info_for_path(current_scan)
            if run is not None:
                return run

        guided_runs = self.guided_runs()
        if guided_runs:
            return guided_runs[0]
        return None

    def guided_run_state(self, run: Optional[RunInfo]) -> tuple[str, str, List[str]]:
        if run is None:
            return (
                "No scan selected yet",
                "Create a run in Scan A Room With The Robot or Capture With Handheld Camera.",
                [
                    "No scan or training run is selected yet.",
                    "Create a run in Scan A Room With The Robot or Capture With Handheld Camera, then come back here.",
                ],
            )

        run_dir = run.path
        has_raw = (run_dir / "raw" / "capture.mp4").is_file()
        has_db = (run_dir / "rtabmap.db").is_file()
        has_dataset = (run_dir / "dataset" / "transforms.json").is_file()
        has_gs_input = (run_dir / "gs_input.env").is_file()
        viewer_ready = self.is_viewer_ready(run_dir)
        exported = (run_dir / "exports" / "splat" / "splat.ply").is_file()
        state = self.read_status_value(run_dir / "logs" / "train_job.status", "state")
        exit_code = self.read_status_value(run_dir / "logs" / "train_job.status", "exit_code")
        train_running = "train-running" in run.badges

        lines = [
            f"Selected run: {run.rel}",
            "",
            f"RTAB-Map database: {'yes' if has_db else 'no'}",
            f"Raw video capture: {'yes' if has_raw else 'no'}",
            f"Training input ready: {'yes' if has_dataset or has_gs_input else 'no'}",
            f"Training job running: {'yes' if train_running else 'no'}",
            f"Browser-ready model: {'yes' if viewer_ready else 'no'}",
            f"Exported splat file: {'yes' if exported else 'no'}",
        ]

        if train_running:
            stage = "Training is in progress"
            next_step = "Watch training progress, then open it in the browser when finished."
        elif viewer_ready:
            stage = "Model is ready to open in a browser"
            next_step = "Open the model in the browser."
        elif has_dataset or has_gs_input:
            stage = "Training input is ready"
            next_step = "Start 3D model training."
        elif has_db or has_raw:
            stage = "Scan data exists but it is not prepared for training yet"
            next_step = "Prepare this run for 3D model training."
        else:
            stage = "This run is missing usable scan data"
            next_step = "Pick a different run or create one in Scan A Room With The Robot or Capture With Handheld Camera."

        if state == "exited":
            lines.append(f"Last training exit code: {exit_code or 'unknown'}")
            if exit_code and exit_code != "0":
                next_step = "Review the training logs, then retry training."

        return stage, next_step, lines

    def show_guided_status(self) -> None:
        run = self.selected_guided_run()
        stage, next_step, lines = self.guided_run_state(run)
        self.show_message(
            "Guided Status",
            "\n".join(lines + ["", f"Current stage: {stage}", f"Recommended next step: {next_step}"]),
        )

    def choose_guided_run(self) -> None:
        run = self.select_run("guided", "Choose Guided Run")
        if run is None:
            return
        self.guided_run_override = run.path
        self.status = f"Selected run: {run.rel}"

    def run_scan_command(self, run_name: str, action: str) -> None:
        self.save_last_scan_run(run_name)
        self.guided_run_override = None
        self.run_command(
            ["env", f"RUN_NAME={run_name}", str(SCRIPTS_DIR / "robot/launch_live_auto_scan.sh"), action],
            safe_behavior="preview",
        )

    def choose_training_mode(self) -> Optional[str]:
        options = [
            ("Prepare Then Train 3D Model (recommended)", "prep-train"),
            ("Train Using Existing Prepared Data Only", "train"),
            ("Only Prepare Run For Training", "prep"),
        ]
        index = 0
        while True:
            self.stdscr.erase()
            self.draw_header("Training Mode", "Choose what should happen next. Enter to select, q to cancel.")
            for row, item in enumerate(options, start=0):
                attr = curses.A_REVERSE if row == index else curses.A_NORMAL
                self.stdscr.addnstr(2 + row, 2, item[0], max(1, self.stdscr.getmaxyx()[1] - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(options)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(options)
            elif key in (10, 13, curses.KEY_ENTER):
                return options[index][1]
            elif key in (27, ord("q")):
                return None

    def choose_memory_profile(self) -> Optional[str]:
        recommended = recommended_memory_profile(self.total_ram_gb)
        subtitle = "Choose the memory level for this training run."
        if self.total_ram_gb is not None:
            subtitle += f" Detected system memory: about {self.total_ram_gb} GB."
        subtitle += f" Recommended: {memory_profile_label(recommended)}"

        if (
            os.environ.get("MASTER_TUI_AUTOTEST") == "1"
            or os.environ.get("GASSIAN_TUI_AUTOTEST") == "1"
            or os.environ.get("GS_TUI_AUTOTEST") == "1"
        ):
            return recommended

        options = [
            (memory_profile_label("low"), "low"),
            (memory_profile_label("medium"), "medium"),
            (memory_profile_label("high"), "high"),
        ]
        index = next((i for i, item in enumerate(options) if item[1] == recommended), 0)
        while True:
            self.stdscr.erase()
            self.draw_header("Memory Level", subtitle + " Enter to select, q to cancel.")
            for row, item in enumerate(options, start=0):
                attr = curses.A_REVERSE if row == index else curses.A_NORMAL
                self.stdscr.addnstr(2 + row, 2, item[0], max(1, self.stdscr.getmaxyx()[1] - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(options)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(options)
            elif key in (10, 13, curses.KEY_ENTER):
                return options[index][1]
            elif key in (27, ord("q")):
                return None

    def show_master_quick_guide(self) -> None:
        self.show_message(
            "Quick Guide",
            "\n".join(
                [
                    "Use Scan A Room With The Robot for the normal supervised robot scan flow.",
                    "Use Advanced Robot Tools for manual driving, health checks, and lower-level robot setup.",
                    "Use Capture With Handheld Camera only when you want to create a run with a handheld camera instead of the robot.",
                    "Use Make A 3D Browser View From A Saved Run after you already have a run and want a browser-viewable model.",
                    "Inside that menu, start with the guided option if you want the simplest path.",
                    "Use Saved Runs to inspect, delete, or restore runs.",
                    "Use Build And Setup or Troubleshooting only when you need maintenance or recovery tools.",
                ]
            ),
        )

    def show_robot_scan_quick_guide(self) -> None:
        self.show_message(
            "Robot Scan Guide",
            "\n".join(
                [
                    'Recommended order:',
                    '1. "Start A Room Scan Now" for the normal one-command workflow.',
                    '2. "Get Ready To Scan Without Moving Yet" and then "Start The Prepared Scan" only when you want to inspect first.',
                    '3. "Show Robot And Scan Status" or "Send Robot To Dock" to recover or check the session.',
                    '4. After the scan finishes, open "Make A 3D Browser View From A Saved Run" and choose the guided option.',
                    "",
                    "Safety:",
                    "- Keep the robot on the floor.",
                    "- Keep the dock area and the first meter ahead clear.",
                    "- Stay nearby while it moves.",
                ]
            ),
        )

    def show_gaussian_plain_english_guide(self) -> None:
        self.show_message(
            "Scan To Browser Guide",
            "\n".join(
                [
                    "This section turns an existing run into a 3D model you can open in a web browser.",
                    "",
                    "Normal order:",
                    "1. Create a run with Scan A Room With The Robot or Capture With Handheld Camera.",
                    "2. Prepare that scan for training.",
                    "3. Choose a memory level that fits this machine.",
                    "4. Start training the 3D model.",
                    "5. Open the finished model in the browser.",
                    "",
                    "Lower-memory choices keep fewer frames so training is more likely to finish on smaller Jetson-class machines.",
                    "Use the guided option if you do not know which step comes next.",
                ]
            ),
        )

    def show_handheld_plain_english_guide(self) -> None:
        self.show_message(
            "Handheld Capture Guide",
            "\n".join(
                [
                    "Use this section only if you want to create a new run with a handheld camera.",
                    "",
                    "Normal order:",
                    "1. Check camera health.",
                    "2. Capture a short handheld scan.",
                    "3. Then move to Turn Scan Into 3D Browser View for training and browser viewing.",
                ]
            ),
        )

    def robot_scan_menu(self) -> None:
        self.menu_loop(
            "Scan A Room With The Robot",
            [
                MenuItem("Start A Room Scan Now (recommended)", self.full_scan_now),
                MenuItem("Get Ready To Scan Without Moving Yet", self.prepare_scan_stack),
                MenuItem("Start The Prepared Scan", self.start_prepared_mission),
                MenuItem("Show Robot And Scan Status", self.show_scan_status),
                MenuItem("Show Previous Robot Scans", self.show_scan_history),
                MenuItem("Send Robot To Dock", self.dock_robot),
                MenuItem("Undock Robot", self.undock_robot),
                MenuItem("Explain Robot Scan", self.show_robot_scan_quick_guide),
                MenuItem("Back", lambda: None),
            ],
            subtitle=f"Last prepared run: {self.current_scan_run_label()}",
        )

    def full_scan_now(self) -> None:
        if not self.confirm(
            "Before Starting Motion",
            "Before starting motion:\n\n"
            "- Robot is on the dock or flat on the floor\n"
            "- Create 3 USB-C link is connected\n"
            "- OAK is connected\n"
            "- Floor area near the dock is clear\n"
            "- A person is nearby to supervise",
        ):
            return
        self.run_scan_command(self.default_scan_run_name(), "start")

    def prepare_scan_stack(self) -> None:
        if not self.confirm(
            "Prepare Scan Stack",
            "Bring up the full scan stack without motion?\n\n"
            "Use this when you want to inspect the stack before letting the robot move.",
        ):
            return
        self.run_scan_command(self.default_scan_run_name(), "start-only")

    def start_prepared_mission(self) -> None:
        run_name = self.load_last_scan_run()
        if not run_name:
            self.show_message(
                "No Prepared Run",
                'There is no remembered run name yet.\n\nUse "Prepare Scan Stack Without Motion" first, or use "Run Full Scan Now".',
            )
            return
        if not self.confirm(
            "Start Prepared Mission",
            f"Start the prepared mission for {run_name}?\n\n"
            "Make sure the floor area near the dock is clear and a person is nearby to supervise.",
        ):
            return
        self.run_scan_command(run_name, "mission")

    def show_scan_status(self) -> None:
        dock = self.run_capture([str(SCRIPTS_DIR / "robot/create3_dock_control.sh"), "status"])
        stack = self.run_capture([str(SCRIPTS_DIR / "robot/launch_live_auto_scan.sh"), "status"])
        self.show_message(
            "Robot + Scan Status",
            "\n".join(
                [
                    f"Repo: {REPO_ROOT}",
                    f"Last run: {self.current_scan_run_label()}",
                    "",
                    "--- Dock status ---",
                    dock,
                    "",
                    "--- Scan stack status ---",
                    stack,
                ]
            ),
        )

    def show_scan_history(self) -> None:
        self.show_message("Previous Scan Runs", "\n".join(self.scan_history_entries()))

    def run_robot_health_check(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/create3_base_health_check.sh")], safe_behavior="preview")

    def dock_robot(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/create3_dock_control.sh"), "dock"], safe_behavior="preview")

    def undock_robot(self) -> None:
        if not self.confirm("Undock Robot", "Undock the robot now?\n\nMake sure the floor area ahead of the dock is clear."):
            return
        self.run_command([str(SCRIPTS_DIR / "robot/create3_dock_control.sh"), "undock"], safe_behavior="preview")

    def manual_drive(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/teleop_drive_app.sh")], safe_behavior="preview")

    def robot_tools_menu(self) -> None:
        self.menu_loop(
            "Advanced Robot Tools",
            [
                MenuItem("Check Robot Connection", self.connection_report),
                MenuItem("Run Robot Health Check", self.run_robot_health_check),
                MenuItem("Drive Robot Manually", self.manual_drive),
                MenuItem("Drive With GameCube Controller", self.gamecube_teleop),
                MenuItem("Drive With Arrow Keys", self.teleop_arrows),
                MenuItem("Drive With Keyboard", self.teleop_keyboard),
                MenuItem("Check ROS Health", self.ros_health_check),
                MenuItem("Run Autonomy Preflight Check", self.preflight_autonomy),
                MenuItem("Check Software Setup", self.software_readiness_audit),
                MenuItem("Show Advanced Startup Notes", self.guided_nav2_start),
                MenuItem("Start Robot Runtime", self.run_robot_runtime_container),
                MenuItem("Start Camera Driver", self.run_oak_camera),
                MenuItem("Start Live Mapping", self.run_rtabmap_rgbd),
                MenuItem("Record Raw Sensor Data", self.record_raw_bag),
                MenuItem("Start Navigation With Live Map", self.run_nav2_with_rtabmap),
                MenuItem("Send Robot To A Goal", self.send_nav2_goal),
                MenuItem("Back", lambda: None),
            ],
            subtitle="Manual control, advanced setup, and lower-level robot tools.",
        )

    def connection_report(self) -> None:
        iface = "l4tbr0"
        iface_state = "present" if (Path("/sys/class/net") / iface).exists() else "missing"
        oper = "unknown"
        if iface_state == "present":
            try:
                oper = (Path("/sys/class/net") / iface / "operstate").read_text().strip()
            except OSError:
                oper = "unknown"

        try:
            ping_ok = subprocess.run(["ping", "-I", iface, "-c", "1", "-W", "1", "192.168.186.2"], capture_output=True, check=False).returncode == 0
        except FileNotFoundError:
            ping_ok = False
        fw = "unreachable"
        if ping_ok:
            try:
                result = subprocess.run(
                    ["curl", "--interface", iface, "-sS", "http://192.168.186.2/home"],
                    text=True,
                    capture_output=True,
                    check=False,
                )
                if result.stdout:
                    matches = re.findall(r'version="[^"]*"|rosversionname="[^"]*"', result.stdout)
                    fw = ", ".join(matches) if matches else "reachable (metadata parse failed)"
            except FileNotFoundError:
                fw = "reachable (curl unavailable)"
        try:
            docker_ok = subprocess.run(["docker", "info"], capture_output=True, check=False).returncode == 0
        except FileNotFoundError:
            docker_ok = False

        self.show_message(
            "Create 3 USB-C Connection Report",
            "\n".join(
                [
                    f"Repo: {REPO_ROOT}",
                    "",
                    f"Interface ({iface}): {iface_state}",
                    f"Interface state:    {oper}",
                    f"Robot ping:         {'yes' if ping_ok else 'no'}",
                    f"Robot metadata:     {fw}",
                    f"Docker daemon:      {'yes' if docker_ok else 'no'}",
                    "",
                    "Tip: For USB-C-only Create 3 control, l4tbr0 should be UP and ping should be yes.",
                ]
            ),
        )

    def gamecube_teleop(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/teleop_gamecube_hidraw.sh")], safe_behavior="preview")

    def teleop_arrows(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/teleop_arrow_keys.sh")], safe_behavior="preview")

    def teleop_keyboard(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/teleop_keyboard.sh")], safe_behavior="preview")

    def ros_health_check(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/ros_health_check.sh")], safe_behavior="preview")

    def preflight_autonomy(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/preflight_autonomy.sh")], safe_behavior="preview")

    def software_readiness_audit(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "build/software_readiness_audit.sh")], safe_behavior="preview")

    def guided_nav2_start(self) -> None:
        self.show_message(
            "Guided Nav2 + Scan Startup",
            "\n".join(
                [
                    "Terminal A:",
                    "  ./scripts/robot/run_robot_runtime_container.sh",
                    "  # inside container:",
                    "  source /opt/ros/humble/setup.bash",
                    "",
                    "Terminal B (host):",
                    "  ./scripts/robot/run_oak_camera.sh",
                    "  ./scripts/robot/run_rtabmap_rgbd.sh",
                    "",
                    "Terminal C (host):",
                    "  ./scripts/robot/run_nav2_with_rtabmap.sh",
                    "",
                    "Then send a goal:",
                    "  ./scripts/robot/send_nav2_goal.sh 1.0 0.0 0.0 1.0",
                    "",
                    "Keep the robot on the floor in an open area before sending goals.",
                ]
            ),
        )

    def run_robot_runtime_container(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/run_robot_runtime_container.sh")], safe_behavior="preview")

    def run_oak_camera(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/run_oak_camera.sh")], safe_behavior="preview")

    def run_rtabmap_rgbd(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/run_rtabmap_rgbd.sh")], safe_behavior="preview")

    def record_raw_bag(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/record_raw_bag.sh")], safe_behavior="preview")

    def run_nav2_with_rtabmap(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/run_nav2_with_rtabmap.sh")], safe_behavior="preview")

    def send_nav2_goal(self) -> None:
        x = self.prompt_input("Nav2 Goal", "Goal X coordinate.", "0.0")
        if x is None:
            return
        y = self.prompt_input("Nav2 Goal", "Goal Y coordinate.", "0.0")
        if y is None:
            return
        qz = self.prompt_input("Nav2 Goal", "Goal orientation qz.", "0.0")
        if qz is None:
            return
        qw = self.prompt_input("Nav2 Goal", "Goal orientation qw.", "1.0")
        if qw is None:
            return
        self.run_command([str(SCRIPTS_DIR / "robot/send_nav2_goal.sh"), x, y, qz, qw], safe_behavior="preview")

    def handheld_capture_menu(self) -> None:
        self.menu_loop(
            "Capture With Handheld Camera",
            [
                MenuItem("Check Camera Health", self.camera_health),
                MenuItem("Start Handheld Capture", self.capture_handheld),
                MenuItem("Explain Handheld Capture", self.show_handheld_plain_english_guide),
                MenuItem("Back", lambda: None),
            ],
            subtitle="Create a new run with a handheld camera. Training and browser viewing happen later.",
        )

    def guided_scan_to_browser_menu(self) -> None:
        while self.running:
            run = self.selected_guided_run()
            stage, next_step, _ = self.guided_run_state(run)
            selected_label = run.rel if run is not None else "none"
            items = [
                MenuItem("Show Current Status And Next Step", self.show_guided_status),
                MenuItem("Choose Saved Run", self.choose_guided_run),
                MenuItem("Prepare Saved Run For Training (choose memory level)", self.guided_prepare_selected_run),
                MenuItem("Start 3D Model Training (choose memory level)", self.guided_start_training),
                MenuItem("Start Jetson Orin Nano 8GB gsplat Training", self.guided_start_training_jetson_gsplat),
                MenuItem("Watch Training Progress", self.guided_watch_training_logs),
                MenuItem("Show Tailscale URL For 3D Model", self.guided_open_viewer),
                MenuItem("Explain This Workflow", self.show_gaussian_plain_english_guide),
                MenuItem("Back", lambda: None),
            ]

            index = 0
            top = 0
            while self.running:
                height, width = self.stdscr.getmaxyx()
                visible_rows = max(5, height - 6)
                if index < top:
                    top = index
                if index >= top + visible_rows:
                    top = index - visible_rows + 1

                self.stdscr.erase()
                subtitle = f"Selected run: {selected_label} | Stage: {stage} | Next: {next_step}"
                self.draw_header("Guided: Saved Run To Browser View", subtitle)
                for row, item in enumerate(items[top : top + visible_rows], start=0):
                    y = 2 + row
                    attr = curses.A_REVERSE if top + row == index else curses.A_NORMAL
                    self.stdscr.addnstr(y, 2, item.label, max(1, width - 4), attr)
                self.draw_footer()
                self.stdscr.refresh()

                key = self.stdscr.getch()
                if key in (curses.KEY_UP, ord("k")):
                    index = (index - 1) % len(items)
                elif key in (curses.KEY_DOWN, ord("j")):
                    index = (index + 1) % len(items)
                elif key in (10, 13, curses.KEY_ENTER):
                    item = items[index]
                    if item.label.lower() == "back":
                        return
                    item.action()
                    break
                elif key in (27, ord("q")):
                    return

    def gaussian_menu(self) -> None:
        self.menu_loop(
            "Make A 3D Browser View From A Saved Run",
            [
                MenuItem("Guided: Saved Run To Browser View (recommended)", self.guided_scan_to_browser_menu),
                MenuItem("Prepare Saved Run For Training (choose memory level)", self.prepare_run),
                MenuItem("Train 3D Model (choose memory level)", self.start_training),
                MenuItem("Train 3D Model With Jetson Orin Nano 8GB gsplat Constraints", self.start_training_jetson_gsplat),
                MenuItem("Watch Training Progress", self.watch_training_logs),
                MenuItem("Show Training Status", self.training_status),
                MenuItem("Stop Training", self.stop_training),
                MenuItem("Start Browser View And Show Tailscale URL", self.start_viewer_and_open_browser),
                MenuItem("Start Browser View", self.start_viewer),
                MenuItem("Stop Browser View", self.stop_viewer),
                MenuItem("Show Saved 3D Model Files", self.show_exported_splats),
                MenuItem("Explain This Workflow", self.show_gaussian_plain_english_guide),
                MenuItem("Back", lambda: None),
            ],
            subtitle="Use this after you already have a run. This section prepares, trains, and opens the 3D model.",
        )

    def camera_health(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "robot/oak_camera_health_check.sh")], safe_behavior="append-dry-run", extra_safe_args=["--dry-run"])

    def capture_handheld(self) -> None:
        duration = self.prompt_input("Capture Duration", "Seconds to record for handheld scan.", DEFAULT_DURATION)
        if duration is None:
            return
        if not duration.isdigit() or int(duration) <= 0:
            duration = DEFAULT_DURATION
        extra = ["--dry-run", "--no-prompt"] if self.safe_mode else []
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/manual_handheld_oak_capture_test.sh"), "--duration", duration, *extra],
            safe_behavior="pass",
        )

    def prepare_run(self) -> None:
        run = self.select_run("trainable", "Prepare Saved Run For Training")
        if run is None:
            return
        memory_profile = self.choose_memory_profile()
        if memory_profile is None:
            return
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_gaussian_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                "prep",
                "--foreground",
                "--memory-profile",
                memory_profile,
                "--downscale",
                memory_profile_downscale(memory_profile),
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def guided_prepare_selected_run(self) -> None:
        run = self.selected_guided_run()
        if run is None:
            self.show_message("Prepare Run", "No guided run is selected yet.")
            return
        memory_profile = self.choose_memory_profile()
        if memory_profile is None:
            return
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_gaussian_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                "prep",
                "--foreground",
                "--memory-profile",
                memory_profile,
                "--downscale",
                memory_profile_downscale(memory_profile),
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def start_training(self) -> None:
        run = self.select_run("trainable", "Train 3D Model")
        if run is None:
            return
        mode = self.choose_training_mode()
        if mode is None:
            return
        memory_profile = self.choose_memory_profile()
        if memory_profile is None:
            return
        iterations = self.prompt_input("Training Iterations", "Set max training iterations.", DEFAULT_ITERS)
        if iterations is None:
            return
        if not iterations.isdigit() or int(iterations) <= 0:
            iterations = DEFAULT_ITERS
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_gaussian_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                mode,
                "--max-iters",
                iterations,
                "--memory-profile",
                memory_profile,
                "--downscale",
                memory_profile_downscale(memory_profile),
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def start_training_jetson_gsplat(self) -> None:
        run = self.select_run("jetson_gsplat_trainable", "Train 3D Model With Jetson gsplat")
        if run is None:
            return
        mode = self.choose_training_mode()
        if mode is None:
            return
        iterations = self.prompt_input("Training Iterations", "Set max training iterations.", DEFAULT_ITERS)
        if iterations is None:
            return
        if not iterations.isdigit() or int(iterations) <= 0:
            iterations = DEFAULT_ITERS
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_jetson_orin_nano_gsplat_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                mode,
                "--max-steps",
                iterations,
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def guided_start_training(self) -> None:
        run = self.selected_guided_run()
        if run is None:
            self.show_message("Train 3D Model", "No guided run is selected yet.")
            return
        memory_profile = self.choose_memory_profile()
        if memory_profile is None:
            return
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_gaussian_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                "prep-train",
                "--max-iters",
                DEFAULT_ITERS,
                "--memory-profile",
                memory_profile,
                "--downscale",
                memory_profile_downscale(memory_profile),
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def guided_start_training_jetson_gsplat(self) -> None:
        run = self.selected_guided_run()
        if run is None:
            self.show_message("Jetson gsplat Training", "No guided run is selected yet.")
            return
        if not self.is_jetson_gsplat_trainable(run.path):
            self.show_message(
                "Jetson gsplat Training",
                "This separate Jetson gsplat path needs either:\n\n- dataset/transforms.json\n- rtabmap.db\n\nRaw video-only runs are not supported by this path.",
            )
            return
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_jetson_orin_nano_gsplat_training_job.sh"),
                "--run",
                str(run.path),
                "--mode",
                "prep-train",
                "--max-steps",
                DEFAULT_ITERS,
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def watch_training_logs(self) -> None:
        run = self.select_run("train_logs", "Watch Training Progress")
        if run is None:
            return
        extra = ["--dry-run", "--no-follow"] if self.safe_mode else []
        self.run_command([str(SCRIPTS_DIR / "gaussian/watch_gaussian_training_job.sh"), "--run", str(run.path), *extra], safe_behavior="pass")

    def guided_watch_training_logs(self) -> None:
        run = self.selected_guided_run()
        if run is None:
            self.show_message("Watch Training", "No guided run is selected yet.")
            return
        extra = ["--dry-run", "--no-follow"] if self.safe_mode else []
        self.run_command([str(SCRIPTS_DIR / "gaussian/watch_gaussian_training_job.sh"), "--run", str(run.path), *extra], safe_behavior="pass")

    def training_status(self) -> None:
        run = self.select_run("train_metadata", "Show Training Status")
        if run is None:
            return
        self.run_command([str(SCRIPTS_DIR / "gaussian/training_job_status.sh"), "--run", str(run.path)], safe_behavior="pass")

    def stop_training(self) -> None:
        run = self.select_run("train_metadata", "Stop Training")
        if run is None:
            return
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/stop_gaussian_training_job.sh"), "--run", str(run.path)],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def start_viewer(self) -> None:
        run = self.select_run("viewer_ready", "Start Browser View")
        if run is None:
            return
        port = self.prompt_input("Viewer Port", "Viewer port to bind on localhost.", DEFAULT_PORT)
        if port is None:
            return
        if not port.isdigit() or int(port) <= 0:
            port = DEFAULT_PORT
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/start_gaussian_viewer.sh"), "--run", str(run.path), "--port", port],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def start_viewer_and_open_browser(self) -> None:
        run = self.select_run("viewer_ready", "Start Browser View And Show Tailscale URL")
        if run is None:
            return
        port = self.prompt_input("Viewer Port", "Viewer port to bind on localhost.", DEFAULT_PORT)
        if port is None:
            return
        if not port.isdigit() or int(port) <= 0:
            port = DEFAULT_PORT
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/start_gaussian_viewer.sh"), "--run", str(run.path), "--port", port, "--open-browser"],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def guided_open_viewer(self) -> None:
        run = self.selected_guided_run()
        if run is None:
            self.show_message("Open In Browser", "No guided run is selected yet.")
            return
        self.run_command(
            [
                str(SCRIPTS_DIR / "gaussian/start_gaussian_viewer.sh"),
                "--run",
                str(run.path),
                "--port",
                DEFAULT_PORT,
                "--open-browser",
            ],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def stop_viewer(self) -> None:
        choice = self.select_viewer_container("Stop Browser View")
        if choice is None:
            return
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/stop_gaussian_viewer.sh"), "--container-name", choice.name],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def show_exported_splats(self) -> None:
        lines = []
        for run in self.list_runs():
            splat = run.path / "exports" / "splat" / "splat.ply"
            if splat.is_file():
                lines.append(str(splat.relative_to(REPO_ROOT)))
        if not lines:
            lines = ["No exported splats found under runs/."]
        self.show_message("Saved 3D Model Files", "\n".join(lines))

    def runs_menu(self) -> None:
        self.menu_loop(
            "Saved Runs",
            [
                MenuItem("List Saved Runs", self.show_all_runs),
                MenuItem("Inspect Saved Run", self.inspect_run),
                MenuItem("Move Run To Trash", self.delete_run),
                MenuItem("Restore Run From Trash", self.restore_run),
                MenuItem("Empty Old Trash", self.purge_trash),
                MenuItem("Back", lambda: None),
            ],
        )

    def show_all_runs(self) -> None:
        runs = self.list_runs()
        if not runs:
            self.show_message("Runs", "No runs found under runs/.")
            return
        self.show_message("Runs", "\n".join(run.label for run in runs))

    def inspect_run(self) -> None:
        run = self.select_run("any", "Inspect Run")
        if run is None:
            return
        details = [
            f"Run: {run.rel}",
            f"Absolute: {run.path}",
            f"Badges: {' '.join(run.badges) if run.badges else '(none)'}",
            "",
            f"raw/capture.mp4: {'yes' if (run.path / 'raw' / 'capture.mp4').is_file() else 'no'}",
            f"rtabmap.db: {'yes' if (run.path / 'rtabmap.db').is_file() else 'no'}",
            f"dataset/transforms.json: {'yes' if (run.path / 'dataset' / 'transforms.json').is_file() else 'no'}",
            f"exports/splat/splat.ply: {'yes' if (run.path / 'exports' / 'splat' / 'splat.ply').is_file() else 'no'}",
        ]
        result = self.run_capture([str(SCRIPTS_DIR / "gaussian/training_job_status.sh"), "--run", str(run.path)])
        if result and result != "(no output)":
            details.extend(["", result])
        self.show_message("Run Details", "\n".join(details))

    def delete_run(self) -> None:
        run = self.select_run("any", "Delete Run")
        if run is None:
            return
        if not self.confirm("Delete Run", f"Move {run.rel} to runs/.trash?"):
            return
        self.run_command(
            [str(SCRIPTS_DIR / "run_tools/delete_run.sh"), "--run", str(run.path), "--yes"],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def restore_run(self) -> None:
        entry = self.select_trash_entry()
        if entry is None:
            return
        self.run_command(
            [str(SCRIPTS_DIR / "run_tools/restore_run.sh"), "--entry", entry],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def purge_trash(self) -> None:
        days = self.prompt_input("Purge Trash", "Delete trash entries older than how many days?", DEFAULT_DAYS)
        if days is None:
            return
        if not days.isdigit():
            days = DEFAULT_DAYS
        if not self.confirm("Purge Trash", f"Permanently purge trash entries older than {days} days?"):
            return
        self.run_command(
            [str(SCRIPTS_DIR / "run_tools/purge_run_trash.sh"), "--older-than-days", days],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def builds_menu(self) -> None:
        self.menu_loop(
            "Build And Setup",
            [
                MenuItem("Build 3D Training Images", self.build_training_images),
                MenuItem("Test 3D Training Build", self.validate_training_clean),
                MenuItem("Build Robot Runtime Image", self.build_robot_runtime),
                MenuItem("Test All Builds", self.validate_all_builds),
                MenuItem("Back", lambda: None),
            ],
        )

    def build_training_images(self) -> None:
        self.run_command(
            [str(SCRIPTS_DIR / "build/build_jetson_training_images.sh")],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def validate_training_clean(self) -> None:
        self.run_command(
            [str(SCRIPTS_DIR / "build/validate_docker_builds.sh"), "--mode", "clean", "--target", "training"],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def build_robot_runtime(self) -> None:
        self.run_command([str(SCRIPTS_DIR / "build/build_robot_runtime_image.sh")], safe_behavior="preview")

    def validate_all_builds(self) -> None:
        self.run_command(
            [str(SCRIPTS_DIR / "build/validate_docker_builds.sh"), "--mode", "cached", "--target", "all"],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )

    def diagnostics_menu(self) -> None:
        self.menu_loop(
            "Troubleshooting",
            [
                MenuItem("Run Menu Self-Tests", self.run_tui_self_tests),
                MenuItem("Show Docker Status", self.show_docker_status),
                MenuItem("Show Browser View Containers", self.show_viewer_containers),
                MenuItem("Clean Up Stale Training State", self.cleanup_stale_training_state),
                MenuItem("Back", lambda: None),
            ],
        )

    def run_tui_self_tests(self) -> None:
        self.run_command(
            ["bash", "-lc", "./scripts/tests/test_operator_tuis.sh && ./scripts/tests/test_gs_tui.sh"],
            safe_behavior="pass",
        )

    def show_docker_status(self) -> None:
        self.run_command(
            ["bash", "-lc", "docker info | sed -n '1,80p'; echo ''; echo 'Container summary:'; docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}'"],
            safe_behavior="pass",
        )

    def show_viewer_containers(self) -> None:
        self.run_command(
            [
                "bash",
                "-lc",
                "docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}' | { read -r header || true; echo \"$header\"; grep 'gs_viewer_' || true; }",
            ],
            safe_behavior="pass",
        )

    def cleanup_stale_training_state(self) -> None:
        self.run_command(
            [str(SCRIPTS_DIR / "gaussian/cleanup_stale_training_state.sh")],
            safe_behavior="append-dry-run",
            extra_safe_args=["--dry-run"],
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Unified ncurses master TUI")
    parser.add_argument("--safe-mode", action="store_true", help="Use dry-run mode for supported actions.")
    parser.add_argument(
        "--start-section",
        choices=["robot-scan", "robot-tools", "gaussian", "runs", "builds", "diagnostics"],
        default="",
        help="Open a section first, then return to the main menu.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    safe_mode = args.safe_mode or os.environ.get("MASTER_TUI_SAFE_MODE") == "1" or os.environ.get("MASTER_TUI_DRY_RUN") == "1"
    start_section = args.start_section or os.environ.get("MASTER_TUI_START_SECTION", "")

    def wrapped(stdscr: curses.window) -> None:
        App(stdscr, safe_mode=safe_mode, start_section=start_section).run()

    curses.wrapper(wrapped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
