#!/usr/bin/env bash
set -euo pipefail

# Win-Reboot-Project: All-in-One Windows 11 Setup
# Inspired by the Tiny11 Project by ntdevlabs
#
# Usage:
#   Local:  ./win11-setup.sh
#   Remote: curl -fsSL https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/win11-setup.sh | bash

#============================================================================
# CONFIGURATION
#============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"
TMP_DIR="${TMP_DIR:-$ROOT_DIR/tmp}"
OUT_DIR="$ROOT_DIR/out"
ISO_PATH="$OUT_DIR/win11.iso"
INSTALLER_SIZE_GB=10

mkdir -p "$TMP_DIR" "$OUT_DIR"

#============================================================================
# UTILITY FUNCTIONS
#============================================================================

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] ERROR: $*" >&2; exit 1; }

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

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing required command: $c (install it first)"
  done
}

#============================================================================
# DEPENDENCY CHECKING
#============================================================================

check_dependencies() {
  msg "Checking dependencies..."
  
  local missing=()
  local distro=""
  
  # Detect distro
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    distro="$ID"
  fi
  
  # Required commands
  local required_cmds=("aria2c" "cabextract" "wimlib-imagex" "chntpw" "genisoimage" "xorriso" "unzip" "parted" "mkfs.fat")
  
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done
  
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${missing[*]}"
    
    if prompt_yn "Auto-install missing dependencies?" "y"; then
      case "$distro" in
        ubuntu|debian|linuxmint|pop)
          sudo apt-get update
          sudo apt-get install -y aria2 cabextract wimtools chntpw genisoimage xorriso unzip parted dosfstools
          ;;
        fedora|rhel|centos)
          sudo dnf install -y aria2 cabextract wimlib-utils chntpw genisoimage xorriso unzip parted dosfstools
          ;;
        arch|manjaro)
          sudo pacman -S --needed --noconfirm aria2 cabextract wimlib chntpw cdrtools libisoburn unzip parted dosfstools
          ;;
        *)
          err "Unsupported distro: $distro. Install packages manually: ${missing[*]}"
          ;;
      esac
      msg "Dependencies installed"
    else
      err "Cannot continue without required dependencies"
    fi
  fi
  
  echo ""
}

#============================================================================
# STEP 1: FETCH ISO
#============================================================================

