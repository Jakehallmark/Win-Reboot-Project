#!/usr/bin/env bash
set -euo pipefail

# Common error handling and troubleshooting library for Win-Reboot-Project
# Source this file in scripts: source "$(dirname "$0")/lib_error.sh"

# Color codes for output (if terminal supports it)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  BLUE='\033[0;34m'
  NC='\033[0m' # No Color
else
  RED=''
  YELLOW=''
  GREEN=''
  BLUE=''
  NC=''
fi

# Track temporary directories for cleanup
declare -a TEMP_DIRS=()
declare -a TEMP_FILES=()

# Register cleanup handler
cleanup_on_exit() {
  local exit_code=$?
  
  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo -e "${YELLOW}[!] Script exited with error code $exit_code${NC}" >&2
    echo -e "${YELLOW}[!] Cleaning up temporary files...${NC}" >&2
  fi
  
  # Unmount any mounted WIM images
  if command -v wimlib-imagex >/dev/null 2>&1; then
    for mount_point in "${TEMP_DIRS[@]}"; do
      if [[ -d "$mount_point/mount" ]] && mountpoint -q "$mount_point/mount" 2>/dev/null; then
        echo "[!] Unmounting WIM at $mount_point/mount" >&2
        wimlib-imagex unmount "$mount_point/mount" 2>/dev/null || true
      fi
    done
  fi
  
  # Remove temporary directories
  for dir in "${TEMP_DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
      rm -rf "$dir" 2>/dev/null || true
    fi
  done
  
  # Remove temporary files
  for file in "${TEMP_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      rm -f "$file" 2>/dev/null || true
    fi
  done
}

# Set up trap for cleanup
trap cleanup_on_exit EXIT INT TERM

# Register a temporary directory for cleanup
register_temp_dir() {
  TEMP_DIRS+=("$1")
}

# Register a temporary file for cleanup
register_temp_file() {
  TEMP_FILES+=("$1")
}

# Enhanced error function with troubleshooting
fatal_error() {
  local error_msg="$1"
  local error_code="${2:-1}"
  local context="${3:-}"
  
  echo ""
  echo -e "${RED}╔═══════════════════════════════════════════════════════════════╗${NC}" >&2
  echo -e "${RED}║                    CRITICAL ERROR                             ║${NC}" >&2
  echo -e "${RED}╚═══════════════════════════════════════════════════════════════╝${NC}" >&2
  echo ""
  echo -e "${RED}Error: $error_msg${NC}" >&2
  
  if [[ -n "$context" ]]; then
    echo ""
    echo -e "${YELLOW}Context: $context${NC}" >&2
  fi
  
  echo ""
  show_troubleshooting "$error_code"
  
  exit "$error_code"
}

# Show context-specific troubleshooting steps
show_troubleshooting() {
  local error_code="$1"
  
  echo -e "${BLUE}Troubleshooting Steps:${NC}" >&2
  echo "" >&2
  
  case "$error_code" in
    10) # Dependency missing
      cat >&2 <<'EOF'
1. Run the dependency checker:
   ./scripts/check_deps.sh

2. Install missing packages for your distribution:

   Debian/Ubuntu:
   sudo apt install aria2 cabextract wimtools genisoimage p7zip-full grub-common curl python3 unzip libhivex-bin

   Fedora/RHEL:
   sudo dnf install aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools curl python3 unzip hivex

   Arch:
   sudo pacman -S aria2 cabextract wimlib cdrtools p7zip grub curl python3 hivex

3. Verify installation:
   which aria2c wimlib-imagex 7z curl python3 hivexregedit

For more help, see: INSTALL.md
EOF
      ;;
    20) # Network error
      cat >&2 <<'EOF'
1. Check your internet connection:
   ping -c 3 8.8.8.8

2. Test access to required services:
   curl -I https://uupdump.net
   curl -I https://github.com

3. Check if you're behind a proxy:
   echo $http_proxy $https_proxy

4. If behind a firewall, ensure these domains are accessible:
   - uupdump.net
   - download.microsoft.com
   - *.dl.delivery.mp.microsoft.com

5. Try again with a different network or wait a moment and retry

For more help, see: INSTALL.md (Troubleshooting section)
EOF
      ;;
    30) # Disk space error
      cat >&2 <<'EOF'
1. Check available disk space:
   df -h $HOME
   df -h /boot

2. Clean up temporary files:
   ./scripts/cleanup.sh

3. Remove old ISOs if not needed:
   ./scripts/cleanup.sh --iso

4. Required space:
   - ~/Win-Reboot-Project/tmp: ~10 GB (temporary)
   - ~/Win-Reboot-Project/out: ~6 GB (ISO storage)
   - /boot: ~6 GB (installer ISO)

5. Consider using a different partition with more space:
   export OUT_DIR=/path/to/larger/partition/out
   export TMP_DIR=/path/to/larger/partition/tmp

For more help, see: INSTALL.md
EOF
      ;;
    40) # WIM/ISO manipulation error
      cat >&2 <<'EOF'
1. Verify wimlib-imagex is installed:
   wimlib-imagex --version

2. Check if the ISO is corrupted:
   7z t /path/to/iso/file

3. Verify you have write permissions:
   touch out/test.txt && rm out/test.txt

4. Check for sufficient disk space (see error 30 troubleshooting)

