#!/usr/bin/env bash
set -euo pipefail

# Interactive wrapper that guides users through the full flow

# Ensure we have a terminal for interactive prompts
if [[ ! -t 0 ]] && [[ ! -e /dev/tty ]]; then
  echo "[!] Error: No interactive terminal available" >&2
  echo "[!] This script requires user input and cannot run in a pipe." >&2
  echo "[!] Please run directly: git clone https://github.com/Jakehallmark/Win-Reboot-Project.git && cd Win-Reboot-Project && ./scripts/interactive_setup.sh" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="${TMP_DIR:-$ROOT_DIR/tmp}"
mkdir -p "$TMP_DIR"

UUP_PARSE_LOG="$TMP_DIR/uup_parse_error.log"
: >"$UUP_PARSE_LOG"

source "$SCRIPT_DIR/lib_error.sh" 2>/dev/null || {
  echo "[!] Error: Cannot load error handling library" >&2
  exit 1
}

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
check_cancel() {
  local val="${1,,}"
  if [[ "$val" == "q" || "$val" == "quit" || "$val" == "exit" || "$val" == "b" ]]; then
    msg "Exiting by user request."
    exit 0
  fi
}
log_uup_issue() {
  local title="$1"
  local details="${2:-}"
  {
    echo "[$(date -Ins)] $title"
    [[ -n "$details" ]] && printf "%s\n" "$details"
    echo ""
  } >>"$UUP_PARSE_LOG"
}

prompt_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local answer
  
  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n]: " answer < /dev/tty
    answer="${answer:-y}"
  else
    read -r -p "$prompt [y/N]: " answer < /dev/tty
    answer="${answer:-n}"
  fi
  check_cancel "$answer"
  
  [[ "${answer,,}" == "y" ]]
}

intro() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           Win-Reboot-Project Interactive Setup                ║
║        Inspired by the Tiny11 Project by ntdevlabs            ║
╚═══════════════════════════════════════════════════════════════╝

This will:
  1. Download the latest Windows 11 ISO from Microsoft
  2. Optionally apply Tiny11-style trimming
  3. Add a GRUB entry to boot the installer
  4. Reboot into the Windows 11 installer

WARNING:
  - Secure Boot MUST be disabled
  - This modifies your GRUB configuration
  - The Windows installer can wipe your disk
  - Test in a VM first!

Tiny11 Credit: This project adapts the excellent methodology from
ntdevlabs' Tiny11 project for use on Linux systems.
Visit: https://github.com/ntdevlabs/tiny11builder

EOF
  prompt_yn "Continue?" "n" || exit 0
}

check_dependencies() {
  msg "Checking dependencies..."
  if [[ -x "$SCRIPT_DIR/check_deps.sh" ]]; then
    if ! "$SCRIPT_DIR/check_deps.sh" --auto-install; then
      fatal_error "Missing required dependencies" 10 \
        "Run: ./scripts/check_deps.sh --auto-install to try again, or install packages manually"
    fi
  else
    warn "check_deps.sh not found, skipping dependency check"
  fi
  echo ""
}

# Global cache for build data to avoid repeated API calls
declare -A BUILD_CACHE_EDITIONS
declare -A BUILD_CACHE_LANGUAGES
declare -A BUILD_CACHE_IDS

