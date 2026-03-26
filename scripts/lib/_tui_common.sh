#!/usr/bin/env bash

: "${TUI_FORCE_PLAIN:=0}"
: "${TUI_USE_WHIPTAIL:=1}"
: "${TUI_AUTOTEST:=0}"

TUI_HAVE_WHIPTAIL=0

tui_init() {
  TUI_HAVE_WHIPTAIL=0
  if [[ "$TUI_FORCE_PLAIN" != "1" && "$TUI_USE_WHIPTAIL" != "0" ]] && command -v whiptail >/dev/null 2>&1; then
    TUI_HAVE_WHIPTAIL=1
  fi
}

tui_safe_clear() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear || true
  fi
}

tui_pause() {
  local prompt="${1:-Press Enter to continue... }"
  if [[ "$TUI_AUTOTEST" == "1" || ! -t 0 ]]; then
    return 0
  fi
  echo ""
  read -rp "$prompt" _
}

tui_show_info() {
  local title="$1"
  local msg="$2"

  if [[ "$TUI_AUTOTEST" == "1" ]]; then
    printf "%s\n\n%b\n" "$title" "$msg"
    return 0
  fi

  if [[ "$TUI_HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "$title" --msgbox "$msg" 18 100
    return 0
  fi

  tui_safe_clear
  echo "$title"
  echo ""
  printf '%b\n' "$msg"
  tui_pause
}

tui_show_text() {
  local title="$1"
  local msg="$2"

  if [[ "$TUI_AUTOTEST" == "1" ]]; then
    printf "%s\n\n%b\n" "$title" "$msg"
    return 0
  fi

  if [[ "$TUI_HAVE_WHIPTAIL" == "1" ]]; then
    local tmp_file
    tmp_file="$(mktemp)"
    printf '%b\n' "$msg" > "$tmp_file"
    whiptail --title "$title" --textbox "$tmp_file" 24 110
    rm -f "$tmp_file"
    return 0
  fi

  tui_safe_clear
  echo "$title"
  echo ""
  printf '%b\n' "$msg"
  tui_pause
}

tui_confirm() {
  local prompt="$1"
  local title="${2:-Confirm}"

  if [[ "$TUI_HAVE_WHIPTAIL" == "1" ]]; then
    whiptail --title "$title" --yesno "$prompt" 16 100
    return $?
  fi

  printf '%b\n' "$prompt"
  local ans
  if ! read -rp "Continue? [y/N]: " ans; then
    return 1
  fi
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

tui_menu_choice() {
  local title="$1"
  local prompt="$2"
  shift 2
  local -a items=("$@")

  if [[ "$TUI_HAVE_WHIPTAIL" == "1" ]]; then
    local out
    out="$(whiptail --title "$title" --menu "$prompt" 24 110 16 "${items[@]}" 3>&1 1>&2 2>&3)" || return 1
    echo "$out"
    return 0
  fi

  echo "$title" >&2
  echo "$prompt" >&2
  echo "" >&2

  local -a keys=()
  local idx=1
  local i
  for ((i=0; i<${#items[@]}; i+=2)); do
    keys+=("${items[$i]}")
    echo "${idx}) ${items[$((i+1))]}" >&2
    idx=$((idx + 1))
  done

  echo "" >&2
  local pick
  if ! read -rp "Choose: " pick; then
    echo ""
    return 1
  fi
  if [[ ! "$pick" =~ ^[0-9]+$ || "$pick" -lt 1 || "$pick" -gt ${#keys[@]} ]]; then
    echo ""
    return 0
  fi
  echo "${keys[$((pick-1))]}"
}

tui_run_cmd() {
  local dry_run="$1"
  shift

  if [[ "$dry_run" == "1" ]]; then
    echo "[DRY-RUN] $*"
    tui_pause
    return 0
  fi

  tui_safe_clear
  echo "Running: $*"
  echo ""
  set +e
  "$@"
  local code=$?
  set -e
  echo ""
  if [[ "$code" -ne 0 ]]; then
    echo "Command failed with exit code $code"
  fi
  tui_pause
  return "$code"
}