5. Try with a fresh ISO download:
   rm out/win11.iso
   ./scripts/fetch_iso.sh

6. If using custom preset, verify the file exists:
   ls -la data/removal-presets/

For more help, see: INSTALL.md (Tiny11 Trimming Fails section)
EOF
      ;;
    50) # GRUB error
      cat >&2 <<'EOF'
1. Verify you have root permissions:
   sudo -v

2. Check if GRUB is properly installed:
   which grub-mkconfig || which grub2-mkconfig
   ls -la /boot/grub/grub.cfg

3. Verify UEFI boot mode (not BIOS):
   [ -d /sys/firmware/efi ] && echo "UEFI" || echo "BIOS"
   (GRUB loopback requires UEFI)

4. Check Secure Boot status (must be disabled):
   mokutil --sb-state 2>/dev/null || echo "mokutil not installed"
   
5. Manually check GRUB configuration:
   sudo grub-script-check /etc/grub.d/40_custom_win11

6. Test GRUB config generation:
   sudo grub-mkconfig -o /tmp/test-grub.cfg

7. Verify /boot has enough space:
   df -h /boot

For more help, see: INSTALL.md (GRUB Entry Not Appearing section)
EOF
      ;;
    60) # Permission error
      cat >&2 <<'EOF'
1. Check file permissions:
   ls -la out/ tmp/

2. Verify you own the directories:
   stat -c '%U' out/ tmp/

3. For GRUB operations, ensure you use sudo:
   sudo ./scripts/grub_entry.sh out/win11.iso

4. Fix ownership if needed:
   sudo chown -R $USER:$USER ~/Win-Reboot-Project

5. Check if filesystem is read-only:
   mount | grep "$(df . | tail -1 | awk '{print $1}')"

For more help, see: INSTALL.md
EOF
      ;;
    *) # Generic error
      cat >&2 <<'EOF'
1. Review the error message above carefully

2. Check the logs in tmp/ directory if they exist

3. Run with verbose mode if available:
   bash -x ./scripts/script_name.sh

4. Verify all prerequisites are met:
   ./scripts/check_deps.sh

5. Try in a clean environment:
   ./scripts/cleanup.sh
   # Then start over

6. Check project status:
   ./scripts/status.sh

7. For more detailed help:
   - See INSTALL.md for comprehensive troubleshooting
   - See QUICKREF.md for common tasks
   - Open an issue: https://github.com/Jakehallmark/Win-Reboot-Project/issues

For general help, see: INSTALL.md or QUICKREF.md
EOF
      ;;
  esac
  
  echo "" >&2
  echo -e "${YELLOW}If the problem persists, please open an issue on GitHub with:${NC}" >&2
  echo -e "${YELLOW}- The full error message${NC}" >&2
  echo -e "${YELLOW}- Your Linux distribution and version${NC}" >&2
  echo -e "${YELLOW}- Output of ./scripts/check_deps.sh${NC}" >&2
  echo -e "${YELLOW}- Any relevant log files from tmp/${NC}" >&2
  echo "" >&2
}

# Check for required commands with detailed error
require_commands() {
  local missing=()
  
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    fatal_error "Missing required commands: ${missing[*]}" 10 \
      "These commands are essential for the script to function."
  fi
}

# Check disk space with detailed error
check_disk_space() {
  local path="$1"
  local required_mb="$2"
  local description="${3:-this operation}"
  
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" 2>/dev/null || \
      fatal_error "Cannot create directory: $path" 60 "Check permissions for parent directory"
  fi
  
  local available_mb
  available_mb=$(df -BM "$path" | tail -1 | awk '{print $4}' | sed 's/M//')
  
  if [[ $available_mb -lt $required_mb ]]; then
    fatal_error "Insufficient disk space in $path" 30 \
      "Required: ${required_mb}MB, Available: ${available_mb}MB for $description"
  fi
}

# Network check with detailed error
check_network() {
  local test_url="${1:-https://uupdump.net}"
  
  if ! curl -s --max-time 10 --head "$test_url" >/dev/null 2>&1; then
    fatal_error "Cannot reach $test_url" 20 \
      "Network connectivity is required to download Windows 11 ISO"
  fi
}

# Verify file integrity
verify_file() {
  local file="$1"
  local min_size_mb="${2:-1}"
  local description="${3:-file}"
  
  if [[ ! -f "$file" ]]; then
    fatal_error "$description not found: $file" 1 \
      "Expected file does not exist"
  fi
  
  local size_mb
  size_mb=$(($(stat -c%s "$file" 2>/dev/null || echo 0) / 1024 / 1024))
  
  if [[ $size_mb -lt $min_size_mb ]]; then
    fatal_error "$description is too small: ${size_mb}MB" 1 \
      "Expected at least ${min_size_mb}MB, got ${size_mb}MB. File may be corrupted."
  fi
}

# Success message
success_msg() {
  echo ""
  echo -e "${GREEN}╔═══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                    SUCCESS                                    ║${NC}"
  echo -e "${GREEN}╚═══════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${GREEN}$1${NC}"
  echo ""
}

# Export functions so they can be used by sourcing scripts
export -f cleanup_on_exit
export -f register_temp_dir
export -f register_temp_file
export -f fatal_error
export -f show_troubleshooting
export -f require_commands
export -f check_disk_space
export -f check_network
export -f verify_file
export -f success_msg
