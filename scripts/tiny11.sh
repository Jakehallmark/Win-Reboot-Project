#!/usr/bin/env bash
set -euo pipefail

# Apply Tiny11-style trimming to a Windows 11 ISO using wimlib.
# Rebuilds a new ISO with modified install.wim.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ISO_IN="${1:-}"
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
err() { echo "[!] $*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing command: $c"
  done
}

parse_args() {
  if [[ -z "$ISO_IN" ]]; then
    usage; err "ISO path is required"
  fi
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --preset) PRESET="$2"; shift 2;;
      --image-index) IMAGE_INDEX="$2"; shift 2;;
      --custom-list) CUSTOM_LIST="$2"; shift 2;;
      --skip-reg) SKIP_REG=1; shift;;
      -h|--help) usage; exit 0;;
      *) err "Unknown arg: $1";;
    esac
  done
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
    minimal|lite) list_file="$ROOT_DIR/data/removal-presets/${PRESET}.txt";;
    *) err "Unknown preset: $PRESET";;
  esac
  load_list "$list_file"
  if [[ -n "$CUSTOM_LIST" ]]; then
    load_list "$CUSTOM_LIST"
  fi
}

ensure_tools() {
  require_cmd 7z wimlib-imagex
  if command -v xorriso >/dev/null 2>&1; then
    ISO_TOOL="xorriso"
  elif command -v genisoimage >/dev/null 2>&1; then
    ISO_TOOL="genisoimage"
  else
    err "Need xorriso or genisoimage to rebuild the ISO"
  fi
  if ! command -v hivexregedit >/dev/null 2>&1; then
    warn "hivexregedit not found; registry bypass tweaks will be skipped"
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
  [[ -f "$ISO_IN" ]] || err "ISO not found: $ISO_IN"
  WORK_DIR="$(mktemp -d "$TMP_ROOT/tiny11-XXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT
  mkdir -p "$WORK_DIR/iso" "$WORK_DIR/mount"

  msg "Extracting ISO..."
  7z x -y -o"$WORK_DIR/iso" "$ISO_IN" >/dev/null

  local install_img="$WORK_DIR/iso/sources/install.wim"
  if [[ ! -f "$install_img" ]]; then
    local esd="$WORK_DIR/iso/sources/install.esd"
    [[ -f "$esd" ]] || err "No install.wim or install.esd found"
    msg "Converting install.esd -> install.wim (this may take a bit)..."
    wimlib-imagex convert "$esd" "$install_img" >/dev/null
  fi

  msg "Mounting image index $IMAGE_INDEX..."
  wimlib-imagex mount "$install_img" "$IMAGE_INDEX" "$WORK_DIR/mount"

  if [[ "$PRESET" != "vanilla" ]]; then
    remove_paths "$WORK_DIR/mount"
    apply_registry_tweaks "$WORK_DIR/mount"
  else
    msg "Preset 'vanilla' selected; skipping removals."
  fi

  msg "Committing changes..."
  wimlib-imagex unmount "$WORK_DIR/mount" --commit

  rebuild_iso "$WORK_DIR/iso" "$OUT_ISO"
  msg "Done. Output ISO: $OUT_ISO"
}

main "$@"
