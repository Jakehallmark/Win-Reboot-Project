#!/usr/bin/env bash
set -euo pipefail

# Apply Tiny11-style trimming to a Windows 11 ISO using wimlib.
# Rebuilds a new ISO with modified install.wim.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib_error.sh" 2>/dev/null || {
  echo "[!] Error: Cannot load error handling library" >&2
  echo "[!] Make sure lib_error.sh exists in $SCRIPT_DIR" >&2
  exit 1
}

# Set defaults; parse_args assigns ISO_IN from CLI
ISO_IN=""
PRESET="minimal" # minimal|lite|vanilla
IMAGE_INDEX=1
OUT_ISO="${OUT_ISO:-$ROOT_DIR/out/win11-tiny.iso}"
TMP_ROOT="${TMP_DIR:-$ROOT_DIR/tmp}"
CUSTOM_LIST=""
SKIP_REG=0

usage() {
  cat <<'EOF'
Usage: tiny11.sh <path-to-win11.iso> [--preset minimal|lite|vanilla] [--image-index N]
                 [--custom-list path] [--skip-reg]
Defaults: preset=minimal, image-index=1, output=out/win11-tiny.iso
Presets live in data/removal-presets/. "vanilla" keeps the image untouched.
EOF
}

msg() { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err() { echo "[!] $*" >&2; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --preset) PRESET="$2"; shift 2;;
      --image-index) IMAGE_INDEX="$2"; shift 2;;
      --custom-list) CUSTOM_LIST="$2"; shift 2;;
      --skip-reg) SKIP_REG=1; shift;;
      *)
        if [[ -z "$ISO_IN" ]]; then
          ISO_IN="$1"; shift
        else
          err "Unknown arg: $1"
        fi
        ;;
    esac
  done
  
  if [[ -z "$ISO_IN" ]]; then
    usage; err "ISO path is required"
  fi
}

load_list() {
  local list_path="$1"
  [[ -f "$list_path" ]] || err "Removal list not found: $list_path"
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    if [[ "$line" =~ ^@include[[:space:]]+(.+) ]]; then
      load_list "$ROOT_DIR/data/removal-presets/${BASH_REMATCH[1]}.txt"
    else
      echo "$line"
    fi
  done <"$list_path"
}

build_removal_list() {
  local list_file
  case "$PRESET" in
    vanilla) return 0;;
    minimal|lite|aggressive) list_file="$ROOT_DIR/data/removal-presets/${PRESET}.txt";;
    *) fatal_error "Unknown preset: $PRESET" 1 "Valid presets: minimal, lite, aggressive, vanilla";;
  esac
  
  if [[ ! -f "$list_file" ]]; then
    fatal_error "Preset file not found: $list_file" 40 \
      "Preset file is missing from data/removal-presets/"
  fi
  
  load_list "$list_file"
  if [[ -n "$CUSTOM_LIST" ]]; then
    if [[ ! -f "$CUSTOM_LIST" ]]; then
      fatal_error "Custom list file not found: $CUSTOM_LIST" 1 \
        "Specified custom removal list does not exist"
    fi
    load_list "$CUSTOM_LIST"
  fi
}

ensure_tools() {
  require_commands 7z wimlib-imagex
  
  if command -v xorriso >/dev/null 2>&1; then
    ISO_TOOL="xorriso"
  elif command -v genisoimage >/dev/null 2>&1; then
    ISO_TOOL="genisoimage"
  else
    fatal_error "Need xorriso or genisoimage to rebuild ISO" 10 \
      "Install one of these packages: xorriso or genisoimage"
  fi
  
  if ! command -v hivexregedit >/dev/null 2>&1; then
    warn "hivexregedit not found; registry bypass tweaks will be skipped"
    warn "Install libhivex-bin (Debian/Ubuntu) or hivex (Fedora/Arch) for registry tweaks"
    SKIP_REG=1
  fi
}

apply_registry_tweaks() {
  local mount_dir="$1"
  [[ "$SKIP_REG" -eq 0 ]] || return 0
  local reg_file="$WORK_DIR/bypass.reg"
  cat >"$reg_file" <<'REG'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\Setup\LabConfig]
"BypassTPMCheck"=dword:00000001
"BypassSecureBootCheck"=dword:00000001
"BypassCPUCheck"=dword:00000001
"BypassRAMCheck"=dword:00000001
"BypassStorageCheck"=dword:00000001
REG
  msg "Applying TPM/RAM/CPU/SB bypass (LabConfig)..."
  hivexregedit --merge "$mount_dir/Windows/System32/config/SYSTEM" <"$reg_file" || warn "Failed to merge registry tweaks"
}

