#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENTRY=""
TO_NAME=""
LIST_ONLY=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Restore a soft-deleted run from runs/.trash back into runs/.

Usage:
  ./scripts/run_tools/restore_run.sh --entry <trash-entry-name> [--to-name <run-name>]

Options:
  --entry <name|path>      Trash entry directory name (under runs/.trash) or absolute path.
  --to-name <run-name>     Optional restored run directory basename.
  --list                   List available trash entries and exit.
  --dry-run                Print what would happen.
  -h, --help               Show this help.
USAGE
}

runs_root="${REPO_ROOT}/runs"
trash_root="${runs_root}/.trash"

list_entries() {
  if [[ ! -d "$trash_root" ]]; then
    echo "No trash directory at ${trash_root}"
    return 0
  fi

  local entry
  echo "Trash entries (newest first):"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    echo "  ${entry#${trash_root}/}"
  done < <(ls -1dt "${trash_root}"/*/ 2>/dev/null | sed 's:/$::' || true)
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --entry)
      ENTRY="$2"
      shift 2
      ;;
    --to-name)
      TO_NAME="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift 1
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

if [[ "$LIST_ONLY" -eq 1 ]]; then
  list_entries
  exit 0
fi

if [[ -z "$ENTRY" ]]; then
  echo "Missing required --entry" >&2
  usage
  exit 1
fi

if [[ "$ENTRY" = /* ]]; then
  trash_entry_dir="$ENTRY"
else
  trash_entry_dir="${trash_root}/${ENTRY}"
fi

if [[ ! -d "$trash_entry_dir" ]]; then
  echo "Trash entry not found: $trash_entry_dir" >&2
  list_entries >&2
  exit 1
fi

entry_base="$(basename "$trash_entry_dir")"
meta_file="${trash_entry_dir}/.trash_meta.env"

if [[ -n "$TO_NAME" ]]; then
  target_base="$TO_NAME"
elif [[ -f "$meta_file" ]]; then
  target_base="$(grep -E '^ORIGINAL_BASENAME=' "$meta_file" | tail -n1 | cut -d= -f2- || true)"
else
  target_base=""
fi

if [[ -z "$target_base" ]]; then
  target_base="${entry_base#*-}"
fi

if [[ -z "$target_base" ]]; then
  echo "Could not derive target run name from trash entry: $entry_base" >&2
  exit 1
fi

target_dir="${runs_root}/${target_base}"

if [[ -e "$target_dir" ]]; then
  echo "Restore target already exists: $target_dir" >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: restore_run.sh"
  echo "Entry: $trash_entry_dir"
  echo "Restore target: $target_dir"
  exit 0
fi

mv "$trash_entry_dir" "$target_dir"
rm -f "${target_dir}/.trash_meta.env"

echo "Restored run: ${target_dir#${REPO_ROOT}/}"
