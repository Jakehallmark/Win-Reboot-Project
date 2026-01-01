#!/usr/bin/env bash
set -euo pipefail

GRUB_CFG="/boot/grub/grub.cfg"
ENTRY_NAME="Windows 11 installer (ISO loop)"

msg() { echo "[+] $*"; }
err() { echo "[!] $*" >&2; exit 1; }

main() {
  [[ $EUID -eq 0 ]] || err "Run as root (sudo)."
  [[ -f "$GRUB_CFG" ]] || err "grub.cfg not found at $GRUB_CFG"
  grep -q "$ENTRY_NAME" "$GRUB_CFG" || err "GRUB entry '$ENTRY_NAME' not found in $GRUB_CFG"
  msg "Found GRUB entry '$ENTRY_NAME'. Rebooting..."
  sleep 2
  systemctl reboot
}

main "$@"
