#!/usr/bin/env bash

# Shared helpers for resolving run directory arguments and run state classification.

run_utils_is_placeholder() {
  local value="$1"
  [[ "$value" == *"YYYY-MM-DD"* || "$value" == *"<"*">"* || "$value" == *"your-existing-run"* || "$value" == *"new-run"* ]]
}

run_utils_runs_root() {
  local repo_root="$1"
  echo "${repo_root}/runs"
}

run_utils_all_runs() {
  local repo_root="$1"
  local runs_root
  runs_root="$(run_utils_runs_root "$repo_root")"

  if [[ ! -d "$runs_root" ]]; then
    return 0
  fi

  ls -1dt "${runs_root}"/*/ 2>/dev/null | sed 's:/$::' | grep -v '/_template$' || true
}

run_utils_read_status_value() {
  local status_file="$1"
  local key="$2"

  if [[ ! -f "$status_file" ]]; then
    return 1
  fi

  grep -E "^${key}=" "$status_file" | tail -n1 | sed "s/^${key}=//"
}

run_utils_has_train_logs() {
  local run_dir="$1"

  if [[ -L "${run_dir}/logs/train_job.latest.log" || -f "${run_dir}/logs/train_job.latest.log" ]]; then
    return 0
  fi

  ls -1 "${run_dir}"/logs/train_job_*.log >/dev/null 2>&1
}

run_utils_has_training_metadata() {
  local run_dir="$1"

  if [[ -f "${run_dir}/logs/train_job.pid" || -f "${run_dir}/logs/train_job.status" ]]; then
    return 0
  fi

  run_utils_has_train_logs "$run_dir"
}

run_utils_is_trainable_run() {
  local run_dir="$1"
  [[ -f "${run_dir}/raw/capture.mp4" || -f "${run_dir}/gs_input.env" ]]
}

run_utils_is_viewer_ready_run() {
  local run_dir="$1"
  find "${run_dir}/checkpoints" -name config.yml -print -quit 2>/dev/null | grep -q .
}

run_utils_is_trained_export_run() {
  local run_dir="$1"
  [[ -f "${run_dir}/exports/splat/splat.ply" ]]
}

run_utils_run_matches_context() {
  local run_dir="$1"
  local context="$2"

  case "$context" in
    any|"")
      return 0
      ;;
    trainable)
      run_utils_is_trainable_run "$run_dir"
      ;;
    viewer_ready)
      run_utils_is_viewer_ready_run "$run_dir"
      ;;
    trained_export)
      run_utils_is_trained_export_run "$run_dir"
      ;;
    train_logs)
      run_utils_has_train_logs "$run_dir"
      ;;
    train_metadata)
      run_utils_has_training_metadata "$run_dir"
      ;;
    *)
      echo "Unknown run context: $context" >&2
      return 1
      ;;
  esac
}

run_utils_context_description() {
  local context="$1"

  case "$context" in
    any|"")
      echo "runs"
      ;;
    trainable)
      echo "trainable runs (must have raw/capture.mp4 or gs_input.env)"
      ;;
    viewer_ready)
      echo "viewer-ready runs (must have checkpoints/**/config.yml)"
      ;;
    trained_export)
      echo "runs with exported splats (exports/splat/splat.ply)"
      ;;
    train_logs)
      echo "runs with training logs"
      ;;
    train_metadata)
      echo "runs with training metadata (pid/status/log)"
      ;;
    *)
      echo "runs for context '$context'"
      ;;
  esac
}

