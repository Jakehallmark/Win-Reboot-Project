#!/usr/bin/env bash
set -euo pipefail

# Win-Reboot-Project: All-in-One Windows 11 Setup (Linux)
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

INSTALLER_VOL_LABEL="WIN11_INSTALL"
WIM_SPLIT_MB=3800   # keeps each .swm < 4GB for FAT32

mkdir -p "$TMP_DIR" "$OUT_DIR"

#============================================================================
# UTILITY FUNCTIONS
#============================================================================

msg()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err()  { echo "[!] ERROR: $*" >&2; exit 1; }

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

cleanup_mounts=()
cleanup_dirs=()

cleanup() {
  set +e
  # unmount in reverse order
  for ((i=${#cleanup_mounts[@]}-1; i>=0; i--)); do
    local m="${cleanup_mounts[$i]}"
    mountpoint -q "$m" 2>/dev/null && sudo umount "$m" >/dev/null 2>&1
  done
  for ((i=${#cleanup_dirs[@]}-1; i>=0; i--)); do
    local d="${cleanup_dirs[$i]}"
    [[ -d "$d" ]] && rmdir "$d" >/dev/null 2>&1 || true
  done
}
trap cleanup EXIT

mktemp_dir() {
  local d
  d="$(mktemp -d)"
  cleanup_dirs+=("$d")
  echo "$d"
}

mount_iso_ro() {
  local iso="$1"
  local mnt="$2"
  sudo mkdir -p "$mnt"
  sudo mount -o loop,ro "$iso" "$mnt" || err "Failed to mount ISO: $iso"
  cleanup_mounts+=("$mnt")
}

copy_tree() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  # rsync is nicer but not guaranteed installed; cp -a is fine.
  cp -a "$src"/. "$dst"/ || err "Failed to copy tree"
}

human_size() {
  # bytes -> human
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB TB",u," ");
    i=1;
    while (b>=1024 && i<5){b/=1024;i++}
    printf "%.2f %s\n", b, u[i]
  }'
}

#============================================================================
# DRIVER INJECTION
#============================================================================

DRIVERS_DIR="${DRIVERS_DIR:-$ROOT_DIR/drivers}"

require_extractors_for_drivers() {
  # We'll use what exists; require only what we actually need.
  require_cmd find awk sed
}

extract_any_driver_payloads() {
  local in_dir="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"

  shopt -s nullglob
  local f
  for f in "$in_dir"/*; do
    [[ -f "$f" ]] || continue
    case "${f,,}" in
      *.zip)
        command -v unzip >/dev/null 2>&1 || err "Need unzip to extract: $f"
        mkdir -p "$out_dir/$(basename "$f").d"
        unzip -q "$f" -d "$out_dir/$(basename "$f").d" || true
        ;;
      *.cab)
        command -v cabextract >/dev/null 2>&1 || err "Need cabextract to extract: $f"
        mkdir -p "$out_dir/$(basename "$f").d"
        cabextract -q -d "$out_dir/$(basename "$f").d" "$f" || true
        ;;
      *.msi)
        # MSI can contain drivers; extraction is best-effort.
        # 7z usually works if installed.
        if command -v 7z >/dev/null 2>&1; then
          mkdir -p "$out_dir/$(basename "$f").d"
          7z x -y -o"$out_dir/$(basename "$f").d" "$f" >/dev/null 2>&1 || true
        else
          warn "Skipping MSI (no 7z): $f"
        fi
        ;;
      *.exe)
        # EXE extraction is best-effort. Many vendor EXEs are 7z/self-extracting.
        if command -v 7z >/dev/null 2>&1; then
          mkdir -p "$out_dir/$(basename "$f").d"
          7z x -y -o"$out_dir/$(basename "$f").d" "$f" >/dev/null 2>&1 || true
        else
          warn "Skipping EXE (no 7z): $f"
        fi
        ;;
      *.inf)
        # Raw INF dropped directly in drivers dir: just copy its folder later.
        ;;
      *)
        warn "Unknown driver payload type, ignoring: $f"
        ;;
    esac
  done
  shopt -u nullglob
}

collect_inf_roots() {
  # Print unique directories that contain .inf files.
  local search_dir="$1"
  find "$search_dir" -type f -iname "*.inf" -print0 2>/dev/null \
    | xargs -0 -n1 dirname 2>/dev/null \
    | awk '!seen[$0]++'
}

stage_inf_drivers_into_tree() {
  local iso_tree="$1"
  local inf_root_list="$2"

  local dest="$iso_tree/sources/\$OEM\$/\$\$/INFDRIVERS"
  mkdir -p "$dest"

  local n=0
  while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    n=$((n+1))
    mkdir -p "$dest/DriverSet$n"
    # Copy only what's needed for INF install (INF/SYS/CAT/DLL plus supporting files).
    cp -a "$dir"/. "$dest/DriverSet$n"/ 2>/dev/null || true
  done <<< "$inf_root_list"

  msg "Staged $n INF driver set(s) to $dest"
}

patch_boot_wim_to_drvload_oem_drivers() {
  local iso_tree="$1"
  local boot_wim="$iso_tree/sources/boot.wim"
  [[ -f "$boot_wim" ]] || err "boot.wim not found at $boot_wim"

  require_cmd wimlib-imagex

  local mount_dir
  mount_dir="$(mktemp_dir)"

  msg "Patching boot.wim (index 2) to auto-load INF drivers in WinPE..."
  wimlib-imagex mountrw "$boot_wim" 2 "$mount_dir" || err "Failed to mount boot.wim index 2"

  local snc="$mount_dir/Windows/System32/startnet.cmd"
  [[ -f "$snc" ]] || err "startnet.cmd not found inside boot.wim"

  # Back up original once
  [[ -f "$snc.orig" ]] || cp -a "$snc" "$snc.orig" 2>/dev/null || true

  cat > "$snc" <<'CMD'
@echo off
wpeinit

rem --- Auto-load any OEM-staged INF drivers (storage/network/etc) ---
set DRVROOT=X:\sources\$OEM$\$$\INFDRIVERS
if exist "%DRVROOT%" (
  for /r "%DRVROOT%" %%I in (*.inf) do (
    drvload "%%I" >nul 2>&1
  )
)

rem --- Launch Windows Setup ---
X:\sources\setup.exe
CMD

  wimlib-imagex unmount "$mount_dir" --commit || err "Failed to commit boot.wim changes"
}

inject_drivers_into_iso_tree() {
  local iso_tree="$1"
  require_extractors_for_drivers

  if [[ ! -d "$DRIVERS_DIR" ]]; then
    msg "No drivers directory found ($DRIVERS_DIR). Skipping driver injection."
    return 0
  fi

  # Create a temp extraction workspace
  local work="$TMP_DIR/driver_work"
  rm -rf "$work"
  mkdir -p "$work/extracted"

  msg "Collecting driver payloads from: $DRIVERS_DIR"
  extract_any_driver_payloads "$DRIVERS_DIR" "$work/extracted"

  # Search both: original drivers dir + extracted results
  local inf_roots=""
  inf_roots="$(
    {
      collect_inf_roots "$DRIVERS_DIR"
      collect_inf_roots "$work/extracted"
    } | awk '!seen[$0]++'
  )"

  if [[ -z "${inf_roots// }" ]]; then
    warn "No .inf drivers found in $DRIVERS_DIR (or extracted payloads). Skipping."
    return 0
  fi

  stage_inf_drivers_into_tree "$iso_tree" "$inf_roots"
  patch_boot_wim_to_drvload_oem_drivers "$iso_tree"

  msg "✓ Driver injection complete (WinPE will drvload all staged INFs)."
}

confirm_destruction() {
  local dev="$1"
  warn "⚠️  This will ERASE ALL DATA on: $dev"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL "$dev" 2>/dev/null || true
  echo ""
  read -r -p "Type the full device path to confirm ($dev): " typed < /dev/tty
  [[ "$typed" == "$dev" ]] || err "Confirmation did not match. Aborting."
}

#============================================================================
# DEPENDENCY CHECKING
#============================================================================

check_dependencies() {
  msg "Checking dependencies..."

  local missing=()
  local distro=""

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    distro="${ID:-}"
  fi

  # Base required commands
  local required_cmds=(
    curl unzip aria2c
    cabextract
    wimlib-imagex
    chntpw
    xorriso
    parted mkfs.fat
  )

  for cmd in "${required_cmds[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing dependencies: ${missing[*]}"
    if prompt_yn "Auto-install missing dependencies?" "y"; then
      case "$distro" in
        ubuntu|debian|linuxmint|pop)
          sudo apt-get update
          sudo apt-get install -y curl unzip aria2 cabextract wimtools chntpw xorriso parted dosfstools
          ;;
        fedora|rhel|centos)
          sudo dnf install -y curl unzip aria2 cabextract wimlib-utils chntpw xorriso parted dosfstools
          ;;
        arch|manjaro)
          sudo pacman -S --needed --noconfirm curl unzip aria2 cabextract wimlib chntpw xorriso parted dosfstools
          ;;
        *)
          err "Unsupported distro: ${distro:-unknown}. Install manually: ${missing[*]}"
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
# STEP 1: FETCH ISO (via UUP dump ZIP, interactive)
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
Download a Windows 11 build from UUP dump:

  1. Visit: https://uupdump.net
  2. Select a build (e.g., latest)
  3. Choose language + edition(s)
  4. Download the ZIP package

Press Enter when you're ready to select the downloaded ZIP file...
EOF

  read -r -p "" < /dev/tty
  echo ""

  local zip_file=""

  if command -v zenity &>/dev/null; then
    zip_file=$(zenity --file-selection --title="Select UUP dump ZIP file" --file-filter="ZIP files (*.zip) | *.zip" 2>/dev/null || true)
  elif command -v kdialog &>/dev/null; then
    zip_file=$(kdialog --getopenfilename ~ "*.zip|ZIP files (*.zip)" 2>/dev/null || true)
  else
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
  [[ -n "${built_iso:-}" ]] || err "No ISO produced"

  mv "$built_iso" "$ISO_PATH"
  msg "✓ ISO created: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 2: "Tiny11 trimming" (file-based, best-effort)
#============================================================================
# Reality check:
# - Proper Windows image servicing (DISM) isn't available here.
# - This step only removes known ISO-level and offline-image files/directories.
# - It may reduce size, but it is not guaranteed "clean" like real servicing.

load_preset_lines() {
  local preset="$1"
  local preset_file="$ROOT_DIR/data/removal-presets/${preset}.txt"

  if [[ ! -f "$preset_file" ]]; then
    preset_file="$TMP_DIR/removal-presets/${preset}.txt"
    if [[ ! -f "$preset_file" ]]; then
      mkdir -p "$TMP_DIR/removal-presets"
      local preset_url="https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/data/removal-presets/${preset}.txt"
      msg "Downloading preset: $preset"
      curl -fsSL "$preset_url" -o "$preset_file" 2>/dev/null || return 1
    fi
  fi

  [[ -f "$preset_file" ]] || return 1
  cat "$preset_file"
}

safe_remove_matches() {
  local root="$1"
  local pattern="$2"

  # Guardrails: refuse wild patterns that look like a disaster.
  [[ "$pattern" == "/"* ]] && return 0
  [[ "$pattern" == "*" ]] && return 0
  [[ -z "$pattern" ]] && return 0

  # Best-effort: remove directories matching pattern (case-insensitive)
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    rm -rf "$d" 2>/dev/null || true
  done < <(find "$root" -type d -iname "*$pattern*" 2>/dev/null)
}

convert_esd_to_wim_if_needed() {
  local sources_dir="$1/sources"
  local esd="$sources_dir/install.esd"
  local wim="$sources_dir/install.wim"

  if [[ -f "$esd" ]]; then
    msg "Converting install.esd -> install.wim..."
    wimlib-imagex export "$esd" all "$wim" --compress=LZX --check || err "ESD conversion failed"
    rm -f "$esd"
  fi

  [[ -f "$wim" ]] || err "No install.wim found after conversion step"
}

apply_preset_to_tree() {
  local iso_tree="$1"
  local preset="$2"

  msg "Applying preset: $preset (best-effort file removal)"
  local lines
  if ! lines="$(load_preset_lines "$preset")"; then
    warn "Failed to load preset: $preset. Skipping removals."
    return 0
  fi

  # ISO-level removals
  while IFS= read -r item; do
    [[ -z "$item" || "$item" =~ ^# ]] && continue

    # Allow two styles:
    # 1) "PATH:relative/path" for explicit paths in ISO tree
    # 2) plain token -> directory name match removal inside offline image mount (if used)
    if [[ "$item" == PATH:* ]]; then
      local rel="${item#PATH:}"
      local target="$iso_tree/$rel"
      if [[ -e "$target" ]]; then
        rm -rf "$target" 2>/dev/null || true
      fi
    fi
  done <<< "$lines"
}

offline_image_best_effort_prune() {
  local iso_tree="$1"
  local preset="$2"

  local wim="$iso_tree/sources/install.wim"
  [[ -f "$wim" ]] || return 0

  local image_count
  image_count="$(wimlib-imagex info "$wim" | awk -F': ' '/Image Count:/ {print $2}' | tr -d '\r')"
  [[ -n "${image_count:-}" ]] || err "Failed to read WIM image count"

  msg "Offline image mount: processing $image_count image(s) (best-effort)"
  local mount_dir
  mount_dir="$(mktemp_dir)"

  local lines
  lines="$(load_preset_lines "$preset" 2>/dev/null || true)"

  for ((img=1; img<=image_count; img++)); do
    msg "Mounting image $img/$image_count..."
    wimlib-imagex mountrw "$wim" "$img" "$mount_dir" || err "Failed to mount image $img"

    # Token-based removals (directory-name matches only)
    if [[ -n "$lines" ]]; then
      while IFS= read -r item; do
        [[ -z "$item" || "$item" =~ ^# ]] && continue
        [[ "$item" == PATH:* ]] && continue
        safe_remove_matches "$mount_dir" "$item"
      done <<< "$lines"
    fi

    msg "Unmounting (commit) image $img..."
    wimlib-imagex unmount "$mount_dir" --commit || err "Failed to unmount image $img"
    sleep 1
  done
}

rebuild_iso_from_tree() {
  local iso_tree="$1"
  local out_iso="$2"
  local volid="$3"

  # Use xorriso in mkisofs emulation.
  xorriso -as mkisofs \
    -iso-level 3 \
    -full-iso9660-filenames \
    -volid "$volid" \
    -eltorito-boot boot/etfsboot.com \
    -no-emul-boot \
    -boot-load-size 8 \
    -eltorito-alt-boot \
    -e efi/microsoft/boot/efisys.bin \
    -no-emul-boot \
    -o "$out_iso" \
    "$iso_tree" >/dev/null 2>&1 || err "Failed to create ISO"
}

step_tiny11() {
  msg "Step 2: Trimming (optional, best-effort)"
  echo ""

  prompt_yn "Apply trimming preset to reduce ISO size? (best-effort)" "y" || {
    msg "Skipping trimming"
    return 0
  }

  echo "Available presets:"
  echo "  minimal    - light removal"
  echo "  lite       - more removal"
  echo "  aggressive - highest removal risk"
  echo "  vanilla    - no changes"
  echo ""

  local preset
  read -r -p "Preset [minimal/lite/aggressive/vanilla]: " preset < /dev/tty
  preset="${preset:-minimal}"

  if [[ "$preset" == "vanilla" ]]; then
    msg "Skipping trimming (vanilla)"
    return 0
  fi

  msg "Preparing ISO working tree..."
  local work_dir="$TMP_DIR/trim"
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  local iso_ro="$work_dir/iso_ro"
  local iso_tree="$work_dir/iso_tree"
  mkdir -p "$iso_ro" "$iso_tree"

  # Always mount ISO read-only to iso_ro, then copy to writable iso_tree.
  mount_iso_ro "$ISO_PATH" "$iso_ro"
  msg "Copying ISO contents to writable tree..."
  copy_tree "$iso_ro" "$iso_tree"

  # Convert ESD to WIM if needed, then optional offline mount prune.
  if [[ -f "$iso_tree/sources/install.esd" ]]; then
    convert_esd_to_wim_if_needed "$iso_tree"
  fi

  apply_preset_to_tree "$iso_tree" "$preset"
  offline_image_best_effort_prune "$iso_tree" "$preset"

  msg "Rebuilding ISO from working tree..."
  local tiny_iso="$OUT_DIR/win11-trimmed.iso"
  rebuild_iso_from_tree "$iso_tree" "$tiny_iso" "WIN11_TRIM"

  mv "$tiny_iso" "$ISO_PATH"
  msg "✓ Trimmed ISO ready: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 3: MEDIA SETUP (UEFI-focused, fixes >4GB WIM for FAT32)
#============================================================================

ensure_wim_split_for_fat32_tree() {
  local tree="$1"
  local wim="$tree/sources/install.wim"

  [[ -f "$wim" ]] || return 0

  local size_bytes
  size_bytes="$(stat -c%s "$wim" 2>/dev/null || echo 0)"
  if [[ "$size_bytes" -le 4294967295 ]]; then
    return 0
  fi

  msg "install.wim is larger than 4GB ($(human_size "$size_bytes")). Splitting to SWM for FAT32..."
  local swm="$tree/sources/install.swm"
  wimlib-imagex split "$wim" "$swm" "$WIM_SPLIT_MB" || err "Failed to split WIM"
  rm -f "$wim"
  msg "✓ WIM split complete (install.swm/install2.swm...)"
}

prepare_iso_tree_for_copy_media() {
  local iso="$1"
  local out_tree="$2"

  rm -rf "$out_tree"
  mkdir -p "$out_tree"

  local ro
  ro="$(mktemp_dir)"
  mount_iso_ro "$iso" "$ro"
  copy_tree "$ro" "$out_tree"

  # If ESD exists, convert to WIM first (so we can split if needed).
  if [[ -f "$out_tree/sources/install.esd" ]]; then
    convert_esd_to_wim_if_needed "$out_tree"
  fi

  ensure_wim_split_for_fat32_tree "$out_tree"
  
  # Inject drivers if available
  inject_drivers_into_iso_tree "$out_tree"
}

ask_bootloader() {
  echo ""
  msg "╔════════════════════════════════════════╗"
  msg "║      Choose How to Boot Windows        ║"
  msg "╚════════════════════════════════════════╝"
  echo ""
  echo "  1) GRUB (adds menu entry where possible)"
  echo "  2) Windows/UEFI boot (no GRUB changes)"
  echo ""
  local answer
  read -r -p "Select bootloader (1 or 2): " answer < /dev/tty

  case "$answer" in
    2) echo "windows" ;;
    1) echo "grub" ;;
    *) warn "Invalid selection. Using GRUB (default)."; echo "grub" ;;
  esac
}

format_and_copy_to_fat32_partition() {
  local part="$1"
  local src_tree="$2"

  msg "Formatting $part as FAT32..."
  sudo mkfs.fat -F32 -n "$INSTALLER_VOL_LABEL" "$part" >/dev/null || err "Failed to format $part"

  local mnt
  mnt="$(mktemp_dir)"
  sudo mkdir -p "$mnt"
  sudo mount "$part" "$mnt" || err "Failed to mount $part"
  cleanup_mounts+=("$mnt")

  msg "Copying installer files (UEFI)..."
  sudo cp -a "$src_tree"/. "$mnt"/ || err "Copy failed"
  sync
}

setup_usb() {
  msg "=== Bootable USB Setup (UEFI) ==="
  echo ""

  msg "Detecting removable devices..."
  local devices=()
  while IFS= read -r line; do
    local dev size rm type
    dev="$(awk '{print $1}' <<<"$line")"
    size="$(awk '{print $2}' <<<"$line")"
    type="$(awk '{print $3}' <<<"$line")"
    rm="$(awk '{print $4}' <<<"$line")"
    [[ "$type" == "disk" && "$rm" == "1" ]] || continue
    local size_gb=$((size / 1024 / 1024 / 1024))
    devices+=("$dev:$size_gb")
    echo "  ${#devices[@]}) $dev (${size_gb}GB) - Removable"
  done < <(lsblk -dplnb -o NAME,SIZE,TYPE,RM | grep -E "disk")

  [[ ${#devices[@]} -gt 0 ]] || err "No removable USB devices found"

  echo ""
  local choice
  read -r -p "Select USB device (1-${#devices[@]}): " choice < /dev/tty
  [[ -n "${choice:-}" ]] || err "No selection made"
  [[ "$choice" -ge 1 && "$choice" -le ${#devices[@]} ]] || err "Invalid selection"

  local selected="${devices[$((choice-1))]}"
  local usb_dev="${selected%%:*}"

  confirm_destruction "$usb_dev"
  prompt_yn "Continue?" "n" || return 1

  msg "Preparing ISO tree for copy-based media (handles >4GB WIM)..."
  local iso_tree="$TMP_DIR/media_iso_tree_usb"
  prepare_iso_tree_for_copy_media "$ISO_PATH" "$iso_tree"

  msg "Partitioning USB (GPT + single FAT32 ESP)..."
  sudo umount "${usb_dev}"* 2>/dev/null || true
  sudo parted -s "$usb_dev" mklabel gpt
  sudo parted -s "$usb_dev" mkpart primary fat32 1MiB 100%
  sudo parted -s "$usb_dev" set 1 esp on

  local part="${usb_dev}1"
  [[ "$usb_dev" =~ nvme ]] && part="${usb_dev}p1"
  sleep 2

  format_and_copy_to_fat32_partition "$part" "$iso_tree"

  local bootloader
  bootloader="$(ask_bootloader)"
  echo "$bootloader" > "$TMP_DIR/bootloader_choice"

  msg "✓ Bootable USB created on $usb_dev (UEFI)"
  if [[ "$bootloader" == "windows" ]]; then
    msg "Boot via UEFI boot menu / BIOS boot order"
  fi
}

setup_disk() {
  msg "=== Dedicated Disk Setup (UEFI) ==="
  echo ""

  msg "Available disks:"
  local disks=()
  local root_dev
  root_dev="$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')"

  while IFS= read -r line; do
    local dev size type
    dev="$(awk '{print $1}' <<<"$line")"
    size="$(awk '{print $2}' <<<"$line")"
    type="$(awk '{print $3}' <<<"$line")"
    [[ "$type" == "disk" ]] || continue
    [[ "$dev" == "$root_dev" ]] && continue
    local size_gb=$((size / 1024 / 1024 / 1024))
    disks+=("$dev:$size_gb")
    echo "  ${#disks[@]}) $dev (${size_gb}GB)"
  done < <(lsblk -dplnb -o NAME,SIZE,TYPE | grep -E "disk")

  [[ ${#disks[@]} -gt 0 ]] || err "No additional disks available"

  echo ""
  local choice
  read -r -p "Select disk (1-${#disks[@]}): " choice < /dev/tty
  [[ -n "${choice:-}" ]] || err "No selection made"
  [[ "$choice" -ge 1 && "$choice" -le ${#disks[@]} ]] || err "Invalid selection"

  local selected="${disks[$((choice-1))]}"
  local disk_dev="${selected%%:*}"

  confirm_destruction "$disk_dev"
  prompt_yn "Continue?" "n" || return 1

  msg "Preparing ISO tree for copy-based media (handles >4GB WIM)..."
  local iso_tree="$TMP_DIR/media_iso_tree_disk"
  prepare_iso_tree_for_copy_media "$ISO_PATH" "$iso_tree"

  msg "Partitioning disk (GPT + single FAT32 ESP)..."
  sudo umount "${disk_dev}"* 2>/dev/null || true
  sudo parted -s "$disk_dev" mklabel gpt
  sudo parted -s "$disk_dev" mkpart primary fat32 1MiB 100%
  sudo parted -s "$disk_dev" set 1 esp on

  local part="${disk_dev}1"
  [[ "$disk_dev" =~ nvme ]] && part="${disk_dev}p1"
  sleep 2

  format_and_copy_to_fat32_partition "$part" "$iso_tree"

  local bootloader
  bootloader="$(ask_bootloader)"
  echo "$bootloader" > "$TMP_DIR/bootloader_choice"

  msg "✓ Windows installer ready on $part (UEFI)"

  if [[ "$bootloader" == "grub" ]]; then
    msg "Creating GRUB entry (chainload USB/disk ESP)..."
    sudo bash <<'SUDO_SCRIPT'
set -euo pipefail
cat > /etc/grub.d/40_custom_win11 <<'GRUB'
#!/bin/sh
menuentry "Windows 11 Installer (UEFI media)" {
    search --no-floppy --set=esp --label WIN11_INSTALL
    chainloader ($esp)/efi/boot/bootx64.efi
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

  A) GRUB ISO loopback (EXPERIMENTAL; many systems won't boot Win11 ISO this way)
  B) Dedicated internal disk (UEFI copy-based, FAT32, auto-splits install.wim if needed)
  C) Bootable USB (UEFI copy-based, FAT32, auto-splits install.wim if needed)

EOF

  if prompt_yn "Use GRUB ISO loopback? (Option A - experimental)" "n"; then
    echo "grub_loop" > "$TMP_DIR/media_choice"
    echo "grub" > "$TMP_DIR/bootloader_choice"
    return 0
  fi

  echo ""
  local choice
  read -r -p "Select option (B or C): " choice < /dev/tty

  case "${choice,,}" in
    b) setup_disk || { warn "Disk setup failed"; return 1; } ;;
    c) setup_usb  || { warn "USB setup failed"; return 1; } ;;
    *) err "Invalid option (must be B or C)" ;;
  esac

  echo ""
}

#============================================================================
# STEP 4: GRUB ENTRY
#============================================================================

step_grub() {
  local bootloader="grub"
  local media_choice=""

  [[ -f "$TMP_DIR/bootloader_choice" ]] && bootloader="$(cat "$TMP_DIR/bootloader_choice")"
  [[ -f "$TMP_DIR/media_choice" ]] && media_choice="$(cat "$TMP_DIR/media_choice")"

  msg "Step 4: Bootloader"
  echo ""

  if [[ "$bootloader" != "grub" ]]; then
    msg "✓ Windows/UEFI boot selected - no GRUB setup needed"
    msg "Use UEFI boot menu / BIOS boot order to boot installer media"
    echo ""
    return 0
  fi

  if [[ "$media_choice" == "grub_loop" ]]; then
    warn "GRUB ISO loopback is experimental for Windows 11 installers."
    prompt_yn "Proceed anyway and add GRUB ISO-loop entry?" "n" || return 0

    [[ $EUID -eq 0 ]] || { sudo "$0" --grub-only; return 0; }

    msg "Copying ISO to /boot..."
    sudo cp "$ISO_PATH" /boot/win11.iso

    msg "Creating GRUB entry..."
    sudo tee /etc/grub.d/40_custom_win11 >/dev/null <<'GRUB'
#!/bin/sh
menuentry "Windows 11 Installer (ISO loopback - experimental)" {
    set isofile="/boot/win11.iso"
    search --no-floppy --set=iso_root --file $isofile
    loopback loop ($iso_root)$isofile
    chainloader (loop)/efi/boot/bootx64.efi
}
GRUB
    sudo chmod +x /etc/grub.d/40_custom_win11

    msg "Regenerating GRUB config..."
    sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || sudo grub2-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

    msg "✓ GRUB configured (experimental loopback)"
    echo ""
    return 0
  fi

  msg "✓ GRUB entry (chainload media) was configured during disk/USB setup (if you selected it)."
  echo ""
}

#============================================================================
# STEP 5: REBOOT
#============================================================================

step_reboot() {
  msg "Step 5: Reboot"
  echo ""

  prompt_yn "Reboot now to start Windows installation?" "n" || {
    msg "Setup complete. Reboot manually when ready."
    return 0
  }

  msg "Rebooting in 5 seconds..."
  sleep 5
  sudo reboot
}

#============================================================================
# MAIN
#============================================================================

intro() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           Win-Reboot-Project: Windows 11 Setup                ║
╚═══════════════════════════════════════════════════════════════╝

Flow:
  1. Build ISO from UUP dump
  2. Optional trimming (best-effort)
  3. Create installer media (UEFI copy-based recommended)
  4. Optional GRUB boot
  5. Reboot

Notes:
  - Secure Boot must be disabled for some setups.
  - Copy-based media auto-splits install.wim >4GB for FAT32.
  - GRUB ISO loopback is experimental.

EOF

  prompt_yn "Continue?" "n" || exit 0
  echo ""
}

main() {
  cd "$ROOT_DIR"

  if [[ "${1:-}" == "--grub-only" ]]; then
    # only used for experimental loopback flow
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