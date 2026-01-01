#!/usr/bin/env bash
set -euo pipefail

# Checks dependencies for Win-Reboot-Project scripts

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

MISSING=()

check_cmd() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$pkg")
    warn "Missing: $cmd (package: $pkg)"
  else
    msg "Found: $cmd"
  fi
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

suggest_install() {
  local distro
  distro="$(detect_distro)"
  
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    msg "All dependencies are installed!"
    return 0
  fi
  
  echo ""
  warn "Missing ${#MISSING[@]} package(s)"
  echo ""
  
  case "$distro" in
    debian|ubuntu|linuxmint|pop)
      echo "Install with:"
      echo "  sudo apt update && sudo apt install -y aria2 cabextract wimtools genisoimage p7zip-full grub-common curl python3 unzip"
      ;;
    fedora|rhel|centos|rocky|almalinux)
      echo "Install with:"
      echo "  sudo dnf install -y aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools curl python3 unzip"
      ;;
    arch|manjaro|endeavouros)
      echo "Install with:"
      echo "  sudo pacman -S aria2 cabextract wimlib cdrtools p7zip grub curl python3"
      ;;
    *)
      echo "Unknown distro. Required packages:"
      echo "  aria2, cabextract, wimlib/wimtools, genisoimage/xorriso, p7zip, grub, curl, python3, unzip"
      ;;
  esac
}

main() {
  msg "Checking dependencies for Win-Reboot-Project..."
  echo ""
  
  # Core tools
  check_cmd "aria2c" "aria2"
  check_cmd "cabextract" "cabextract"
  check_cmd "wimlib-imagex" "wimtools/wimlib"
  check_cmd "7z" "p7zip"
  check_cmd "curl" "curl"
  check_cmd "python3" "python3"
  check_cmd "unzip" "unzip"
  
  # ISO building tools (one of these)
  if ! command -v genisoimage >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
    MISSING+=("genisoimage or xorriso")
    warn "Missing: genisoimage or xorriso (needed for ISO rebuild)"
  else
    if command -v xorriso >/dev/null 2>&1; then
      msg "Found: xorriso"
    else
      msg "Found: genisoimage"
    fi
  fi
  
  # GRUB tools
  if ! command -v grub-mkconfig >/dev/null 2>&1 && ! command -v grub2-mkconfig >/dev/null 2>&1; then
    MISSING+=("grub-mkconfig")
    warn "Missing: grub-mkconfig/grub2-mkconfig"
  else
    msg "Found: grub-mkconfig or grub2-mkconfig"
  fi
  
  # Optional but recommended
  if ! command -v hivexregedit >/dev/null 2>&1; then
    warn "Optional: hivexregedit not found (registry tweaks will be skipped)"
  else
    msg "Found: hivexregedit (optional)"
  fi
  
  echo ""
  suggest_install
}

main "$@"