remove_paths() {
  local mount_dir="$1"
  local removed=0
  while IFS= read -r rel; do
    local target="$mount_dir/$rel"
    if compgen -G "$target" >/dev/null 2>&1; then
      msg "Removing $rel"
      rm -rf $target
      removed=$((removed+1))
    fi
  done < <(build_removal_list)
  msg "Removal entries processed: $removed"
}

rebuild_iso() {
  local src_dir="$1"
  local iso_out="$2"
  msg "Rebuilding ISO -> $iso_out"
  if [[ "$ISO_TOOL" == "xorriso" ]]; then
    xorriso -as mkisofs -iso-level 3 -udf -D -N \
      -V "WIN11_TINY" \
      -b "boot/etfsboot.com" -no-emul-boot -boot-load-size 8 -boot-info-table \
      -eltorito-alt-boot -eltorito-platform efi -eltorito-boot "efi/microsoft/boot/efisys.bin" -no-emul-boot \
      -o "$iso_out" "$src_dir" >/dev/null
  else
    genisoimage -udf -iso-level 3 -D -N \
      -V "WIN11_TINY" \
      -b "boot/etfsboot.com" -no-emul-boot -boot-load-size 8 -boot-info-table \
      -eltorito-alt-boot -eltorito-platform efi -eltorito-boot "efi/microsoft/boot/efisys.bin" -no-emul-boot \
      -o "$iso_out" "$src_dir" >/dev/null
  fi
  msg "ISO rebuilt"
}

main() {
  parse_args "$@"
  ensure_tools
  
  # Verify input ISO exists
  if [[ ! -f "$ISO_IN" ]]; then
    fatal_error "ISO not found: $ISO_IN" 1 \
      "Provide a valid path to Windows 11 ISO"
  fi
  
  verify_file "$ISO_IN" 4000 "Input ISO"
  
  # Check disk space requirements
  check_disk_space "$TMP_ROOT" 12000 "temporary working files"
  check_disk_space "$(dirname "$OUT_ISO")" 6000 "output ISO"
  
  # Create working directory with cleanup registration
  WORK_DIR="$(mktemp -d "$TMP_ROOT/tiny11-XXXX")"
  register_temp_dir "$WORK_DIR"
  
  mkdir -p "$WORK_DIR/iso" "$WORK_DIR/mount"

  msg "Extracting ISO..."
  if ! 7z x -y -o"$WORK_DIR/iso" "$ISO_IN" >/dev/null 2>&1; then
    fatal_error "Failed to extract ISO" 40 \
      "ISO file may be corrupted or 7z encountered an error"
  fi

  local install_img="$WORK_DIR/iso/sources/install.wim"
  if [[ ! -f "$install_img" ]]; then
    local esd="$WORK_DIR/iso/sources/install.esd"
    if [[ ! -f "$esd" ]]; then
      fatal_error "No install.wim or install.esd found" 40 \
        "ISO may not be a valid Windows 11 installer"
    fi
    msg "Converting install.esd -> install.wim (this may take a bit)..."
    if ! wimlib-imagex convert "$esd" "$install_img" >/dev/null 2>&1; then
      fatal_error "Failed to convert install.esd to install.wim" 40 \
        "Check disk space and wimlib installation"
    fi
  fi

  msg "Mounting image index $IMAGE_INDEX..."
  if ! wimlib-imagex mount "$install_img" "$IMAGE_INDEX" "$WORK_DIR/mount" 2>&1; then
    fatal_error "Failed to mount WIM image" 40 \
      "Image index may be invalid or wimlib encountered an error"
  fi
  
  # Ensure unmount on cleanup
  register_temp_dir "$WORK_DIR/mount"

  if [[ "$PRESET" != "vanilla" ]]; then
    remove_paths "$WORK_DIR/mount"
    apply_registry_tweaks "$WORK_DIR/mount"
  else
    msg "Preset 'vanilla' selected; skipping removals."
  fi

  msg "Committing changes..."
  if ! wimlib-imagex unmount "$WORK_DIR/mount" --commit 2>&1; then
    warn "Unmount with commit failed, trying without commit..."
    wimlib-imagex unmount "$WORK_DIR/mount" 2>/dev/null || true
    fatal_error "Failed to commit WIM changes" 40 \
      "Changes to Windows image could not be saved"
  fi

  rebuild_iso "$WORK_DIR/iso" "$OUT_ISO"
  success_msg "Done. Output ISO: $OUT_ISO"
}

main "$@"
