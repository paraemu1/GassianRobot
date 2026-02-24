#!/usr/bin/env bash

# Shared helpers for resolving run directory arguments.

run_utils_is_placeholder() {
  local value="$1"
  [[ "$value" == *"YYYY-MM-DD"* || "$value" == *"<"*">"* || "$value" == *"your-existing-run"* || "$value" == *"new-run"* ]]
}

run_utils_list_runs() {
  local repo_root="$1"
  local runs_root="${repo_root}/runs"
  local listed=0

  echo "Available runs (newest first):"
  if [[ ! -d "$runs_root" ]]; then
    echo "  (no runs directory at ${runs_root})"
    return 0
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    listed=1
    echo "  ${line#${repo_root}/}"
  done < <(ls -1dt "${runs_root}"/*/ 2>/dev/null | sed 's:/$::' | grep -v '/_template$' | head -n 20 || true)

  if [[ "$listed" -eq 0 ]]; then
    echo "  (no run folders found under ${runs_root})"
  fi
}

run_utils_latest_run() {
  local repo_root="$1"
  local runs_root="${repo_root}/runs"
  local latest

  latest="$(ls -1dt "${runs_root}"/*/ 2>/dev/null | sed 's:/$::' | grep -v '/_template$' | head -n 1 || true)"
  if [[ -n "$latest" ]]; then
    echo "$latest"
  fi
}

run_utils_resolve_run_dir() {
  local repo_root="$1"
  local run_arg="$2"
  local candidate=""

  if [[ -z "$run_arg" || "$run_arg" == "latest" ]]; then
    candidate="$(run_utils_latest_run "$repo_root")"
    if [[ -z "$candidate" ]]; then
      echo "Could not find any runs under ${repo_root}/runs." >&2
      return 1
    fi
    realpath -m "$candidate"
    return 0
  fi

  if run_utils_is_placeholder "$run_arg"; then
    echo "Run value looks like a placeholder: ${run_arg}" >&2
    echo "Use a real run folder or use '--run latest'." >&2
    return 1
  fi

  if [[ "$run_arg" = /* ]]; then
    candidate="$run_arg"
  elif [[ -d "${repo_root}/${run_arg}" ]]; then
    candidate="${repo_root}/${run_arg}"
  elif [[ -d "${repo_root}/runs/${run_arg}" ]]; then
    candidate="${repo_root}/runs/${run_arg}"
  elif [[ -d "${PWD}/${run_arg}" ]]; then
    candidate="${PWD}/${run_arg}"
  else
    candidate="${repo_root}/${run_arg}"
  fi

  realpath -m "$candidate"
}
