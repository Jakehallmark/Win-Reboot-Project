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

step_fetch_iso() {
  msg "Step 1: Fetch Windows 11 ISO"
  echo ""
  
  cat <<'EOF'
To get started, download a Windows 11 build from UUP dump:

  1. Visit: https://uupdump.net
  2. Select a build (e.g., "Latest Dev Channel build")
  3. Choose your language (e.g., English (United States))
  4. Choose your edition(s) (e.g., Windows 11 Professional)
  5. Click the "Download" button and save the ZIP file

Press Enter when you're ready to select the downloaded ZIP file...
EOF
  
  read -r -p "" < /dev/tty
  echo ""
  
  local zip_file=""
  
  # Try GUI file picker first
  if command -v zenity &>/dev/null; then
    msg "Opening file picker..."
    zip_file=$(zenity --file-selection --title="Select UUP dump ZIP file" --file-filter="ZIP files (*.zip) | *.zip" --file-filter="All files | *" 2>/dev/null || true)
  elif command -v kdialog &>/dev/null; then
    msg "Opening file picker..."
    zip_file=$(kdialog --getopenfilename ~ "*.zip|ZIP files (*.zip)" 2>/dev/null || true)
  else
    # Fallback to text input if no GUI available
    warn "No GUI file picker available (zenity or kdialog not found)"
    echo "Please enter the full path to the downloaded ZIP file:"
    echo "Example: /home/user/Downloads/28020.1362_amd64_en-us_multi_5510915e_convert.zip"
    echo ""
    read -r -p "Path to ZIP: " zip_file < /dev/tty
  fi
  
  check_cancel "$zip_file"
  
  if [[ -z "$zip_file" ]]; then
    fatal_error "No file selected" 1 \
      "Please run the script again and select the UUP dump ZIP file"
  fi
  
  # Check if it's a file path to an existing ZIP
  if [[ -f "$zip_file" ]]; then
    msg "Using ZIP file: $zip_file"
    
    # Extract the ZIP to tmp and run the conversion
    local pkg_dir="$TMP_DIR/uupdump-manual"
    rm -rf "$pkg_dir"
    mkdir -p "$pkg_dir"
    
    msg "Extracting UUP dump package..."
    if ! unzip -q "$zip_file" -d "$pkg_dir" 2>&1; then
      fatal_error "Failed to extract ZIP file" 40 \
        "The ZIP file may be corrupted or invalid"
    fi
    
    if [[ ! -x "$pkg_dir/uup_download_linux.sh" ]]; then
      chmod +x "$pkg_dir/uup_download_linux.sh" 2>/dev/null || true
    fi
    
    if [[ ! -f "$pkg_dir/uup_download_linux.sh" ]]; then
      fatal_error "Invalid UUP dump package" 40 \
        "ZIP file does not contain uup_download_linux.sh script"
    fi
    
    msg "Running UUP dump conversion (this may take a while)..."
    msg "This process downloads from Microsoft CDN and builds the ISO"
    
    if ! (cd "$pkg_dir" && bash ./uup_download_linux.sh 2>&1 | tee "$TMP_DIR/uup_build.log"); then
      fatal_error "UUP dump conversion failed" 40 \
        "Check $TMP_DIR/uup_build.log for details"
    fi
    
    local built_iso
    # Search for ISO file (case-insensitive - UUP dump can create .ISO or .iso)
    built_iso="$(find "$pkg_dir" -maxdepth 1 -type f \( -iname '*.iso' \) | head -n1)"
    
    if [[ -z "$built_iso" ]]; then
      fatal_error "No ISO produced" 40 \
        "Build completed but no ISO file found. Check $TMP_DIR/uup_build.log and $pkg_dir for files"
    fi
    
    mkdir -p "$ROOT_DIR/out"
    msg "Moving ISO to output directory..."
    mv "$built_iso" "$ROOT_DIR/out/win11.iso"
    
    msg "ISO created successfully: $ROOT_DIR/out/win11.iso"
    echo ""
  else
    fatal_error "File not found" 1 \
      "The selected file does not exist: $zip_file"
  fi
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