run_utils_run_status_badges() {
  local run_dir="$1"
  local -a badges=()
  local status_file state exit_code pid

  if run_utils_is_trainable_run "$run_dir"; then
    badges+=("trainable")
  fi

  if run_utils_is_viewer_ready_run "$run_dir"; then
    badges+=("viewer-ready")
  fi

  if run_utils_is_trained_export_run "$run_dir"; then
    badges+=("exported")
  fi

  if run_utils_has_train_logs "$run_dir"; then
    badges+=("train-logs")
  fi

  status_file="${run_dir}/logs/train_job.status"
  pid=""
  if [[ -f "${run_dir}/logs/train_job.pid" ]]; then
    pid="$(cat "${run_dir}/logs/train_job.pid" 2>/dev/null || true)"
  fi

  if [[ -n "$pid" ]] && ps -p "$pid" >/dev/null 2>&1; then
    badges+=("train-running")
  else
    state="$(run_utils_read_status_value "$status_file" "state" || true)"
    exit_code="$(run_utils_read_status_value "$status_file" "exit_code" || true)"
    if [[ "$state" == "exited" ]]; then
      if [[ -n "$exit_code" ]]; then
        badges+=("train-exited:${exit_code}")
      else
        badges+=("train-exited")
      fi
    fi
  fi

  if [[ ${#badges[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  printf '[%s] ' "${badges[@]}"
}

run_utils_list_runs() {
  local repo_root="$1"
  local listed=0
  local run_dir rel badges

  echo "Available runs (newest first):"

  while IFS= read -r run_dir; do
    [[ -z "$run_dir" ]] && continue
    listed=1
    rel="${run_dir#${repo_root}/}"
    badges="$(run_utils_run_status_badges "$run_dir")"
    if [[ -n "$badges" ]]; then
      echo "  ${rel} ${badges}"
    else
      echo "  ${rel}"
    fi
  done < <(run_utils_all_runs "$repo_root")

  if [[ "$listed" -eq 0 ]]; then
    echo "  (no run folders found under $(run_utils_runs_root "$repo_root"))"
  fi
}

run_utils_latest_matching_run() {
  local repo_root="$1"
  local context="$2"
  local run_dir

  while IFS= read -r run_dir; do
    [[ -z "$run_dir" ]] && continue
    if run_utils_run_matches_context "$run_dir" "$context"; then
      echo "$run_dir"
      return 0
    fi
  done < <(run_utils_all_runs "$repo_root")

  return 1
}

run_utils_latest_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "any"
}

run_utils_latest_trainable_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "trainable"
}

run_utils_latest_viewer_ready_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "viewer_ready"
}

run_utils_latest_trained_export_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "trained_export"
}

run_utils_latest_with_train_logs_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "train_logs"
}

run_utils_latest_with_training_metadata_run() {
  local repo_root="$1"
  run_utils_latest_matching_run "$repo_root" "train_metadata"
}

run_utils_pick_latest_by_context() {
  local repo_root="$1"
  local context="$2"

  case "$context" in
    any|"")
      run_utils_latest_run "$repo_root"
      ;;
    trainable)
      run_utils_latest_trainable_run "$repo_root"
      ;;
    viewer_ready)
      run_utils_latest_viewer_ready_run "$repo_root"
      ;;
    trained_export)
      run_utils_latest_trained_export_run "$repo_root"
      ;;
    train_logs)
      run_utils_latest_with_train_logs_run "$repo_root"
      ;;
    train_metadata)
      run_utils_latest_with_training_metadata_run "$repo_root"
      ;;
    *)
      echo "Unknown run context: $context" >&2
      return 1
      ;;
  esac
}

run_utils_resolve_run_dir() {
  local repo_root="$1"
  local run_arg="$2"
  local candidate=""

  if [[ -z "$run_arg" || "$run_arg" == "latest" ]]; then
    candidate="$(run_utils_latest_run "$repo_root" || true)"
    if [[ -z "$candidate" ]]; then
      echo "Could not find any runs under $(run_utils_runs_root "$repo_root")." >&2
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

run_utils_resolve_run_dir_for_context() {
  local repo_root="$1"
  local run_arg="$2"
  local context="$3"
  local resolved=""

  if [[ -z "$run_arg" || "$run_arg" == "latest" ]]; then
    resolved="$(run_utils_pick_latest_by_context "$repo_root" "$context" || true)"
    if [[ -z "$resolved" ]]; then
      echo "Could not find $(run_utils_context_description "$context") under $(run_utils_runs_root "$repo_root")." >&2
      return 1
    fi
    realpath -m "$resolved"
    return 0
  fi

  resolved="$(run_utils_resolve_run_dir "$repo_root" "$run_arg")"
  if ! run_utils_run_matches_context "$resolved" "$context"; then
    echo "Run does not match required context '${context}': $resolved" >&2
    echo "Expected: $(run_utils_context_description "$context")." >&2
    return 1
  fi

  realpath -m "$resolved"
}

run_utils_validate_run_for_context() {
  local run_dir="$1"
  local context="$2"

  if run_utils_run_matches_context "$run_dir" "$context"; then
    return 0
  fi

  echo "Run does not match required context '${context}': $run_dir" >&2
  echo "Expected: $(run_utils_context_description "$context")." >&2
  return 1
}