prefetch_build_data() {
  msg "Pre-fetching available Windows builds from UUP dump..."
  echo "  This reduces rate limiting and speeds up the selection process"
  echo ""
  
  # Query only the most common configurations to minimize API calls
  # Most users want retail/amd64, so prioritize that
  local -a configs=(
    "retail:amd64"
    "rp:amd64"
  )
  
  local delay=10  # Use 10 second delay (same as UUP Dump's own tools)
  for config in "${configs[@]}"; do
    local channel="${config%:*}"
    local arch="${config#*:}"
    local cache_key="${channel}_${arch}"
    
    # Add delay between requests (10s per UUP Dump's own API usage)
    if [[ "$config" != "retail:amd64" ]]; then
      echo "  Waiting ${delay}s to avoid rate limiting..."
      sleep $delay
    fi
    
    echo -n "  Querying ${channel}/${arch}... "
    
    local api="https://api.uupdump.net/fetchupd.php?arch=${arch}&ring=${channel}&build=latest"
    local json
    json="$(curl -fsSL "$api" 2>&1)" || {
      echo "failed (network)"
      continue
    }
    
    local update_id
    update_id="$(echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('response',{}).get('updateId',''))" 2>/dev/null)" || {
      echo "failed (parse)"
      continue
    }
    
    if [[ -z "$update_id" ]]; then
      echo "no build found"
      continue
    fi
    
    BUILD_CACHE_IDS["$cache_key"]="$update_id"
    echo "found (ID: ${update_id:0:8}...)"
    
    # Now fetch editions and languages for this build
    # Use 10s delay per UUP Dump's own API usage pattern
    echo "  Waiting 10s before querying build details..."
    sleep 10
    
    local editions="" languages="" is_insider="false"
    if query_build_details "$update_id" "editions" "languages" "quiet"; then
      if [[ "$languages" == "INSIDER_BUILD" ]]; then
        is_insider="true"
      fi
    else
      echo "    Could not parse details (check $UUP_PARSE_LOG)"
      continue
    fi
    
    if [[ "$is_insider" == "true" ]]; then
      echo "    Insider build detected (single language/edition)"
      BUILD_CACHE_EDITIONS["$cache_key"]="INSIDER_BUILD"
      BUILD_CACHE_LANGUAGES["$cache_key"]="INSIDER_BUILD"
      continue
    fi
    
    if [[ -n "$editions" && -n "$languages" ]]; then
      BUILD_CACHE_EDITIONS["$cache_key"]="$editions"
      BUILD_CACHE_LANGUAGES["$cache_key"]="$languages"
      local ed_count=$(echo "$editions" | wc -l)
      local lang_count=$(echo "$languages" | wc -l)
      echo "    ✓ Cached $ed_count editions, $lang_count languages"
    fi
  done
  
  echo ""
  local cached_count=${#BUILD_CACHE_IDS[@]}
  if [[ $cached_count -gt 0 ]]; then
    msg "Build data cached successfully ($cached_count configuration(s))"
  else
    warn "Could not cache build data - will query on demand"
  fi
  echo ""
}

query_available_builds() {
  local channel="$1"
  local arch="$2"
  local var_name="$3"  # Variable name to store update ID
  local cache_key="${channel}_${arch}"
  
  # Check cache first (safe check for unset key)
  if [[ -v BUILD_CACHE_IDS[$cache_key] && -n "${BUILD_CACHE_IDS[$cache_key]}" ]]; then
    local cached_id="${BUILD_CACHE_IDS[$cache_key]}"
    echo "  Using cached build: $cached_id"
    
    if [[ -n "$var_name" ]]; then
      eval "$var_name='$cached_id'"
    fi
    return 0
  fi
  
  # Cache miss - query API
  msg "Querying available builds from UUP dump..."
  
  local api="https://api.uupdump.net/fetchupd.php?arch=${arch}&ring=${channel}&build=latest"
  local json
  json="$(curl -fsSL "$api" 2>&1)" || {
    warn "Could not query UUP dump API, using default options"
    return 1
  }
  
  local update_id
  update_id="$(echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('response',{}).get('updateId',''))" 2>/dev/null)" || return 1
  
  if [[ -z "$update_id" ]]; then
    warn "Could not find available builds, using default options"
    return 1
  fi
  
  local build_title
  build_title="$(echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); print(data.get('response',{}).get('updateTitle','Unknown'))" 2>/dev/null)"
  
  echo "  Found: $build_title"
  echo "  Build ID: $update_id"
  
  # Store in cache and return variable
  BUILD_CACHE_IDS["$cache_key"]="$update_id"
  
  if [[ -n "$var_name" ]]; then
    eval "$var_name='$update_id'"
  fi
  
  return 0
}

