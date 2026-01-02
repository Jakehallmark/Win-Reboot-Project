#!/usr/bin/env bash
set -euo pipefail

# Display Win-Reboot-Project status and information

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

msg() { echo "[+] $*"; }
info() { echo "[i] $*"; }

main() {
  local version
  version="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo "unknown")"
  
  cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║            Win-Reboot-Project Status                          ║
║            Version: $version                                    ║
╚═══════════════════════════════════════════════════════════════╝

EOF

  info "Project Directory: $ROOT_DIR"
  echo ""
  
  # Check for downloaded ISOs
  msg "ISO Status:"
  if [[ -f "$ROOT_DIR/out/win11.iso" ]]; then
    local size_mb
    size_mb=$(($(stat -c%s "$ROOT_DIR/out/win11.iso") / 1024 / 1024))
    echo "  • out/win11.iso: ${size_mb} MB (found)"
  else
    echo "  • out/win11.iso: Not found"
  fi
  
  if [[ -f "$ROOT_DIR/out/win11-tiny.iso" ]]; then
    local size_mb
    size_mb=$(($(stat -c%s "$ROOT_DIR/out/win11-tiny.iso") / 1024 / 1024))
    echo "  • out/win11-tiny.iso: ${size_mb} MB (found)"
  else
    echo "  • out/win11-tiny.iso: Not found"
  fi
  echo ""
  
  # Check GRUB entry
  msg "GRUB Status:"
  if [[ -f "/etc/grub.d/40_custom_win11" ]]; then
    echo "  • GRUB entry: Installed"
  else
    echo "  • GRUB entry: Not installed"
  fi
  
  if [[ -f "/boot/win11.iso" ]]; then
    local size_mb
    size_mb=$(($(stat -c%s "/boot/win11.iso" 2>/dev/null || echo 0) / 1024 / 1024))
    echo "  • /boot/win11.iso: ${size_mb} MB (found)"
  else
    echo "  • /boot/win11.iso: Not found"
  fi
  echo ""
  
  # Check disk space
  msg "Disk Space:"
  echo "  • Project directory:"
  df -h "$ROOT_DIR" | tail -n1 | awk '{print "    Available: "$4" ("$5" used)"}'
  echo "  • /boot partition:"
  df -h /boot | tail -n1 | awk '{print "    Available: "$4" ("$5" used)"}'
  echo ""
  
  # Check dependencies
  msg "Quick Dependency Check:"
  local deps_ok=0
  for cmd in aria2c cabextract wimlib-imagex 7z curl python3 unzip hivexregedit; do
    if command -v "$cmd" >/dev/null 2>&1; then
      deps_ok=$((deps_ok + 1))
    fi
  done
  echo "  • $deps_ok/8 core dependencies found"
  if [[ $deps_ok -lt 8 ]]; then
    echo "    Run: ./scripts/check_deps.sh for details"
  fi
  echo ""
  
  # Available scripts
  msg "Available Scripts:"
  echo "  • ./scripts/interactive_setup.sh  - Full guided setup"
  echo "  • ./scripts/check_deps.sh         - Check dependencies"
  echo "  • ./scripts/fetch_iso.sh          - Download Windows 11 ISO"
  echo "  • ./scripts/tiny11.sh             - Apply Tiny11 trimming"
  echo "  • sudo ./scripts/grub_entry.sh    - Add GRUB entry"
  echo "  • ./scripts/cleanup.sh            - Cleanup files"
  echo "  • ./scripts/test.sh               - Run test suite"
  echo ""
  
  msg "Quick Commands:"
  echo "  • make check      - Check dependencies"
  echo "  • make fetch      - Download ISO"
  echo "  • make trim       - Apply Tiny11 trimming"
  echo "  • make help       - Show all make targets"
  echo ""
  
  info "Documentation:"
  echo "  • README.md         - Project overview"
  echo "  • INSTALL.md        - Installation guide"
  echo "  • CONTRIBUTING.md   - Contribution guidelines"
  echo ""
}

main "$@"
