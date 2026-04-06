#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_RUNTIME_DIR="$(mktemp -d)"

passes=0
failures=0

cleanup() {
  rm -rf "$TMP_RUNTIME_DIR"
}
trap cleanup EXIT

run_sequence() {
  local label="$1"
  local expected="$2"
  local sequence="$3"
  shift 3

  local out_file
  out_file="$(mktemp)"
  if printf "%b" "$sequence" | "$@" >"$out_file" 2>&1 && grep -Eq "$expected" "$out_file"; then
    echo "[PASS] $label"
    passes=$((passes + 1))
  else
    echo "[FAIL] $label"
    cat "$out_file"
    failures=$((failures + 1))
  fi
  rm -f "$out_file"
}

COMMON_ENV=(
  env
  XDG_RUNTIME_DIR="$TMP_RUNTIME_DIR"
  MASTER_TUI_FORCE_PLAIN=1
  MASTER_TUI_AUTOTEST=1
)

mapfile -t ROOT_TUI_SCRIPTS < <(find "${SCRIPT_DIR}/.." -maxdepth 1 -type f -name '*.sh' | sort)
if [[ "${#ROOT_TUI_SCRIPTS[@]}" -eq 1 && "$(basename "${ROOT_TUI_SCRIPTS[0]}")" == "master_tui.sh" ]]; then
  echo "[PASS] scripts/ root keeps only master_tui.sh"
  passes=$((passes + 1))
else
  echo "[FAIL] scripts/ root shell entrypoints: ${ROOT_TUI_SCRIPTS[*]}"
  failures=$((failures + 1))
fi

run_sequence \
  "Master launcher opens robot scan directly and supports prepare-then-mission flow" \
  "launch_live_auto_scan\\.sh[[:space:]]+mission" \
  "2\n3\n0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh" --start-section robot-scan

run_sequence \
  "Master launcher lists previous scan runs directly" \
  "Previous Scan Runs" \
  "5\n0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh" --start-section robot-scan

run_sequence \
  "Master launcher opens robot tools directly" \
  "Advanced Robot Tools" \
  "0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh" --start-section robot-tools

run_sequence \
  "Master launcher opens robot tools section" \
  "Advanced Robot Tools" \
  "2\n0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh"

run_sequence \
  "Master launcher opens Handheld Capture section" \
  "Capture With Handheld Camera" \
  "3\n0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh"

run_sequence \
  "Master launcher opens scan-to-browser section" \
  "Make A 3D Browser View From A Saved Run" \
  "4\n0\n0\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/../master_tui.sh"

echo ""
echo "Operator TUI self-test summary: ${passes} passed, ${failures} failed."
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "All operator TUI smoke tests passed."