get_cached_build_details() {
  local channel="$1"
  local arch="$2"
  local editions_var="$3"
  local languages_var="$4"
  local cache_key="${channel}_${arch}"
  
  # Return cached data if available (safe check for unset keys)
  if [[ -v BUILD_CACHE_EDITIONS[$cache_key] && -v BUILD_CACHE_LANGUAGES[$cache_key] ]]; then
    if [[ -n "${BUILD_CACHE_EDITIONS[$cache_key]}" && -n "${BUILD_CACHE_LANGUAGES[$cache_key]}" ]]; then
      if [[ -n "$editions_var" ]]; then
        eval "$editions_var='${BUILD_CACHE_EDITIONS[$cache_key]}'"
      fi
      if [[ -n "$languages_var" ]]; then
        eval "$languages_var='${BUILD_CACHE_LANGUAGES[$cache_key]}'"
      fi
      return 0
    fi
  fi
  
  return 1
}

query_build_details() {
  local update_id="$1"
  local editions_var="$2"
  local languages_var="$3"
  local quiet="${4:-}"
  
  if [[ "$quiet" != "quiet" ]]; then
    msg "Querying available editions and languages..."
  fi
  
  # First, query available languages using listlangs.php
  if [[ "$quiet" != "quiet" ]]; then
    echo "  Waiting 10s before querying languages..."
  fi
  sleep 10
  
  local langs_api="https://api.uupdump.net/listlangs.php?id=${update_id}"
  local langs_json
  langs_json="$(curl -fsSL "$langs_api" 2>&1)" || {
    log_uup_issue "listlangs request failed for ${update_id}" "$langs_json"
    [[ "$quiet" == "quiet" ]] || warn "Could not query languages (network error)"
    return 1
  }
  
  # Check if response is empty
  if [[ -z "$langs_json" ]]; then
    log_uup_issue "listlangs empty response for ${update_id}" "$langs_json"
    [[ "$quiet" == "quiet" ]] || warn "Languages API returned empty response (rate limiting or connection issue)"
    return 1
  fi
  
  # Check response size
  local json_size=${#langs_json}
  if [[ $json_size -lt 20 ]]; then
    log_uup_issue "listlangs small response for ${update_id}" "$langs_json"
    [[ "$quiet" == "quiet" ]] || warn "Languages API returned small response ($json_size bytes)"
    return 1
  fi
  
  # Parse languages response
  local parse_error
  parse_error=$(mktemp)
  local langs_list
  langs_list="$(python3 - "$langs_json" 2>"$parse_error" <<'PY'
import json, sys
try:
    # JSON payload is passed as argv[1] to avoid stdin conflicts with heredocs
    input_data = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    if not input_data:
        print("Empty API response", file=sys.stderr)
        sys.exit(1)
    
    data = json.loads(input_data)
    response = data.get('response', data) if isinstance(data, dict) else data

    # listlangs.php can return:
    # - a plain list of codes
    # - an object with response.langList (newer API shape)
    if isinstance(response, list):
        langs = response
    elif isinstance(response, dict) and 'langList' in response:
        langs = response.get('langList', [])
    else:
        langs = []

    if not langs:
        print("INSIDER_BUILD", file=sys.stderr)
        sys.exit(1)

    print("\n".join(langs))

except json.JSONDecodeError as e:
    print(f"JSON decode error: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Parse error: {e}", file=sys.stderr)
    sys.exit(1)
PY
)" || {
    local err_msg=$(cat "$parse_error" 2>/dev/null)
    log_uup_issue "listlangs parse error for ${update_id}" "Error: ${err_msg}\nResponse:\n${langs_json}"
    if [[ "$err_msg" == *"INSIDER_BUILD"* ]]; then
      [[ -n "$languages_var" ]] && eval "$languages_var='INSIDER_BUILD'"
      rm -f "$parse_error"
      return 0
    fi
    [[ "$quiet" == "quiet" ]] || warn "Could not parse languages: $err_msg (see $UUP_PARSE_LOG)"
    rm -f "$parse_error"
    return 1
  }
  rm -f "$parse_error"
  
  if [[ "$langs_list" == "INSIDER_BUILD" ]]; then
    [[ -n "$languages_var" ]] && eval "$languages_var='INSIDER_BUILD'"
    return 0
  fi
  
  # Now query available editions using listeditions.php with the first language
  local first_lang=$(echo "$langs_list" | head -1)
  if [[ "$quiet" != "quiet" ]]; then
    echo "  Waiting 10s before querying editions..."
  fi
  sleep 10
  
  local eds_api="https://api.uupdump.net/listeditions.php?lang=${first_lang}&id=${update_id}"
  local eds_json
  eds_json="$(curl -fsSL "$eds_api" 2>&1)" || {
    log_uup_issue "listeditions request failed for ${update_id} (lang=${first_lang})" "$eds_json"
    [[ "$quiet" == "quiet" ]] || warn "Could not query editions (network error)"
    return 1
  }
  
  # Check if response is empty
  if [[ -z "$eds_json" ]]; then
    log_uup_issue "listeditions empty response for ${update_id} (lang=${first_lang})" "$eds_json"
    [[ "$quiet" == "quiet" ]] || warn "Editions API returned empty response (rate limiting or connection issue)"
    return 1
  fi
  
  # Parse editions response
  parse_error=$(mktemp)
  local eds_list
  eds_list="$(python3 - "$eds_json" 2>"$parse_error" <<'PY'
