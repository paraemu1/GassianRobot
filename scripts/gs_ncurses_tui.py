#!/usr/bin/env python3
from __future__ import annotations

import argparse
import curses
import os
import subprocess
import textwrap
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, List, Optional, Sequence


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
DEFAULT_ITERS = "30000"
DEFAULT_PORT = "7007"


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
class MenuItem:
    key: str
    label: str
    action: Callable[[], None]


class App:
    def __init__(self, stdscr: curses.window, safe_mode: bool) -> None:
        self.stdscr = stdscr
        self.safe_mode = safe_mode
        self.status = "Ready"
        self.running = True

    def run(self) -> None:
        curses.curs_set(0)
        self.stdscr.keypad(True)
        curses.use_default_colors()
        while self.running:
            self.menu_loop(
                "Gaussian Splat Workflow",
                [
                    MenuItem("1", "Workflow", self.workflow_menu),
                    MenuItem("2", "Runs", self.runs_menu),
                    MenuItem("3", "Builds", self.builds_menu),
                    MenuItem("4", "Diagnostics", self.diagnostics_menu),
                    MenuItem("q", "Quit", self.quit),
                ],
                subtitle="Arrow keys to move, Enter to select, q to back/quit.",
            )
            self.running = False

    def quit(self) -> None:
        self.running = False

    def workflow_menu(self) -> None:
        self.menu_loop(
            "Workflow",
            [
                MenuItem("1", "Prepare selected run", self.prepare_run),
                MenuItem("2", "Start training", self.start_training),
                MenuItem("3", "Watch training logs", self.watch_training_logs),
                MenuItem("4", "Training status", self.training_status),
                MenuItem("5", "Stop training", self.stop_training),
                MenuItem("6", "Start viewer", self.start_viewer),
                MenuItem("7", "Start viewer + open browser", lambda: self.start_viewer(open_browser=True)),
                MenuItem("8", "Stop viewer", self.stop_viewer),
                MenuItem("q", "Back", lambda: None),
            ],
            subtitle="Trainable runs now include RTAB-Map DB scans.",
        )

    def runs_menu(self) -> None:
        self.menu_loop(
            "Runs",
            [
                MenuItem("1", "List all runs", self.show_all_runs),
                MenuItem("2", "Inspect run", self.inspect_run),
                MenuItem("q", "Back", lambda: None),
            ],
        )

    def builds_menu(self) -> None:
        self.menu_loop(
            "Builds",
            [
                MenuItem("1", "Build training images", lambda: self.run_command([str(SCRIPTS_DIR / "build/build_jetson_training_images.sh")], safe_dry_run=True)),
                MenuItem("2", "Build robot runtime image", lambda: self.run_command([str(SCRIPTS_DIR / "build/build_robot_runtime_image.sh")], safe_dry_run=False)),
                MenuItem("3", "Validate all builds", lambda: self.run_command([str(SCRIPTS_DIR / "build/validate_docker_builds.sh"), "--mode", "cached", "--target", "all"], safe_dry_run=True)),
                MenuItem("q", "Back", lambda: None),
            ],
        )

    def diagnostics_menu(self) -> None:
        self.menu_loop(
            "Diagnostics",
            [
                MenuItem("1", "Show Docker status", lambda: self.run_command(["bash", "-lc", "docker ps --format 'table {{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.Ports}}'"], safe_dry_run=False)),
                MenuItem("2", "Cleanup stale training state", lambda: self.run_command([str(SCRIPTS_DIR / "gaussian/cleanup_stale_training_state.sh")], safe_dry_run=True)),
                MenuItem("q", "Back", lambda: None),
            ],
        )

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
                if item.key == "q":
                    return
                item.action()
                if not self.running:
                    return
            elif key in (27, ord("q")):
                return

    def draw_header(self, title: str, subtitle: str) -> None:
        height, width = self.stdscr.getmaxyx()
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

    def list_runs(self) -> List[RunInfo]:
        runs_dir = REPO_ROOT / "runs"
        candidates = [path for path in runs_dir.glob("*") if path.is_dir() and path.name != "_template" and path.name != ".trash"]
        candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
        return [RunInfo(path=path, rel=str(path.relative_to(REPO_ROOT)), badges=self.compute_badges(path)) for path in candidates]

    def compute_badges(self, run_dir: Path) -> List[str]:
        badges: List[str] = []
        if self.is_trainable(run_dir):
            badges.append("trainable")
        if (run_dir / "rtabmap.db").is_file():
            badges.append("rtabmap-db")
        if list((run_dir / "checkpoints").glob("**/config.yml")):
            badges.append("viewer-ready")
        if (run_dir / "exports" / "splat" / "splat.ply").is_file():
            badges.append("exported")
        if (run_dir / "logs" / "train_job.pid").is_file():
            try:
                pid = int((run_dir / "logs" / "train_job.pid").read_text().strip())
                os.kill(pid, 0)
                badges.append("train-running")
            except Exception:
                badges.append("train-metadata")
        elif (run_dir / "logs" / "train_job.status").is_file():
            badges.append("train-metadata")
        return badges

    def is_trainable(self, run_dir: Path) -> bool:
        return any(
            [
                (run_dir / "raw" / "capture.mp4").is_file(),
                (run_dir / "gs_input.env").is_file(),
                (run_dir / "rtabmap.db").is_file(),
                (run_dir / "dataset" / "transforms.json").is_file(),
            ]
        )

    def select_run(self, context: str, title: str) -> Optional[RunInfo]:
        all_runs = self.list_runs()
        if context == "trainable":
            runs = [run for run in all_runs if self.is_trainable(run.path)]
        elif context == "viewer_ready":
            runs = [run for run in all_runs if "viewer-ready" in run.badges]
        elif context == "train_logs":
            runs = [run for run in all_runs if list((run.path / "logs").glob("train_job_*.log"))]
        elif context == "train_metadata":
            runs = [run for run in all_runs if "train-metadata" in run.badges or "train-running" in run.badges]
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

    def choose_training_mode(self) -> Optional[str]:
        options = [
            RunInfo(Path("prep-train"), "prep-train", ["prep", "train", "export"]),
            RunInfo(Path("train"), "train", ["train", "export"]),
            RunInfo(Path("prep"), "prep", ["prep"]),
        ]
        index = 0
        while True:
            self.stdscr.erase()
            self.draw_header("Training Mode", "Enter to select, q to cancel.")
            for row, item in enumerate(options, start=0):
                attr = curses.A_REVERSE if row == index else curses.A_NORMAL
                self.stdscr.addnstr(2 + row, 2, item.label, max(1, self.stdscr.getmaxyx()[1] - 4), attr)
            self.draw_footer()
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k")):
                index = (index - 1) % len(options)
            elif key in (curses.KEY_DOWN, ord("j")):
                index = (index + 1) % len(options)
            elif key in (10, 13, curses.KEY_ENTER):
                return options[index].rel
            elif key in (27, ord("q")):
                return None

    def run_command(self, cmd: Sequence[str], safe_dry_run: bool) -> None:
        command = list(cmd)
        if self.safe_mode and safe_dry_run and "--dry-run" not in command:
            command.append("--dry-run")
        self.status = "Running: " + " ".join(command)

        curses.def_prog_mode()
        curses.endwin()
        try:
            print(f"Repo: {REPO_ROOT}")
            print("Command:", " ".join(command))
            print("")
            subprocess.run(command, cwd=REPO_ROOT, check=False)
            input("\nPress Enter to return to the ncurses UI...")
        finally:
            self.stdscr.refresh()
            curses.reset_prog_mode()
            curses.curs_set(0)
            self.stdscr.keypad(True)
            self.status = "Ready"

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
        status_script = SCRIPTS_DIR / "gaussian/training_job_status.sh"
        result = subprocess.run([str(status_script), "--run", str(run.path)], cwd=REPO_ROOT, text=True, capture_output=True, check=False)
        if result.stdout.strip():
            details.extend(["", result.stdout.strip()])
        elif result.stderr.strip():
            details.extend(["", result.stderr.strip()])
        self.show_message("Run Details", "\n".join(details))

    def prepare_run(self) -> None:
        run = self.select_run("trainable", "Prepare Run")
        if run is None:
            return
        self.run_command([str(SCRIPTS_DIR / "gaussian/start_gaussian_training_job.sh"), "--run", str(run.path), "--mode", "prep", "--foreground"], safe_dry_run=True)

    def start_training(self) -> None:
        run = self.select_run("trainable", "Start Training")
        if run is None:
            return
        mode = self.choose_training_mode()
        if mode is None:
            return
        iterations = self.prompt_input("Iterations", "Max training iterations.", DEFAULT_ITERS)
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
            ],
            safe_dry_run=True,
        )

    def watch_training_logs(self) -> None:
        run = self.select_run("train_logs", "Watch Training Logs")
        if run is None:
            return
        command = [str(SCRIPTS_DIR / "gaussian/watch_gaussian_training_job.sh"), "--run", str(run.path)]
        if self.safe_mode:
            command.extend(["--dry-run", "--no-follow"])
        self.run_command(command, safe_dry_run=False)

    def training_status(self) -> None:
        run = self.select_run("train_metadata", "Training Status")
        if run is None:
            return
        self.run_command([str(SCRIPTS_DIR / "gaussian/training_job_status.sh"), "--run", str(run.path)], safe_dry_run=False)

    def stop_training(self) -> None:
        run = self.select_run("train_metadata", "Stop Training")
        if run is None:
            return
        self.run_command([str(SCRIPTS_DIR / "gaussian/stop_gaussian_training_job.sh"), "--run", str(run.path)], safe_dry_run=True)

    def start_viewer(self, open_browser: bool = False) -> None:
        run = self.select_run("viewer_ready", "Start Viewer")
        if run is None:
            return
        port = self.prompt_input("Viewer Port", "Viewer port to bind on localhost.", DEFAULT_PORT)
        if port is None:
            return
        if not port.isdigit() or int(port) <= 0:
            port = DEFAULT_PORT
        command = [str(SCRIPTS_DIR / "gaussian/start_gaussian_viewer.sh"), "--run", str(run.path), "--port", port]
        if open_browser:
            command.append("--open-browser")
        self.run_command(command, safe_dry_run=True)

    def stop_viewer(self) -> None:
        run = self.select_run("viewer_ready", "Stop Viewer")
        if run is None:
            return
        self.run_command([str(SCRIPTS_DIR / "gaussian/stop_gaussian_viewer.sh"), "--run", str(run.path)], safe_dry_run=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ncurses Gaussian workflow TUI")
    parser.add_argument("--safe-mode", action="store_true", help="Use dry-run mode for supported actions.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    safe_mode = args.safe_mode or os.environ.get("GS_TUI_SAFE_MODE") == "1"

    def wrapped(stdscr: curses.window) -> None:
        App(stdscr, safe_mode=safe_mode).run()

    curses.wrapper(wrapped)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
