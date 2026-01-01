#!/usr/bin/env bash
set -euo pipefail

# Copy Windows ISO to /boot and add a GRUB entry to boot the installer via loopback.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ISO_SRC="$ROOT_DIR/out/win11.iso"
ISO_DEST="/boot/win11.iso"
GRUB_CUSTOM="/etc/grub.d/40_custom_win11"
GRUB_CFG="/boot/grub/grub.cfg"

msg() { echo "[+] $*"; }
err() { echo "[!] $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: grub_entry.sh [path-to-iso] [--dest /boot/win11.iso]
Requires root. Secure Boot must be disabled.
EOF
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing command: $c"
  done
}

detect_grub_mkconfig() {
  if command -v grub-mkconfig >/dev/null 2>&1; then
    echo "grub-mkconfig"
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    echo "grub2-mkconfig"
  else
    err "grub-mkconfig/grub2-mkconfig not found"
  fi
}

main() {
  local iso_set=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --dest) ISO_DEST="$2"; shift 2;;
      *) 
        if [[ $iso_set -eq 0 ]]; then
          ISO_SRC="$1"; iso_set=1; shift
        else
          err "Unknown arg: $1"
        fi
        ;;
    esac
  done

  [[ $EUID -eq 0 ]] || err "Run as root (sudo)."
  [[ -f "$ISO_SRC" ]] || err "ISO not found: $ISO_SRC"
  require_cmd cp stat grep awk

  local iso_size_mb
  iso_size_mb=$(($(stat -c%s "$ISO_SRC") / 1024 / 1024))
  msg "Copying ISO to $ISO_DEST (${iso_size_mb} MB)..."
  cp "$ISO_SRC" "$ISO_DEST"

  cat >"$GRUB_CUSTOM" <<'GRUB'
menuentry "Windows 11 installer (ISO loop)" {
    set isofile="/boot/win11.iso"
    search --no-floppy --set=iso_root --file $isofile
    loopback loop ($iso_root)$isofile
    chainloader (loop)/efi/boot/bootx64.efi
}
GRUB
  chmod +x "$GRUB_CUSTOM"
  msg "Wrote $GRUB_CUSTOM"

  local mkcfg
  mkcfg="$(detect_grub_mkconfig)"

  if command -v grub-script-check >/dev/null 2>&1; then
    msg "Validating GRUB script..."
    grub-script-check "$GRUB_CUSTOM"
  fi

  msg "Regenerating grub.cfg..."
  "$mkcfg" -o "$GRUB_CFG"
  msg "Done. Review $GRUB_CFG and reboot when ready."
}

main "$@"