import json, sys
try:
    # JSON payload is passed as argv[1] to avoid stdin conflicts with heredocs
    input_data = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    if not input_data:
        print("Empty API response", file=sys.stderr)
        sys.exit(1)
    
    data = json.loads(input_data)
    response = data.get('response', data) if isinstance(data, dict) else data

    # listeditions.php can return:
    # - a plain list of edition codes
    # - an object with response.editionList (newer API shape)
    if isinstance(response, list):
        editions = response
    elif isinstance(response, dict) and 'editionList' in response:
        editions = response.get('editionList', [])
    else:
        editions = []

    if not editions:
        print("No editions found", file=sys.stderr)
        sys.exit(1)

    print("\n".join(editions))

except json.JSONDecodeError as e:
    print(f"JSON decode error: {e}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"Parse error: {e}", file=sys.stderr)
    sys.exit(1)
PY
)" || {
    local err_msg=$(cat "$parse_error" 2>/dev/null)
    log_uup_issue "listeditions parse error for ${update_id} (lang=${first_lang})" "Error: ${err_msg}\nResponse:\n${eds_json}"
    [[ "$quiet" == "quiet" ]] || warn "Could not parse editions: $err_msg (see $UUP_PARSE_LOG)"
    rm -f "$parse_error"
    return 1
  }
  rm -f "$parse_error"
  
  # Store results in variables if provided
  if [[ -n "$editions_var" ]]; then
    eval "$editions_var='$eds_list'"
  fi
  if [[ -n "$languages_var" ]]; then
    eval "$languages_var='$langs_list'"
  fi
  
  return 0
}

