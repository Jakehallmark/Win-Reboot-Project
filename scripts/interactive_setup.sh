#!/usr/bin/env bash
set -euo pipefail

# Interactive wrapper that guides users through the full flow

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
    read -p "$prompt [Y/n]: " answer
    answer="${answer:-y}"
  else
    read -p "$prompt [y/N]: " answer
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
    if ! "$SCRIPT_DIR/check_deps.sh"; then
      fatal_error "Missing required dependencies" 10 \
        "Run: ./scripts/check_deps.sh to see what's missing, then install the packages"
    fi
  else
    warn "check_deps.sh not found, skipping dependency check"
  fi
  echo ""
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
  echo ""
  
  prompt_yn "Use default settings?" "y" || {
    warn "Custom settings not implemented in interactive mode. Edit fetch_iso.sh args manually."
  }
  
  if ! "$SCRIPT_DIR/fetch_iso.sh"; then
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
  read -p "Preset [minimal/lite/vanilla]: " preset
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
