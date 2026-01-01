#!/usr/bin/env bash
set -euo pipefail

# Cleanup script to remove temporary files and reset the environment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }

REMOVE_ISO=0
REMOVE_GRUB=0
CLEAN_ALL=0

usage() {
  cat <<'EOF'
Usage: cleanup.sh [--iso] [--grub] [--all]
  --iso   Remove downloaded/built ISOs from out/ directory
  --grub  Remove GRUB entry (requires root)
  --all   Remove everything (tmp/, out/, GRUB entry)
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --iso) REMOVE_ISO=1; shift;;
      --grub) REMOVE_GRUB=1; shift;;
      --all) CLEAN_ALL=1; REMOVE_ISO=1; REMOVE_GRUB=1; shift;;
      -h|--help) usage; exit 0;;
      *) warn "Unknown arg: $1"; shift;;
    esac
  done
}

clean_tmp() {
  if [[ -d "$ROOT_DIR/tmp" ]]; then
    msg "Cleaning tmp/ directory..."
    rm -rf "$ROOT_DIR/tmp"/*
    msg "tmp/ cleaned"
  fi
}

clean_iso() {
  if [[ -d "$ROOT_DIR/out" ]]; then
    msg "Removing ISOs from out/ directory..."
    rm -f "$ROOT_DIR/out"/*.iso
    msg "ISOs removed"
  fi
}

clean_grub() {
  msg "Removing GRUB entry (requires root)..."
  
  if [[ $EUID -ne 0 ]]; then
    warn "GRUB cleanup requires root. Run with sudo."
    return 1
  fi
  
  local grub_custom="/etc/grub.d/40_custom_win11"
  local iso_dest="/boot/win11.iso"
  
  if [[ -f "$grub_custom" ]]; then
    rm -f "$grub_custom"
    msg "Removed $grub_custom"
  fi
  
  if [[ -f "$iso_dest" ]]; then
    rm -f "$iso_dest"
    msg "Removed $iso_dest"
  fi
  
  # Regenerate GRUB config
  if command -v grub-mkconfig >/dev/null 2>&1; then
    msg "Regenerating grub.cfg..."
    grub-mkconfig -o /boot/grub/grub.cfg
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    msg "Regenerating grub.cfg..."
    grub2-mkconfig -o /boot/grub/grub.cfg
  fi
  
  msg "GRUB entry removed"
}

main() {
  parse_args "$@"
  
  if [[ $CLEAN_ALL -eq 0 && $REMOVE_ISO -eq 0 && $REMOVE_GRUB -eq 0 ]]; then
    msg "Cleaning tmp/ directory only (use --help for more options)"
    clean_tmp
    exit 0
  fi
  
  clean_tmp
  
  if [[ $REMOVE_ISO -eq 1 ]]; then
    clean_iso
  fi
  
  if [[ $REMOVE_GRUB -eq 1 ]]; then
    clean_grub
  fi
  
  msg "Cleanup complete"
}

main "$@"
