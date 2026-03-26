#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  -h|--help|help)
    exec "${SCRIPT_DIR}/launch_live_auto_scan.sh" help
    ;;
  *)
    exec "${SCRIPT_DIR}/launch_live_auto_scan.sh" stop "$@"
    ;;
esac
