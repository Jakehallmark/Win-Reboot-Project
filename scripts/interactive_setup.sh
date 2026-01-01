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

source "$SCRIPT_DIR/lib_error.sh" 2>/dev/null || {
  echo "[!] Error: Cannot load error handling library" >&2
  exit 1
}

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

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

query_available_builds() {
  local channel="$1"
  local arch="$2"
  
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
    # Use defaults - no extra args needed
    :
  else
    # Custom settings
    echo ""
    msg "Custom ISO Settings"
    echo ""
    
    # First, let user select channel and architecture to query available builds
    echo "Select Release Channel:"
    echo "  1) Retail (stable, recommended)"
    echo "  2) Release Preview (pre-release testing)"
    echo ""
    local channel_choice
    read -r -p "Choice [1-2, default 1]: " channel_choice < /dev/tty
    channel_choice="${channel_choice:-1}"
    
    local selected_channel
    case "$channel_choice" in
      1) selected_channel="retail";;
      2) selected_channel="rp";;
      *) warn "Invalid choice, using retail"; selected_channel="retail";;
    esac
    
    echo ""
    
    # Architecture selection
    echo "Select Architecture:"
    echo "  1) x64 (amd64) - 64-bit Intel/AMD"
    echo "  2) arm64 - 64-bit ARM (for ARM devices)"
    echo ""
    local arch_choice
    read -r -p "Choice [1-2, default 1]: " arch_choice < /dev/tty
    arch_choice="${arch_choice:-1}"
    
    local selected_arch
    case "$arch_choice" in
      1) selected_arch="amd64";;
      2) selected_arch="arm64";;
      *) warn "Invalid choice, using amd64"; selected_arch="amd64";;
    esac
    
    echo ""
    
    # Query what's actually available for selected channel/arch
    if query_available_builds "$selected_channel" "$selected_arch"; then
      echo ""
      msg "The following build is available and will be downloaded"
    else
      warn "Could not verify available builds, proceeding anyway..."
    fi
    
    echo ""
    
    fetch_args+=(--channel "$selected_channel")
    fetch_args+=(--arch "$selected_arch")
    
    # Edition selection
    echo "Select Edition:"
    echo "  1) Professional (recommended)"
    echo "  2) Home"
    echo "  3) Core (Home without OEM branding)"
    echo "  4) Enterprise"
    echo "  5) Education"
    echo "  6) All editions (includes all above)"
    echo ""
    local edition_choice
    read -r -p "Choice [1-6, default 1]: " edition_choice < /dev/tty
    edition_choice="${edition_choice:-1}"
    
    case "$edition_choice" in
      1) fetch_args+=(--edition "professional");;
      2) fetch_args+=(--edition "home");;
      3) fetch_args+=(--edition "core");;
      4) fetch_args+=(--edition "enterprise");;
      5) fetch_args+=(--edition "education");;
      6) fetch_args+=(--edition "professional,home,core,enterprise,education");;
      *) warn "Invalid choice, using Professional"; fetch_args+=(--edition "professional");;
    esac
    
    echo ""
    
    # Language selection
    echo "Select Language:"
    echo "  1) en-us (English - United States)"
    echo "  2) en-gb (English - United Kingdom)"
    echo "  3) es-es (Spanish - Spain)"
    echo "  4) fr-fr (French - France)"
    echo "  5) de-de (German - Germany)"
    echo "  6) pt-br (Portuguese - Brazil)"
    echo "  7) zh-cn (Chinese - Simplified)"
    echo "  8) ja-jp (Japanese)"
    echo "  9) Other (enter manually)"
    echo ""
    local lang_choice
    read -r -p "Choice [1-9, default 1]: " lang_choice < /dev/tty
    lang_choice="${lang_choice:-1}"
    
    case "$lang_choice" in
      1) fetch_args+=(--lang "en-us");;
      2) fetch_args+=(--lang "en-gb");;
      3) fetch_args+=(--lang "es-es");;
      4) fetch_args+=(--lang "fr-fr");;
      5) fetch_args+=(--lang "de-de");;
      6) fetch_args+=(--lang "pt-br");;
      7) fetch_args+=(--lang "zh-cn");;
      8) fetch_args+=(--lang "ja-jp");;
      9) 
        local custom_lang
        read -r -p "Enter language code (e.g., it-it): " custom_lang < /dev/tty
        fetch_args+=(--lang "$custom_lang")
        ;;
      *) warn "Invalid choice, using en-us"; fetch_args+=(--lang "en-us");;
    esac
    
    echo ""
    msg "Configured settings: ${fetch_args[*]}"
    echo ""
  fi
  
  if ! "$SCRIPT_DIR/fetch_iso.sh" "${fetch_args[@]}"; then
    fatal_error "ISO download failed" 20 \
      "Check network connection and disk space. See error messages above."
  fi
  echo ""
}

step_tiny11() {
  msg "Step 2: Apply Tiny11 trimming (optional)"
  echo ""
  echo "Presets:"
  echo "  minimal - Conservative app removals (recommended)"
  echo "  lite    - More aggressive removals"
  echo "  vanilla - No modifications (skip this step)"
  echo ""
  
  prompt_yn "Apply Tiny11 trimming?" "y" || {
    msg "Skipping Tiny11 modifications"
    return 0
  }
  
  local preset
  read -r -p "Preset [minimal/lite/vanilla]: " preset < /dev/tty
  preset="${preset:-minimal}"
  
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