step_fetch_iso() {
  msg "Step 1: Download Windows 11 ISO"
  echo ""

  if [[ -f "$ROOT_DIR/out/win11.iso" ]]; then
    local size_mb
    size_mb=$(($(stat -c%s "$ROOT_DIR/out/win11.iso" 2>/dev/null || echo 0) / 1024 / 1024))
    msg "Found existing ISO: out/win11.iso ($size_mb MB)"
    prompt_yn "Skip download and use existing ISO?" "y" && return 0
  fi

  echo "Download options:"
  echo "  Edition: Professional (default)"
  echo "  Language: en-us (default)"
  echo "  Architecture: x64 (amd64)"
  echo "  Channel: Retail (stable release)"
  echo ""

  local fetch_args=()

  if prompt_yn "Use default settings?" "y"; then
    :
  else
    echo ""
    msg "Custom ISO Settings"
    echo ""

    echo "Select Release Channel:"
    echo "  1) Retail (stable, recommended)"
    echo "  2) Release Preview (pre-release testing)"
    echo ""
    local channel_choice
    read -r -p "Choice [1-2, default 1]: " channel_choice < /dev/tty
    channel_choice="${channel_choice:-1}"
    check_cancel "$channel_choice"

    local selected_channel
    case "$channel_choice" in
      1) selected_channel="retail";;
      2) selected_channel="rp";;
      *) warn "Invalid choice, using retail"; selected_channel="retail";;
    esac

    echo ""
    echo "Select Architecture:"
    echo "  1) x64 (amd64) - 64-bit Intel/AMD"
    echo "  2) arm64 - 64-bit ARM (for ARM devices)"
    echo ""
    local arch_choice
    read -r -p "Choice [1-2, default 1]: " arch_choice < /dev/tty
    arch_choice="${arch_choice:-1}"
    check_cancel "$arch_choice"

    local selected_arch
    case "$arch_choice" in
      1) selected_arch="amd64";;
      2) selected_arch="arm64";;
      *) warn "Invalid choice, using amd64"; selected_arch="amd64";;
    esac

    echo ""

    local captured_update_id=""
    if ! query_available_builds "$selected_channel" "$selected_arch" "captured_update_id"; then
      err "Could not query available builds from UUP dump API"
      echo ""
      echo "This could be due to:"
      echo "  - Network connectivity issues"
      echo "  - API rate limiting (wait a few minutes)"
      echo "  - The selected channel/arch combination is not available"
      echo ""
      if ! prompt_yn "Retry the query?"; then
        err "Cannot proceed without build information"
        return 1
      fi
      echo ""
      if ! query_available_builds "$selected_channel" "$selected_arch" "captured_update_id"; then
        err "Query failed again. Please try again later or check your network connection."
        return 1
      fi
    fi

    echo ""
    msg "The following build is available and will be downloaded"

    local available_editions="" available_languages="" is_insider_build="false"
    if get_cached_build_details "$selected_channel" "$selected_arch" "available_editions" "available_languages"; then
      echo "  Using cached editions and languages"
      if [[ -n "$available_editions" && -n "$available_languages" ]]; then
        echo "  Available editions: $(echo "$available_editions" | wc -l) found"
        echo "  Available languages: $(echo "$available_languages" | wc -l) found"
        [[ "$available_languages" == "INSIDER_BUILD" ]] && is_insider_build="true"
      fi
    else
      local retry_count=0
      local max_retries=2
      while [[ $retry_count -lt $max_retries ]]; do
        if query_build_details "$captured_update_id" "available_editions" "available_languages"; then
          if [[ "$available_languages" == "INSIDER_BUILD" ]]; then
            is_insider_build="true"
            echo "  This is an Insider Preview build (single edition, single language)"
            break
          elif [[ -n "$available_editions" && -n "$available_languages" ]]; then
            echo "  Available editions: $(echo "$available_editions" | wc -l) found"
            echo "  Available languages: $(echo "$available_languages" | wc -l) found"
            break
          fi
        fi
        ((retry_count++))
        if [[ $retry_count -lt $max_retries ]]; then
          warn "Query failed, waiting 15s before retry $retry_count/$max_retries..."
          sleep 15
        fi
      done

      if [[ "$is_insider_build" != "true" && (-z "$available_editions" || -z "$available_languages") ]]; then
        err "Could not fetch build details after $max_retries retries"
        echo ""
        echo "This is required to show you accurate edition and language options."
        echo "Without this data, we cannot guarantee the selected combination will work."
        echo ""
        echo "Possible causes:"
        echo "  - UUP dump API is experiencing issues"
        echo "  - Rate limiting (you may have made too many requests)"
        echo "  - Network connectivity problems"
        echo ""
        echo "Please try again in a few minutes."
        return 1
      fi
    fi

    if [[ "$is_insider_build" == "true" ]]; then
      echo ""
      echo "Since this is an Insider Preview build, edition and language are pre-configured."
      echo "Proceeding with default settings..."
      echo ""
      fetch_args+=(--channel "$selected_channel")
      fetch_args+=(--arch "$selected_arch")
      [[ -n "$captured_update_id" ]] && fetch_args+=(--update-id "$captured_update_id")
      msg "Configured settings: ${fetch_args[*]}"
      echo ""
    else
      echo ""
      fetch_args+=(--channel "$selected_channel")
      fetch_args+=(--arch "$selected_arch")
      [[ -n "$captured_update_id" ]] && fetch_args+=(--update-id "$captured_update_id")

      echo "Select Edition:"
      local -a edition_list
      mapfile -t edition_list <<< "$available_editions"
      local ed_idx=1
      local -A edition_map
      local default_idx=1

      for ed in "${edition_list[@]}"; do
        echo "  $ed_idx) $ed"
        edition_map[$ed_idx]="$ed"
        # Set Professional as the default if available
        if [[ "${ed,,}" == "professional" ]]; then
          default_idx=$ed_idx
        fi
        ((ed_idx++))
      done

      echo ""
      echo "  (Note: Select ONE edition. Multi-edition ISOs are not supported by UUP dump.)"
      echo ""
      local edition_choice
      read -r -p "Choice [1-$((ed_idx-1)), default $default_idx]: " edition_choice < /dev/tty
      edition_choice="${edition_choice:-$default_idx}"
      check_cancel "$edition_choice"

      local selected_edition="${edition_map[$edition_choice]}"
      if [[ -n "$selected_edition" ]]; then
        fetch_args+=(--edition "$selected_edition")
      else
        warn "Invalid choice, using Professional"
        fetch_args+=(--edition "professional")
      fi

      echo ""
      echo "Select Language:"
      local -a lang_list
      mapfile -t lang_list <<< "$available_languages"
      local lang_idx=1
      local -A lang_map
      local default_lang_idx=1

      # Prioritize common languages at the top
      local -a priority_langs=("en-us" "en-gb" "es-es" "fr-fr" "de-de" "pt-br" "it-it" "ja-jp" "ko-kr" "zh-cn")
      local -a sorted_langs=()
      local -a other_langs=()

      # Separate priority languages from others
      for lang in "${lang_list[@]}"; do
        local is_priority=0
        for p in "${priority_langs[@]}"; do
          if [[ "$lang" == "$p" ]]; then
            is_priority=1
            break
          fi
        done
        if [[ $is_priority -eq 1 ]]; then
          sorted_langs+=("$lang")
        else
          other_langs+=("$lang")
        fi
      done

      # Combine: priority languages first, then others
      local -a display_langs=("${sorted_langs[@]}" "${other_langs[@]}")

      local max_show=10
      local shown=0
      for lang in "${display_langs[@]}"; do
        if [[ $shown -lt $max_show ]]; then
          echo "  $lang_idx) $lang"
          lang_map[$lang_idx]="$lang"
          # Set en-us as default if available
          if [[ "$lang" == "en-us" ]]; then
            default_lang_idx=$lang_idx
          fi
          ((lang_idx++))
          shown=$((shown + 1))
        fi
      done

      if [[ ${#display_langs[@]} -gt $max_show ]]; then
        echo "  $lang_idx) Other (enter manually from ${#display_langs[@]} available)"
        lang_map[$lang_idx]="other"
        ((lang_idx++))
      fi

      echo ""
      local lang_choice
      read -r -p "Choice [1-$((lang_idx-1)), default $default_lang_idx]: " lang_choice < /dev/tty
      lang_choice="${lang_choice:-$default_lang_idx}"
      check_cancel "$lang_choice"

      local selected_lang="${lang_map[$lang_choice]}"
      if [[ "$selected_lang" == "other" ]]; then
        echo ""
        echo "Available languages:"
        printf "  %s\n" "${display_langs[@]}"
        echo ""
        read -r -p "Enter language code: " selected_lang < /dev/tty
        check_cancel "$selected_lang"
      fi

      if [[ -n "$selected_lang" && "$selected_lang" != "other" ]]; then
        fetch_args+=(--lang "$selected_lang")
      else
        warn "Invalid choice, using en-us"
        fetch_args+=(--lang "en-us")
      fi

      echo ""
      msg "Configured settings: ${fetch_args[*]}"
      echo ""
    fi
  fi

  echo ""
  msg "Starting ISO download..."
  echo ""

  # Call fetch_iso.sh with collected arguments
  if [[ ${#fetch_args[@]} -gt 0 ]]; then
    if ! "$SCRIPT_DIR/fetch_iso.sh" "${fetch_args[@]}"; then
      fatal_error "ISO download failed" 20 \
        "Check network connection and try again. See error messages above."
    fi
  else
    if ! "$SCRIPT_DIR/fetch_iso.sh"; then
      fatal_error "ISO download failed" 20 \
        "Check network connection and try again. See error messages above."
    fi
  fi

  # Verify ISO was downloaded
  if [[ ! -f "$ROOT_DIR/out/win11.iso" ]]; then
    fatal_error "ISO file not found after download" 40 \
      "Expected: $ROOT_DIR/out/win11.iso"
  fi

  local size_mb
  size_mb=$(($(stat -c%s "$ROOT_DIR/out/win11.iso" 2>/dev/null || echo 0) / 1024 / 1024))
  msg "ISO downloaded successfully: $size_mb MB"
  echo ""
}

step_tiny11() {
  msg "Step 2: Apply Tiny11 trimming (optional)"
  echo ""
  echo "Presets:"
  echo "  minimal - Removes inbox consumer apps (News/Weather/Bing/Office hub/Teams/Clipchamp/QuickAssist/YourPhone/Xbox apps/OneDrive installer); keeps Store, Defender, BitLocker, .NET, printing, RDP"
  echo "  lite    - minimal plus removes WinRE/Help/WinRE config, Media Player, Quick Assist, Mixed Reality, OneDrive packages (more aggressive, fewer recovery/help tools)"
  echo "  aggressive - minimal plus Photos/Maps/Camera/Alarms/Calculator/Paint/Snipping/Voice Recorder, Xbox system apps, Cortana remnants (heavier debloat; keep if you don't need those apps)"
  echo "  vanilla - No changes (skip trimming)"
  echo ""
  
  prompt_yn "Apply Tiny11 trimming?" "y" || {
    msg "Skipping Tiny11 modifications"
    return 0
  }
  
  local preset
  read -r -p "Preset [minimal/lite/vanilla]: " preset < /dev/tty
  preset="${preset:-minimal}"
   check_cancel "$preset"
  
  msg "Applying preset: $preset"
  if ! "$SCRIPT_DIR/tiny11.sh" "$ROOT_DIR/out/win11.iso" --preset "$preset"; then
    fatal_error "Tiny11 processing failed" 40 \
      "Check disk space and WIM manipulation tools. See error messages above."
  fi
  
  # Use the tiny ISO if it was created
  if [[ -f "$ROOT_DIR/out/win11-tiny.iso" ]]; then
    msg "Using trimmed ISO for installation"
    cp "$ROOT_DIR/out/win11-tiny.iso" "$ROOT_DIR/out/win11.iso"
  fi
  echo ""
}

step_grub() {
  msg "Step 3: Add GRUB entry"
  echo ""
  warn "This step requires root privileges and will modify GRUB configuration"
  
  prompt_yn "Continue?" "y" || exit 0
  
  if ! sudo "$SCRIPT_DIR/grub_entry.sh" "$ROOT_DIR/out/win11.iso"; then
    fatal_error "GRUB configuration failed" 50 \
      "Check that you have root access, GRUB is installed, and Secure Boot is disabled."
  fi
  echo ""
}

step_reboot() {
  msg "Step 4: Reboot to installer"
  echo ""
  warn "Your system will reboot in 10 seconds!"
  warn "At the GRUB menu, select 'Windows 11 installer (ISO loop)'"
  echo ""
  
  prompt_yn "Reboot now?" "n" || {
    msg "Installation prepared. Reboot manually when ready."
    msg "At GRUB menu, select: 'Windows 11 installer (ISO loop)'"
    return 0
  }
  
  sudo "$SCRIPT_DIR/reboot_to_installer.sh"
}

main() {
  cd "$ROOT_DIR"
  
  intro
  check_dependencies
  prefetch_build_data  # Cache build data early to avoid rate limits later
  step_fetch_iso
  step_tiny11
  step_grub
  step_reboot
  
  msg "Setup complete!"
}

main "$@"
