#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

OLDER_THAN_DAYS=30
DRY_RUN=0

usage() {
  cat <<'USAGE'
Permanently delete old run trash entries under runs/.trash.

Usage:
  ./scripts/run_tools/purge_run_trash.sh [--older-than-days N] [--dry-run]

Options:
  --older-than-days N   Purge entries older than N days (default: 30).
  --dry-run             Show entries that would be purged.
  -h, --help            Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --older-than-days)
      OLDER_THAN_DAYS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$OLDER_THAN_DAYS" =~ ^[0-9]+$ ]]; then
  echo "--older-than-days must be a non-negative integer" >&2
  exit 1
fi

trash_root="${REPO_ROOT}/runs/.trash"
if [[ ! -d "$trash_root" ]]; then
  echo "No trash directory found: $trash_root"
  exit 0
fi

purged=0

while IFS= read -r -d '' entry; do
  rel="${entry#${REPO_ROOT}/}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Would purge: $rel"
  else
    rm -rf "$entry"
    echo "Purged: $rel"
  fi
  purged=$((purged + 1))
done < <(find "$trash_root" -mindepth 1 -maxdepth 1 -type d -mtime "+${OLDER_THAN_DAYS}" -print0)

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run complete. Entries matched: $purged"
else
  echo "Purge complete. Entries removed: $purged"
fi