step_fetch_iso() {
  msg "Step 1: Fetch Windows 11 ISO"
  echo ""
  
  if [[ -f "$ISO_PATH" ]]; then
    if prompt_yn "ISO already exists at $ISO_PATH. Use it?" "y"; then
      return 0
    fi
  fi
  
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
  
  # Try GUI file picker
  if command -v zenity &>/dev/null; then
    zip_file=$(zenity --file-selection --title="Select UUP dump ZIP file" --file-filter="ZIP files (*.zip) | *.zip" 2>/dev/null || true)
  elif command -v kdialog &>/dev/null; then
    zip_file=$(kdialog --getopenfilename ~ "*.zip|ZIP files (*.zip)" 2>/dev/null || true)
  else
    # Fallback to text input
    warn "No GUI file picker available"
    read -r -p "Path to UUP dump ZIP: " zip_file < /dev/tty
  fi
  
  [[ -f "$zip_file" ]] || err "File not found: $zip_file"
  
  msg "Extracting UUP dump package..."
  local pkg_dir="$TMP_DIR/uupdump"
  rm -rf "$pkg_dir"
  mkdir -p "$pkg_dir"
  unzip -q "$zip_file" -d "$pkg_dir" || err "Failed to extract ZIP"
  
  [[ -f "$pkg_dir/uup_download_linux.sh" ]] || err "Invalid UUP dump package"
  chmod +x "$pkg_dir/uup_download_linux.sh"
  
  msg "Running UUP dump conversion (this may take a while)..."
  (cd "$pkg_dir" && bash ./uup_download_linux.sh) || err "UUP dump conversion failed"
  
  local built_iso
  built_iso="$(find "$pkg_dir" -maxdepth 1 -type f -iname '*.iso' | head -n1)"
  [[ -n "$built_iso" ]] || err "No ISO produced"
  
  mv "$built_iso" "$ISO_PATH"
  msg "✓ ISO created: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 2: TINY11 TRIMMING
#============================================================================

step_tiny11() {
  msg "Step 2: Tiny11 trimming (optional)"
  echo ""
  
  prompt_yn "Apply Tiny11 trimming to reduce ISO size?" "y" || {
    msg "Skipping trimming"
    return 0
  }
  
  echo "Available presets:"
  echo "  minimal    - Remove consumer apps; keep Store, Defender, BitLocker"
  echo "  lite       - minimal + remove WinRE/Help, Media Player, Quick Assist"
  echo "  aggressive - minimal + Photos/Maps/Camera/Calculator/Paint"
  echo "  vanilla    - No changes"
  echo ""
  
  local preset
  read -r -p "Preset [minimal/lite/aggressive/vanilla]: " preset < /dev/tty
  preset="${preset:-minimal}"
  
  if [[ "$preset" == "vanilla" ]]; then
    msg "Skipping trimming (vanilla)"
    return 0
  fi
  
  require_cmd wimlib-imagex
  
  msg "Applying $preset preset..."
  
  local work_dir="$TMP_DIR/tiny11"
  local mount_dir="$work_dir/mount"
  local iso_mount="$work_dir/iso"
  
  rm -rf "$work_dir"
  mkdir -p "$mount_dir" "$iso_mount"
  
  msg "Extracting ISO..."
  
  # Try multiple extraction methods
  if command -v 7z >/dev/null 2>&1; then
    msg "Using 7z for extraction..."
    7z x -y -o"$iso_mount" "$ISO_PATH" >/dev/null 2>&1 || err "Failed to extract ISO with 7z"
  elif command -v iso-read >/dev/null 2>&1; then
    msg "Using iso-read for extraction..."
    iso-read -l "$ISO_PATH" | while read -r file; do
      [[ -z "$file" ]] && continue
      mkdir -p "$iso_mount/$(dirname "$file")"
      iso-read -f "$file" -o "$iso_mount/$file" -i "$ISO_PATH" 2>/dev/null || true
    done
  else
    # Last resort: try mounting as loop
    msg "Using loop mount for extraction..."
    sudo mount -o loop "$ISO_PATH" "$iso_mount" || err "Failed to mount ISO"
  fi
  
  # Find install.wim or install.esd (case-insensitive)
  local wim_file=""
  wim_file=$(find "$iso_mount" -type f -iname "install.wim" -o -iname "install.esd" | head -n1)
  
  if [[ -z "$wim_file" ]]; then
    warn "Cannot find install.wim or install.esd"
    warn "ISO contents:"
    ls -la "$iso_mount/" || true
    [[ -d "$iso_mount/sources" ]] && ls -la "$iso_mount/sources/" || true
    err "No install.wim or install.esd found in ISO"
  fi
  
  msg "Found WIM file: $wim_file"
  
  if [[ "$wim_file" == *.esd || "$wim_file" == *.ESD ]]; then
    msg "Converting ESD to WIM..."
    local wim_dir="$(dirname "$wim_file")"
    local new_wim="$wim_dir/install.wim"
    wimlib-imagex export "$wim_file" all "$new_wim" --compress=LZX --check || err "ESD conversion failed"
    rm "$wim_file"
    wim_file="$new_wim"
    msg "Converted to: $wim_file"
  fi
  
  local image_count
  image_count=$(wimlib-imagex info "$wim_file" | grep "Image Count:" | awk '{print $3}')
  
  msg "Processing $image_count Windows edition(s)..."
  
  for ((img=1; img<=image_count; img++)); do
    msg "Processing image $img/$image_count..."
    
    wimlib-imagex mountrw "$wim_file" "$img" "$mount_dir" || err "Failed to mount image $img"
    
    # Load preset (local or download from GitHub)
    local preset_file="$ROOT_DIR/data/removal-presets/${preset}.txt"
    if [[ ! -f "$preset_file" ]]; then
      preset_file="$TMP_DIR/removal-presets/${preset}.txt"
      if [[ ! -f "$preset_file" ]]; then
        msg "Downloading preset from GitHub..."
        mkdir -p "$TMP_DIR/removal-presets"
        local preset_url="https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/data/removal-presets/${preset}.txt"
        if ! curl -fsSL "$preset_url" -o "$preset_file" 2>/dev/null; then
          warn "Failed to download preset, continuing without package removal"
          wimlib-imagex unmount "$mount_dir" --commit
          continue
        fi
      fi
    fi
    
    if [[ -f "$preset_file" ]]; then
      msg "Removing packages from preset: $preset"
      while IFS= read -r pkg; do
        [[ -z "$pkg" || "$pkg" =~ ^# ]] && continue
        find "$mount_dir" -type d -iname "*$pkg*" 2>/dev/null | while read -r dir; do
          rm -rf "$dir" 2>/dev/null || true
        done
      done < "$preset_file"
    fi
    
    msg "Unmounting image..."
    wimlib-imagex unmount "$mount_dir" --commit || err "Failed to unmount"
    sleep 2
  done
  
  msg "Rebuilding ISO..."
  local tiny_iso="$OUT_DIR/win11-tiny.iso"
  
  xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "WIN11_TINY" \
    -eltorito-boot boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
    -o "$tiny_iso" \
    "$iso_mount" 2>/dev/null || err "Failed to create ISO"
  
  # Cleanup: unmount if it was mounted
  if mountpoint -q "$iso_mount" 2>/dev/null; then
    msg "Unmounting ISO..."
    sudo umount "$iso_mount" || true
  fi
  
  mv "$tiny_iso" "$ISO_PATH"
  msg "✓ Tiny11 ISO ready: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 3: MEDIA SETUP
#============================================================================

ask_bootloader() {
  echo ""
  echo ""
  msg "╔════════════════════════════════════════╗"
  msg "║      Choose How to Boot Windows        ║"
  msg "╚════════════════════════════════════════╝"
  echo ""
  echo "  1) GRUB (integrated with Linux bootloader)"
  echo "     - Windows installer appears in GRUB menu"
  echo "     - Still depends on Linux boot working"
  echo ""
  echo "  2) Windows Bootloader (direct UEFI boot)"
  echo "     - Boot directly without GRUB"
  echo "     - Works even if Linux boot is broken"
  echo "     - Change BIOS boot order to USB/disk"
  echo ""
  
  local answer
  read -r -p "Select bootloader (1 or 2): " answer < /dev/tty
  
  if [[ "$answer" == "2" ]]; then
    echo "windows"
  elif [[ "$answer" == "1" ]]; then
    echo "grub"
  else
    warn "Invalid selection. Using GRUB (default)."
    echo "grub"
  fi
}

setup_usb() {
  msg "=== Bootable USB Setup ==="
  
  msg "Detecting removable devices..."
  local devices=()
  while IFS= read -r line; do
    local dev size rm
    dev=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    rm=$(echo "$line" | awk '{print $4}')
    
    [[ "$rm" == "1" ]] || continue
    
    local size_gb=$((size / 1024 / 1024 / 1024))
    devices+=("$dev:$size_gb")
    echo "  ${#devices[@]}) $dev (${size_gb}GB) - Removable"
  done < <(lsblk -dplnb -o NAME,SIZE,TYPE,RM | grep "disk")
  
  [[ ${#devices[@]} -gt 0 ]] || err "No removable USB devices found"
  
  echo ""
  local choice
  read -r -p "Select USB device (1-${#devices[@]}): " choice < /dev/tty
  
  [[ -n "$choice" ]] || err "No selection made"
  [[ "$choice" -ge 1 && "$choice" -le ${#devices[@]} ]] || err "Invalid selection (must be 1-${#devices[@]})"
  
  local selected="${devices[$((choice-1))]}"
  local usb_dev="${selected%%:*}"
  
  warn "⚠️  This will ERASE all data on $usb_dev"
  prompt_yn "Continue?" "n" || return 1
  
  msg "Writing ISO to $usb_dev..."
  sudo umount "${usb_dev}"* 2>/dev/null || true
  sudo dd if="$ISO_PATH" of="$usb_dev" bs=4M status=progress oflag=sync conv=fsync || err "Failed to write USB"
  sync
  
  local bootloader
  bootloader=$(ask_bootloader)
  echo "$bootloader" > "$TMP_DIR/bootloader_choice"
  
  msg "✓ Bootable USB created on $usb_dev"
  
  if [[ "$bootloader" == "windows" ]]; then
    msg "To boot: Change BIOS/UEFI boot order to USB"
  fi
}

setup_disk() {
  msg "=== Dedicated Disk Setup ==="
  
  msg "Available disks:"
  local disks=()
  local root_dev
  root_dev=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
  
  while IFS= read -r line; do
    local dev size
    dev=$(echo "$line" | awk '{print $1}')
    size=$(echo "$line" | awk '{print $2}')
    
    [[ "$dev" == "$root_dev" ]] && continue
    
    local size_gb=$((size / 1024 / 1024 / 1024))
    disks+=("$dev:$size_gb")
    echo "  ${#disks[@]}) $dev (${size_gb}GB)"
  done < <(lsblk -dplnb -o NAME,SIZE,TYPE | grep "disk")
  
  [[ ${#disks[@]} -gt 0 ]] || err "No additional disks available"
  
  echo ""
  local choice
  read -r -p "Select disk (1-${#disks[@]}): " choice < /dev/tty
  
  [[ -n "$choice" ]] || err "No selection made"
  [[ "$choice" -ge 1 && "$choice" -le ${#disks[@]} ]] || err "Invalid selection (must be 1-${#disks[@]})"
  
  local selected="${disks[$((choice-1))]}"
  local disk_dev="${selected%%:*}"
  
  warn "⚠️  This will ERASE all data on $disk_dev"
  prompt_yn "Continue?" "n" || return 1
  
  msg "Creating partition on $disk_dev..."
  sudo parted "$disk_dev" --script mklabel gpt
  sudo parted "$disk_dev" --script mkpart primary fat32 1MiB 100%
  sudo parted "$disk_dev" --script set 1 esp on
  
  local partition="${disk_dev}1"
  [[ "$disk_dev" =~ nvme ]] && partition="${disk_dev}p1"
  
  sleep 2
  sudo mkfs.fat -F32 -n WIN11_INSTALL "$partition" || err "Failed to format partition"
  
  local mount_dir
  mount_dir=$(mktemp -d)
  sudo mount "$partition" "$mount_dir"
  
  msg "Copying ISO contents to partition..."
  local iso_mount
  iso_mount=$(mktemp -d)
  sudo mount -o loop "$ISO_PATH" "$iso_mount"
  sudo cp -r "$iso_mount"/* "$mount_dir"/
  sudo umount "$iso_mount"
  rmdir "$iso_mount"
  sudo umount "$mount_dir"
  rmdir "$mount_dir"
  
  local bootloader
  bootloader=$(ask_bootloader)
  echo "$bootloader" > "$TMP_DIR/bootloader_choice"
  
  msg "✓ Windows installer ready on $partition"
  
  if [[ "$bootloader" == "grub" ]]; then
    msg "Creating GRUB entry..."
    sudo bash << 'SUDO_SCRIPT'
cat > /etc/grub.d/40_custom_win11 << 'GRUB'
#!/bin/sh
menuentry "Windows 11 Installer (dedicated disk)" {
    search --no-floppy --set=iso_root --label WIN11_INSTALL
    chainloader ($iso_root)/efi/boot/bootx64.efi
}
GRUB
chmod +x /etc/grub.d/40_custom_win11
SUDO_SCRIPT
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || sudo grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
    msg "✓ GRUB configured"
  fi
}

step_media_setup() {
  msg "Step 3: Installer Media Setup"
  echo ""
  
  cat <<'EOF'
Choose how to set up the Windows installer:

  A) GRUB loopback (simple and fast)
     - ISO stays in /boot
     - Windows installer appears in GRUB menu
     - Can't format disk with /boot during Windows install
     - RECOMMENDED for most users

  B) Dedicated internal disk (more flexible)
     - Use another internal drive
     - Can safely format ALL other disks
     - Choose GRUB or Windows bootloader

  C) Bootable USB (most flexible)
     - Create bootable USB drive
     - Completely independent from Linux
     - Can format ALL internal disks
     - Requires USB drive with sufficient space

EOF
  
  if prompt_yn "Use GRUB loopback? (Option A - recommended)" "y"; then
    echo "grub" > "$TMP_DIR/bootloader_choice"
    return 0
  fi
  
  echo ""
  read -r -p "Select option (B or C): " choice < /dev/tty
  
  case "${choice,,}" in
    b) setup_disk || { warn "Disk setup failed"; return 1; } ;;
    c) setup_usb || { warn "USB setup failed"; return 1; } ;;
    *) err "Invalid option (must be B or C)" ;;
  esac
  
  echo ""
}

#============================================================================
# STEP 4: GRUB ENTRY
#============================================================================

step_grub() {
  local bootloader="grub"
  
  if [[ -f "$TMP_DIR/bootloader_choice" ]]; then
    bootloader=$(cat "$TMP_DIR/bootloader_choice")
  fi
  
  if [[ "$bootloader" != "grub" ]]; then
    msg "Step 4: Bootloader"
    msg "✓ Windows bootloader selected - no GRUB setup needed"
    msg "Change BIOS boot order to boot from the Windows installer media"
    echo ""
    return 0
  fi
  
  msg "Step 4: GRUB Configuration"
  echo ""
  
  prompt_yn "Add GRUB entry for Windows installer?" "y" || return 0
  
  [[ $EUID -eq 0 ]] || { sudo "$0" --grub-only; return 0; }
  
  msg "Copying ISO to /boot..."
  cp "$ISO_PATH" /boot/win11.iso
  
  msg "Creating GRUB entry..."
  cat > /etc/grub.d/40_custom_win11 << 'GRUB'
#!/bin/sh
menuentry "Windows 11 Installer (ISO loop)" {
    set isofile="/boot/win11.iso"
    search --no-floppy --set=iso_root --file $isofile
    loopback loop ($iso_root)$isofile
    chainloader (loop)/efi/boot/bootx64.efi
}
GRUB
  chmod +x /etc/grub.d/40_custom_win11
  
  msg "Regenerating GRUB config..."
  grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
  
  msg "✓ GRUB configured"
  echo ""
}

#============================================================================
# STEP 5: REBOOT
#============================================================================

step_reboot() {
  msg "Step 5: Reboot"
  echo ""
  
  prompt_yn "Reboot now to start Windows installation?" "n" || {
    msg "Setup complete! Reboot manually when ready."
    return 0
  }
  
  msg "Rebooting in 5 seconds..."
  sleep 5
  reboot
}

#============================================================================
# MAIN
#============================================================================

intro() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           Win-Reboot-Project: Windows 11 Setup                ║
║        Inspired by the Tiny11 Project by ntdevlabs            ║
╚═══════════════════════════════════════════════════════════════╝

This will guide you through:
  1. Downloading Windows 11 ISO from UUP dump
  2. Optional Tiny11 trimming to reduce size
  3. Setting up installer media (GRUB/USB/Disk)
  4. Configuring boot
  5. Rebooting to installer

⚠️  WARNING:
  - Secure Boot must be disabled
  - The Windows installer can wipe your disks
  - Test in a VM first if unsure

EOF
  
  prompt_yn "Continue?" "n" || exit 0
  echo ""
}

main() {
  cd "$ROOT_DIR"
  
  if [[ "${1:-}" == "--grub-only" ]]; then
    step_grub
    exit 0
  fi
  
  intro
  check_dependencies
  step_fetch_iso
  step_tiny11
  step_media_setup
  step_grub
  step_reboot
  
  msg "✓ Setup complete!"
}

main "$@"
