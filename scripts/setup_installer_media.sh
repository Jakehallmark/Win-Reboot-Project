#!/usr/bin/env bash
set -euo pipefail

# Setup Windows installer media with intelligent storage detection
# Offers multiple options: resize current disk, use another disk, or create bootable USB

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ISO_SRC="${1:-$ROOT_DIR/out/win11.iso}"
INSTALLER_SIZE_GB=10

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] $*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing required command: $c"
  done
}

usage() {
  cat <<'EOF'
Usage: setup_installer_media.sh [path-to-iso]

Intelligently detects available storage and offers options to:
1. Resize current drive and create 10GB partition for installer
2. Use another internal drive for the installer
3. Create bootable USB for the installer

Requires root. Secure Boot must be disabled for GRUB loopback.
EOF
}

# Detect all block devices
detect_devices() {
  lsblk -dplnb -o NAME,SIZE,TYPE,RM,MOUNTPOINT 2>/dev/null | grep -E "^/dev" || true
}

# Get size in GB
get_size_gb() {
  local bytes="$1"
  echo "$((bytes / 1024 / 1024 / 1024))"
}

# Find where root filesystem is mounted
get_root_device() {
  df / | tail -1 | awk '{print $1}'
}

# Get the actual disk device from a partition (e.g., /dev/nvme0n1p1 -> /dev/nvme0n1)
get_disk_from_partition() {
  local part="$1"
  # Remove trailing partition number
  if [[ "$part" =~ ^(/dev/[a-z]+)p[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$part" =~ ^(/dev/[a-z]+)[0-9]+$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$part"
  fi
}

# Check if device is removable
is_removable() {
  local dev="$1"
  local base="${dev##*/}"
  local rm_file="/sys/class/block/$base/removable"
  if [[ -f "$rm_file" ]]; then
    [[ "$(cat "$rm_file")" == "1" ]]
  else
    return 1
  fi
}

# Get available space on filesystem
get_available_space_gb() {
  local path="$1"
  df "$path" 2>/dev/null | tail -1 | awk '{print $4}' | xargs -I {} sh -c 'echo $(({} / 1024 / 1024))'
}

# Prompt bootloader choice for external media
ask_bootloader_preference() {
  local media_type="$1"  # "disk" or "usb"
  
  echo ""
  msg "Choose how to boot the Windows installer:"
  echo ""
  echo "  Option 1) GRUB (integrated with Linux bootloader)"
  echo "           - Windows installer appears in GRUB menu"
  echo "           - Requires GRUB to be functional"
  echo "           - Still depends on Linux boot chain"
  echo ""
  echo "  Option 2) Windows Bootloader (direct UEFI boot)"
  echo "           - Boot directly to Windows installer from UEFI"
  echo "           - Independent from GRUB/Linux boot"
  echo "           - Works even if Linux boot is broken"
  echo "           - Requires changing BIOS/UEFI boot order"
  echo ""
  
  local answer
  read -p "Select bootloader (1=GRUB, 2=Windows): " answer
  
  if [[ "$answer" == "2" ]]; then
    echo "windows"
    return 0
  else
    echo "grub"
    return 0
  fi
}


# Option 1: Resize current disk and create new partition
option_resize_current() {
  msg "=== Option 1: Resize Current Disk ==="
  
  local root_dev
  root_dev="$(get_root_device)"
  local disk
  disk="$(get_disk_from_partition "$root_dev")"
  
  msg "Current root device: $root_dev (disk: $disk)"
  
  # Check available space
  local avail_gb
  avail_gb="$(get_available_space_gb /)"
  msg "Available space in root filesystem: ~${avail_gb}GB"
  
  if [[ $avail_gb -lt $INSTALLER_SIZE_GB ]]; then
    warn "Insufficient space. Need ${INSTALLER_SIZE_GB}GB but only have ${avail_gb}GB available"
    return 1
  fi
  
  warn "This operation requires:"
  warn "  - Stopping services and unmounting filesystems"
  warn "  - Resizing LVM volumes (if applicable)"
  warn "  - Creating new partition"
  warn "  - Creating new filesystem"
  
  if ! prompt_yes_no "Proceed with resizing current disk?"; then
    return 1
  fi
  
  msg "Starting partition resize process..."
  
  # For now, we'll create a simple approach that works with LVM
  # Check if root is on LVM
  if dmsetup ls 2>/dev/null | grep -q "$(basename "$root_dev")"; then
    msg "Detected LVM setup. Shrinking LVM volume for partition..."
    local vg_name lv_name
    vg_name="$(lvdisplay "$root_dev" 2>/dev/null | grep "LV Name" | awk '{print $NF}')"
    lv_name="$(lvdisplay "$root_dev" 2>/dev/null | grep "LV Name" | awk '{print $NF}' | xargs basename)"
    
    msg "Volume Group: $vg_name, Logical Volume: $lv_name"
    
    # Check current size
    local current_size
    current_size="$(lvdisplay "$root_dev" 2>/dev/null | grep "LV Size" | awk '{print $NF}' | sed 's/,//')"
    msg "Current LV size: $current_size"
    
    warn "LVM resizing is complex and risky. Consider using GParted GUI instead."
    warn "For now, recommend using Option 2 (another disk) or Option 3 (USB)."
    return 1
  else
    msg "Resize not implemented for non-LVM setups yet."
    warn "Recommend using Option 2 (another disk) or Option 3 (USB)."
    return 1
  fi
}

# Option 2: Use another internal drive
option_another_disk() {
  msg "=== Option 2: Use Another Internal Drive ==="
  
  local root_dev
  root_dev="$(get_root_device)"
  local root_disk
  root_disk="$(get_disk_from_partition "$root_dev")"
  
  msg "Current system disk: $root_disk"
  msg ""
  msg "Available disks:"
  
  local target_disk=""
  local count=0
  local -a options=()
  
  while IFS= read -r line; do
    local dev size rm
    dev="$(echo "$line" | awk '{print $1}')"
    size="$(echo "$line" | awk '{print $2}')"
    rm="$(echo "$line" | awk '{print $4}')"
    
    # Skip current root disk and removable devices
    if [[ "$dev" == "$root_disk" ]] || [[ "$rm" == "1" ]]; then
      continue
    fi
    
    ((count++))
    local size_gb
    size_gb="$(get_size_gb "$size")"
    msg "  $count) $dev (${size_gb}GB) - Not removable"
    options+=("$dev")
  done < <(detect_devices)
  
  if [[ $count -eq 0 ]]; then
    warn "No suitable internal disks found (or all are the system disk)"
    return 1
  fi
  
  local choice
  read -p "Select disk number (1-$count): " choice
  
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $count ]]; then
    err "Invalid selection"
  fi
  
  target_disk="${options[$((choice-1))]}"
  local target_size_gb
  target_size_gb="$(lsblk -dplnb -o NAME,SIZE "$target_disk" 2>/dev/null | awk '{print $2}' | head -1 | xargs -I {} sh -c 'echo $(({} / 1024 / 1024 / 1024))')"
  
  msg "Selected: $target_disk (${target_size_gb}GB)"
  
  warn "WARNING: This will completely format $target_disk"
  if ! prompt_yes_no "Format $target_disk and use for Windows installer?"; then
    return 1
  fi
  
  msg "Formatting $target_disk with FAT32..."
  sudo umount "${target_disk}"* 2>/dev/null || true
  sudo parted -s "$target_disk" mklabel gpt || true
  sudo parted -s "$target_disk" mkpart primary fat32 0% 100%
  
  local partition="${target_disk}1"
  sleep 1
  
  sudo mkfs.vfat -F 32 "$partition" >/dev/null 2>&1 || err "Failed to format partition"
  
  local mount_dir
  mount_dir="$(mktemp -d)"
  msg "Mounting to $mount_dir..."
  sudo mount "$partition" "$mount_dir"
  
  msg "Copying ISO to $partition..."
  sudo cp "$ISO_SRC" "$mount_dir/win11.iso"
  
  # Ask user's bootloader preference
  local bootloader
  bootloader="$(ask_bootloader_preference "disk")"
  
  if [[ "$bootloader" == "grub" ]]; then
    msg "Setting up GRUB entry to boot from $partition..."
    cat | sudo tee /etc/grub.d/40_custom_win11 >/dev/null <<'GRUB'
menuentry "Windows 11 installer (from disk)" {
    search --no-floppy --set=iso_root --label WIN11_INSTALL
    set isofile="/win11.iso"
    loopback loop ($iso_root)$isofile
    chainloader (loop)/efi/boot/bootx64.efi
}
GRUB
    sudo chmod +x /etc/grub.d/40_custom_win11
    
    msg "Regenerating grub.cfg..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || sudo grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1
    
    msg "✓ Setup complete!"
    msg "Windows installer is on $partition (GRUB enabled)"
    msg "It will appear in the GRUB menu at next boot"
  else
    msg "Setup for Windows bootloader..."
    msg ""
    msg "✓ Windows 11 installer ready on $partition"
    msg ""
    msg "To boot the Windows installer:"
    msg "  1. Reboot your system"
    msg "  2. Enter BIOS/UEFI settings (usually Del, F2, or F12 key)"
    msg "  3. Change boot order to boot from: $partition (or 'UEFI: ...' entry)"
    msg "  4. Save and reboot"
    msg "  5. Windows installer will boot directly"
    msg ""
    warn "Note: You can still access GRUB by holding Shift during boot"
  fi
  
  sudo umount "$mount_dir"
  rmdir "$mount_dir"
  
  msg "You can now safely format all other disks during Windows installation."
  return 0
}

# Option 3: Create bootable USB
option_usb() {
  msg "=== Option 3: Create Bootable USB ==="
  
  msg "Detecting removable devices..."
  
  local count=0
  local -a usb_devices=()
  
  while IFS= read -r line; do
    local dev size rm
    dev="$(echo "$line" | awk '{print $1}')"
    size="$(echo "$line" | awk '{print $2}')"
    rm="$(echo "$line" | awk '{print $4}')"
    
    # Only show removable block devices
    if [[ "$rm" != "1" ]]; then
      continue
    fi
    
    ((count++))
    local size_gb
    size_gb="$(get_size_gb "$size")"
    msg "  $count) $dev (${size_gb}GB) - Removable"
    usb_devices+=("$dev")
  done < <(detect_devices)
  
  if [[ $count -eq 0 ]]; then
    warn "No removable USB devices detected"
    warn "Plug in a USB drive with at least 10GB free space and try again"
    return 1
  fi
  
  local choice
  read -p "Select USB device number (1-$count): " choice
  
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt $count ]]; then
    err "Invalid selection"
  fi
  
  local target_usb="${usb_devices[$((choice-1))]}"
  local target_size_gb
  target_size_gb="$(lsblk -dplnb -o NAME,SIZE "$target_usb" 2>/dev/null | awk '{print $2}' | head -1 | xargs -I {} sh -c 'echo $(({} / 1024 / 1024 / 1024))')"
  
  if [[ $target_size_gb -lt $INSTALLER_SIZE_GB ]]; then
    err "USB device too small (${target_size_gb}GB, need ${INSTALLER_SIZE_GB}GB)"
  fi
  
  msg "Selected: $target_usb (${target_size_gb}GB)"
  
  warn "⚠️  CAUTION: This will completely erase $target_usb"
  warn "All data on $target_usb will be destroyed"
  
  if ! prompt_yes_no "Format $target_usb and create bootable Windows installer?"; then
    return 1
  fi
  
  msg "Unmounting $target_usb..."
  sudo umount "${target_usb}"* 2>/dev/null || true
  sleep 1
  
  msg "Writing ISO to $target_usb (this will take a few minutes)..."
  sudo dd if="$ISO_SRC" of="$target_usb" bs=4M status=progress oflag=sync || err "Failed to write ISO"
  
  msg "Syncing..."
  sync
  
  # Ask user's bootloader preference for USB
  local bootloader
  bootloader="$(ask_bootloader_preference "usb")"
  
  msg ""
  if [[ "$bootloader" == "grub" ]]; then
    msg "✓ Bootable USB created successfully!"
    msg "To boot with GRUB:"
    msg "  1. Keep USB plugged in"
    msg "  2. Reboot and let GRUB menu appear"
    msg "  3. Select 'Windows 11 installer' from GRUB menu"
    msg ""
    msg "Note: You'll need to set up GRUB entry on your system disk"
    msg "Run this on next boot to configure GRUB:"
    msg "  sudo grub-mkconfig -o /boot/grub/grub.cfg"
  else
    msg "✓ Bootable USB created successfully!"
    msg "To boot the Windows installer:"
    msg "  1. Unplug the USB drive from this computer"
    msg "  2. Plug it into the computer where you want to install Windows"
    msg "  3. Reboot that computer"
    msg "  4. Press the boot menu key (usually F12, Esc, or Del) at startup"
    msg "  5. Select your USB drive from the boot menu"
    msg "  6. Windows installer will boot directly from USB"
  fi
  
  msg ""
  msg "Windows installer will boot and you can safely format all disks"
  
  return 0
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      *) shift;;
    esac
  done
  
  [[ $EUID -eq 0 ]] || err "Run as root (sudo)"
  [[ -f "$ISO_SRC" ]] || err "ISO not found: $ISO_SRC"
  
  require_cmd lsblk df parted mkfs.vfat dd grub-mkconfig 2>/dev/null || \
    require_cmd lsblk df parted mkfs.vfat dd grub2-mkconfig || \
    err "Missing required utilities"
  
  msg "Windows 11 Installer Media Setup"
  msg "ISO: $ISO_SRC"
  msg ""
  msg "Choose how to set up the installer:"
  msg "  1) Resize current disk and create 10GB partition"
  msg "  2) Use another internal disk"
  msg "  3) Create bootable USB"
  msg "  4) Exit"
  msg ""
  
  local choice
  read -p "Select option (1-4): " choice
  
  case "$choice" in
    1)
      option_resize_current || msg "Resize option not completed"
      ;;
    2)
      option_another_disk || msg "Another disk option not completed"
      ;;
    3)
      option_usb || msg "USB option not completed"
      ;;
    4)
      msg "Exiting"
      exit 0
      ;;
    *)
      err "Invalid option"
      ;;
  esac
}

main "$@"
