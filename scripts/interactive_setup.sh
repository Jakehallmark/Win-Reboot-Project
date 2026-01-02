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
  1. Download Windows 11 ISO files from UUP dump
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

extract_url_params() {
  local url="$1"
  local build_id_var="$2"
  local language_var="$3"
  local edition_var="$4"
  
  # Extract build ID (required)
  if [[ "$url" =~ id=([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}) ]]; then
    eval "$build_id_var='${BASH_REMATCH[1]}'"
  else
    return 1
  fi
  
  # Extract language pack (optional but expected)
  if [[ "$url" =~ pack=([a-zA-Z]{2}-[a-zA-Z]{2}) ]]; then
    eval "$language_var='${BASH_REMATCH[1]}'"
  fi
  
  # Extract edition (optional but expected)
  # Handle URL encoding (e.g., %3B = semicolon) and extract first edition if multiple
  if [[ "$url" =~ edition=([a-zA-Z0-9_%]+) ]]; then
    local raw_edition="${BASH_REMATCH[1]}"
    # URL decode common characters
    raw_edition="${raw_edition//%3B/;}"
    raw_edition="${raw_edition//%3b/;}"
    # Take first edition if semicolon-separated (e.g., "core;professional" -> "core")
    local first_edition="${raw_edition%%;*}"
    eval "$edition_var='$first_edition'"
  fi
  
  return 0
}

verify_build_exists() {
  local build_id="$1"
  
  msg "Verifying build availability..."
  
  # Query the UUP dump API to check if build exists
  local api="https://api.uupdump.net/listlangs.php?id=${build_id}"
  local json
  
  if ! json="$(curl -fsSL "$api" 2>&1)"; then
    warn "Could not connect to UUP dump API"
    return 1
  fi
  
  # Check if response indicates success
  if echo "$json" | python3 -c "import json,sys; data=json.load(sys.stdin); sys.exit(0 if data.get('response',{}).get('apiVersion') else 1)" 2>/dev/null; then
    msg "Build verified: ID $build_id is available"
    return 0
  else
    warn "Build ID appears to be invalid or expired"
    return 1
  fi
}

step_fetch_iso() {
  msg "Step 1: Fetch Windows 11 ISO"
  echo ""
  
  cat <<'EOF'
To get started, you need to find a Windows 11 build on UUP dump:

  1. Visit https://uupdump.net
  2. Click "Latest Dev Channel build" or search for a specific version
  3. Select your language (e.g., English (United States))
  4. Select your edition (e.g., Windows 11 Professional)
  5. On the download options page, copy the URL from your browser's address bar

The URL will look like one of these:
  https://uupdump.net/download.php?id=BUILD_ID&pack=en-us&edition=professional
  https://uupdump.net/getfiles.php?id=BUILD_ID&pack=en-us&edition=professional

Note: If you see multiple editions (e.g., core;professional), the script will 
use the first one. To choose a specific edition, select it on the UUP dump 
website before copying the URL.

EOF
  
  read -r -p "Paste the full UUP dump URL: " user_url < /dev/tty
  check_cancel "$user_url"
  
  if [[ -z "$user_url" ]]; then
    fatal_error "URL cannot be empty" 1 \
      "Please provide a valid UUP dump URL"
  fi
  
  # Extract parameters from URL
  local build_id="" language="" edition=""
  if ! extract_url_params "$user_url" "build_id" "language" "edition"; then
    fatal_error "Invalid URL format" 1 \
      "Could not extract build ID from URL. Expected format: https://uupdump.net/...?id=BUILD_ID&pack=LANGUAGE&edition=EDITION"
  fi
  
  echo ""
  msg "Extracted parameters from URL:"
  echo "  Build ID: $build_id"
  [[ -n "$language" ]] && echo "  Language: $language" || echo "  Language: (not specified)"
  [[ -n "$edition" ]] && echo "  Edition: $edition" || echo "  Edition: (not specified)"
  echo ""
  
  # Verify the build exists
  if ! verify_build_exists "$build_id"; then
    echo ""
    warn "The build ID could not be verified. This could mean:"
    echo "  - The build is expired or no longer available"
    echo "  - There's a network connectivity issue"
    echo "  - The UUP dump API is experiencing problems"
    echo ""
    if ! prompt_yn "Continue anyway?"; then
      fatal_error "Build verification failed" 1 \
        "Please try a different build from uupdump.net"
    fi
  fi
  
  echo ""
  msg "Downloading Windows 11 ISO files..."
  
  # Build arguments for fetch_iso.sh
  local -a fetch_args=()
  fetch_args+=(--update-id "$build_id")
  
  # Add language if specified
  if [[ -n "$language" ]]; then
    fetch_args+=(--language "$language")
  fi
  
  # Add edition if specified (normalize to lowercase)
  if [[ -n "$edition" ]]; then
    fetch_args+=(--edition "${edition,,}")
  fi
  
  # Execute the fetch
  if ! "$SCRIPT_DIR/fetch_iso.sh" "${fetch_args[@]}"; then
    fatal_error "ISO download failed" 20 \
      "Check the error messages above. The build may be expired or unavailable."
  fi
  
  # Verify output exists
  if [[ ! -f "$ROOT_DIR/out/win11.iso" ]]; then
    fatal_error "ISO file not found after download" 25 \
      "Expected output at: $ROOT_DIR/out/win11.iso"
  fi
  
  msg "ISO downloaded successfully: $ROOT_DIR/out/win11.iso"
  echo ""
}

step_tiny11() {
  msg "Step 2: Tiny11 trimming (optional)"
  echo ""
  echo "Tiny11 reduces ISO size and removes unnecessary Windows components."
  echo ""
  echo "Available presets:"
  echo "  minimal    - Removes inbox consumer apps; keeps Store, Defender, BitLocker, etc."
  echo "  lite       - minimal plus removes WinRE/Help, Media Player, Quick Assist, etc."
  echo "  aggressive - minimal plus Photos/Maps/Camera/Calculator/Paint, etc."
  echo "  vanilla    - No changes (skip trimming)"
  echo ""
  
  prompt_yn "Apply Tiny11 trimming?" "y" || {
    msg "Skipping Tiny11 modifications"
    return 0
  }
  
  local preset
  read -r -p "Preset [minimal/lite/aggressive/vanilla]: " preset < /dev/tty
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
  step_fetch_iso
  step_tiny11
  step_grub
  step_reboot
  
  msg "Setup complete!"
}

main "$@"
