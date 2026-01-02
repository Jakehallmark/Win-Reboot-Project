#!/usr/bin/env bash
set -euo pipefail

# Checks and optionally installs dependencies for Win-Reboot-Project scripts

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

MISSING=()
AUTO_INSTALL=0
SILENT=0

usage() {
  cat <<'EOF'
Usage: check_deps.sh [--auto-install] [--silent]

Options:
  --auto-install    Attempt to automatically install missing dependencies
  --silent          Suppress output except errors
  -h, --help        Show this help message
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto-install) AUTO_INSTALL=1; shift;;
      --silent) SILENT=1; shift;;
      -h|--help) usage; exit 0;;
      *) warn "Unknown arg: $1"; shift;;
    esac
  done
}

check_cmd() {
  local cmd="$1"
  local pkg="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$pkg")
    [[ $SILENT -eq 0 ]] && warn "Missing: $cmd (package: $pkg)"
  else
    [[ $SILENT -eq 0 ]] && msg "Found: $cmd"
  fi
  # Always return 0 to prevent set -e from exiting early
  return 0
}

detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

get_package_manager() {
  local distro="$1"
  case "$distro" in
    debian|ubuntu|linuxmint|pop) echo "apt";;
    fedora|rhel|centos|rocky|almalinux) echo "dnf";;
    arch|manjaro|endeavouros) echo "pacman";;
    *) echo "unknown";;
  esac
}

get_packages_for_distro() {
  local distro="$1"
  case "$distro" in
    debian|ubuntu|linuxmint|pop)
      # Note: Debian/Ubuntu use python3-hivex for registry editing (hivexregedit not available)
      echo "aria2 cabextract wimtools genisoimage p7zip-full grub-common curl python3 unzip python3-hivex chntpw"
      ;;
    fedora|rhel|centos|rocky|almalinux)
      echo "aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools curl python3 unzip hivex chntpw"
      ;;
    arch|manjaro|endeavouros)
      echo "aria2 cabextract wimlib cdrtools p7zip grub curl python3 hivex chntpw"
      ;;
    *)
      echo ""
      ;;
  esac
}

can_sudo() {
  sudo -n true 2>/dev/null
}

prompt_yn() {
  local prompt="$1"
  local answer
  # Use /dev/tty if stdin is not available (e.g., when piped from curl)
  if [[ -t 0 ]]; then
    read -r -p "$prompt [y/N]: " answer
  else
    read -r -p "$prompt [y/N]: " answer < /dev/tty
  fi
  [[ "${answer,,}" == "y" ]]
}

auto_install_dependencies() {
  local distro
  distro="$(detect_distro)"
  
  local pkg_mgr
  pkg_mgr="$(get_package_manager "$distro")"
  
  if [[ "$pkg_mgr" == "unknown" ]]; then
    warn "Cannot auto-install on unknown distribution: $distro"
    return 1
  fi
  
  local packages
  packages="$(get_packages_for_distro "$distro")"
  
  msg "Detected distribution: $distro"
  msg "Package manager: $pkg_mgr"
  echo ""
  
  # Check if we can sudo without password
  if can_sudo; then
    msg "Installing dependencies with sudo..."
    case "$pkg_mgr" in
      apt)
        sudo apt update -qq && sudo apt install -y $packages
        ;;
      dnf)
        sudo dnf install -y $packages
        ;;
      pacman)
        sudo pacman -S --noconfirm $packages
        ;;
    esac
    return $?
  else
    # Ask for permission
    echo "Missing dependencies need to be installed."
    echo "This requires administrator (sudo) privileges."
    echo ""
    echo "Will install: $packages"
    echo ""
    
    if prompt_yn "Install dependencies now?"; then
      case "$pkg_mgr" in
        apt)
          sudo apt update && sudo apt install -y $packages
          ;;
        dnf)
          sudo dnf install -y $packages
          ;;
        pacman)
          sudo pacman -S --noconfirm $packages
          ;;
      esac
      return $?
    else
      return 1
    fi
  fi
}

show_manual_instructions() {
  local distro
  distro="$(detect_distro)"
  
  echo ""
  echo "╔═══════════════════════════════════════════════════════════════╗"
  echo "║              Installation Instructions Required              ║"
  echo "╚═══════════════════════════════════════════════════════════════╝"
  echo ""
  echo "I know, I know... reading documentation is so last century."
  echo "But since we're here anyway, let me hold your hand through this:"
  echo ""
  warn "Missing ${#MISSING[@]} package(s): ${MISSING[*]}"
  echo ""
  
  case "$distro" in
    debian|ubuntu|linuxmint|pop)
      echo "For Debian/Ubuntu-based systems, copy and paste this:"
      echo ""
      echo "  sudo apt update && sudo apt install -y aria2 cabextract wimtools genisoimage p7zip-full grub-common curl python3 unzip python3-hivex chntpw"
      echo ""
      ;;
    fedora|rhel|centos|rocky|almalinux)
      echo "For Fedora/RHEL-based systems, copy and paste this:"
      echo ""
      echo "  sudo dnf install -y aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools curl python3 unzip hivex chntpw"
      echo ""
      ;;
    arch|manjaro|endeavouros)
      echo "For Arch-based systems (because of course you use Arch):"
      echo ""
      echo "  sudo pacman -S aria2 cabextract wimlib cdrtools p7zip grub curl python3 hivex chntpw"
      echo ""
      ;;
    *)
      echo "For your system, you'll need these packages:"
      echo "  aria2, cabextract, wimlib/wimtools, genisoimage/xorriso,"
      echo "  p7zip, grub, curl, python3, unzip, hivex/python3-hivex, chntpw"
      echo ""
      echo "Check your distro's package manager. You got this!"
      echo ""
      ;;
  esac

  echo "Note: Registry editing requires hivexregedit (Fedora/Arch) or python3-hivex (Debian/Ubuntu)."
  
  echo ""
  echo "Once installed, run this script again or proceed with:"
  echo "  ./scripts/interactive_setup.sh"
  echo ""
  echo "Pro tip: Next time, try running with --auto-install flag."
  echo "It's like magic, but with more sudo."
  echo ""
}

