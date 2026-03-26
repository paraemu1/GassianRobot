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
  GASSIAN_TUI_FORCE_PLAIN=1
  GASSIAN_TUI_USE_WHIPTAIL=0
  GASSIAN_TUI_AUTOTEST=1
)

run_sequence \
  "Easy menu supports prepare-then-mission flow" \
  "launch_live_auto_scan\\.sh mission" \
  "2\ny\n3\ny\n12\n" \
  "${COMMON_ENV[@]}" EASY_AUTONOMY_TUI_DRY_RUN=1 "${SCRIPT_DIR}/easy_autonomy_tui.sh"

run_sequence \
  "Control center routes into the easy menu" \
  "Easy Robot Scan Menu" \
  "1\n12\n11\n" \
  "${COMMON_ENV[@]}" CONTROL_TUI_DRY_RUN=1 "${SCRIPT_DIR}/control_center.sh"

run_sequence \
  "Master launcher routes into the advanced control center" \
  "Advanced Robot Control Center" \
  "2\n11\n6\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 "${SCRIPT_DIR}/master_tui.sh"

run_sequence \
  "Master launcher routes into the Gaussian workflow menu" \
  "Project Workflow TUI" \
  "3\n0\n6\n" \
  "${COMMON_ENV[@]}" MASTER_TUI_DRY_RUN=1 GS_TUI_AUTOTEST=1 GS_TUI_FORCE_PLAIN=1 "${SCRIPT_DIR}/master_tui.sh"

echo ""
echo "Operator TUI self-test summary: ${passes} passed, ${failures} failed."
if [[ "$failures" -ne 0 ]]; then
  exit 1
fi

echo "All operator TUI smoke tests passed."