main() {
  parse_args "$@"
  
  [[ $SILENT -eq 0 ]] && msg "Checking dependencies for Win-Reboot-Project..."
  [[ $SILENT -eq 0 ]] && echo ""
  
  # Core tools
  check_cmd "aria2c" "aria2"
  check_cmd "cabextract" "cabextract"
  check_cmd "wimlib-imagex" "wimtools/wimlib"
  check_cmd "7z" "p7zip"
  check_cmd "curl" "curl"
  check_cmd "python3" "python3"
  check_cmd "unzip" "unzip"

  # Registry editing tool (hivexregedit OR python3-hivex)
  if command -v hivexregedit >/dev/null 2>&1; then
    [[ $SILENT -eq 0 ]] && msg "Found: hivexregedit"
  elif python3 -c "import hivex" 2>/dev/null; then
    [[ $SILENT -eq 0 ]] && msg "Found: python3-hivex (alternative to hivexregedit)"
  else
    MISSING+=("hivexregedit or python3-hivex")
    [[ $SILENT -eq 0 ]] && warn "Missing: hivexregedit or python3-hivex (needed for registry tweaks)"
  fi

  # ISO building tools (one of these)
  if ! command -v genisoimage >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
    MISSING+=("genisoimage or xorriso")
    [[ $SILENT -eq 0 ]] && warn "Missing: genisoimage or xorriso (needed for ISO rebuild)"
  else
    if command -v xorriso >/dev/null 2>&1; then
      [[ $SILENT -eq 0 ]] && msg "Found: xorriso"
    else
      [[ $SILENT -eq 0 ]] && msg "Found: genisoimage"
    fi
  fi
  
  # GRUB tools
  if ! command -v grub-mkconfig >/dev/null 2>&1 && ! command -v grub2-mkconfig >/dev/null 2>&1; then
    MISSING+=("grub-mkconfig")
    [[ $SILENT -eq 0 ]] && warn "Missing: grub-mkconfig/grub2-mkconfig"
  else
    [[ $SILENT -eq 0 ]] && msg "Found: grub-mkconfig or grub2-mkconfig"
  fi
  
  # Note: hivexregedit is already checked above with check_cmd
  
  echo ""
  
  # Handle missing dependencies
  if [[ ${#MISSING[@]} -eq 0 ]]; then
    msg "All dependencies are installed!"
    return 0
  fi
  
  # Try auto-install if requested
  if [[ $AUTO_INSTALL -eq 1 ]]; then
    echo ""
    msg "Missing ${#MISSING[@]} package(s), attempting automatic installation..."
    echo ""
    if auto_install_dependencies; then
      echo ""
      msg "Dependencies installed successfully!"
      msg "Re-checking dependencies..."
      echo ""
      # Re-check to verify installation (all core tools)
      MISSING=()
      check_cmd "aria2c" "aria2"
      check_cmd "cabextract" "cabextract"
      check_cmd "wimlib-imagex" "wimtools/wimlib"
      check_cmd "7z" "p7zip"
      check_cmd "curl" "curl"
      check_cmd "python3" "python3"
      check_cmd "unzip" "unzip"

      # Re-check registry editing tool (hivexregedit OR python3-hivex)
      if ! command -v hivexregedit >/dev/null 2>&1 && ! python3 -c "import hivex" 2>/dev/null; then
        MISSING+=("hivexregedit or python3-hivex")
        [[ $SILENT -eq 0 ]] && warn "Missing: hivexregedit or python3-hivex"
      fi

      # Re-check ISO building tools
      if ! command -v genisoimage >/dev/null 2>&1 && ! command -v xorriso >/dev/null 2>&1; then
        MISSING+=("genisoimage or xorriso")
        [[ $SILENT -eq 0 ]] && warn "Missing: genisoimage or xorriso"
      fi

      # Re-check GRUB tools
      if ! command -v grub-mkconfig >/dev/null 2>&1 && ! command -v grub2-mkconfig >/dev/null 2>&1; then
        MISSING+=("grub-mkconfig")
        [[ $SILENT -eq 0 ]] && warn "Missing: grub-mkconfig/grub2-mkconfig"
      fi

      if [[ ${#MISSING[@]} -gt 0 ]]; then
        warn "Some packages still missing after installation attempt"
        return 1
      fi
      return 0
    else
      warn "Auto-install failed or was declined"
      show_manual_instructions
      return 1
    fi
  else
    # Just show manual instructions
    show_manual_instructions
    return 1
  fi
}

main "$@"
