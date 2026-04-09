#!/usr/bin/env bash
set -euo pipefail

# Win-Reboot-Project: Windows 11 USB Installer for macOS
# Supports: macOS 14 (Sonoma), macOS 15 (Sequoia), and macOS 26 (Tahoe)
# Architectures: Apple Silicon (M1/M2/M3/M4) and Intel (x86_64)

[[ "$(uname -s)" == "Darwin" ]] || {
  echo "[!] This script is macOS-only. Use win11-setup.sh on Linux."
  exit 1
}

# BASH_SOURCE may be unset when this script is run via stdin (curl | bash).
# On macOS Bash 3.2, avoid indexing BASH_SOURCE unless it is set.
SCRIPT_SOURCE="$0"
if [[ -n "${BASH_SOURCE:-}" ]]; then
  SCRIPT_SOURCE="${BASH_SOURCE[0]}"
fi
if [[ "$SCRIPT_SOURCE" == "bash" || "$SCRIPT_SOURCE" == "-" ]]; then
  SCRIPT_DIR="$PWD"
else
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
fi

BOOTSTRAP_MODE="file"
if [[ -z "${BASH_SOURCE:-}" || "$0" == "bash" || "$0" == "-" ]]; then
  BOOTSTRAP_MODE="stdin"
fi

# Optional startup diagnostics for troubleshooting bootstrap mode.
if [[ "${WIN_REBOOT_DEBUG:-0}" == "1" ]]; then
  echo "[+] Bootstrap mode: $BOOTSTRAP_MODE (script dir: $SCRIPT_DIR)"
fi

#============================================================================
# CONFIGURATION
#============================================================================
ROOT_DIR="$SCRIPT_DIR"

TMP_DIR="${TMP_DIR:-$ROOT_DIR/tmp}"
OUT_DIR="$ROOT_DIR/out"
ISO_PATH="$OUT_DIR/win11.iso"

INSTALLER_VOL_LABEL="WIN11_INST"
WIM_SPLIT_MB=3800

ARCH="$(uname -m)"   # arm64 = Apple Silicon, x86_64 = Intel
[[ "$ARCH" == "arm64" ]] && HOMEBREW_PREFIX="/opt/homebrew" || HOMEBREW_PREFIX="/usr/local"

# FUSE availability - set by detect_macfuse, consumed by trimming + driver injection
FUSE_AVAILABLE=0

mkdir -p "$TMP_DIR" "$OUT_DIR"

#============================================================================
# UTILITY FUNCTIONS
#============================================================================

msg()  { echo "[+] $*"; }
warn() { echo "[!] $*" >&2; }
err()  { echo "[!] ERROR: $*" >&2; exit 1; }

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_host_arch() {
  local raw
  raw="$(to_lower "$(uname -m)")"
  case "$raw" in
    arm64|aarch64|armv8*|armv9*) echo "arm64" ;;
    x86_64|amd64|x64|i386|i486|i586|i686|x86) echo "x64" ;;
    *) echo "unknown" ;;
  esac
}

detect_uup_arch_from_pkg() {
  local pkg_dir="$1"
  local zip_file="$2"

  local arm_hits=0
  local x64_hits=0
  local zip_lower

  zip_lower="$(to_lower "$(basename "$zip_file")")"
  [[ "$zip_lower" == *"arm64"* || "$zip_lower" == *"aarch64"* ]] && arm_hits=$((arm_hits+4))
  [[ "$zip_lower" == *"amd64"* || "$zip_lower" == *"x64"* || "$zip_lower" == *"x86_64"* ]] && x64_hits=$((x64_hits+4))

  arm_hits=$((arm_hits + $(grep -RIEio 'arm64|aarch64' "$pkg_dir" 2>/dev/null | wc -l | tr -d ' ')))
  x64_hits=$((x64_hits + $(grep -RIEio 'amd64|x64|x86_64' "$pkg_dir" 2>/dev/null | wc -l | tr -d ' ')))

  if (( arm_hits > 0 && x64_hits == 0 )); then
    echo "arm64"
  elif (( x64_hits > 0 && arm_hits == 0 )); then
    echo "x64"
  elif (( arm_hits >= (x64_hits * 2) )); then
    echo "arm64"
  elif (( x64_hits >= (arm_hits * 2) )); then
    echo "x64"
  else
    echo "unknown"
  fi
}

confirm_arch_mismatch_if_needed() {
  local host_arch="$1"
  local target_arch="$2"

  [[ "$host_arch" == "unknown" || "$target_arch" == "unknown" ]] && return 0
  [[ "$host_arch" == "$target_arch" ]] && return 0

  if [[ "$host_arch" == "arm64" && "$target_arch" == "x64" ]]; then
    warn "Detected Apple Silicon (ARM64), but selected UUP package appears to be x64/amd64."
    warn "x64 Windows media does not boot natively on Apple Silicon."
  elif [[ "$host_arch" == "x64" && "$target_arch" == "arm64" ]]; then
    warn "Detected Intel x86_64 host, but selected UUP package appears to be ARM64."
    warn "ARM64 media may not boot or install on x86_64 systems."
  else
    warn "Host CPU architecture ($host_arch) does not match selected UUP architecture ($target_arch)."
  fi

  if ! prompt_yn "Proceed anyway with this architecture mismatch?" "n"; then
    err "Aborted by user due to architecture mismatch"
  fi
}

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
  [[ "$(to_lower "$answer")" == "y" ]]
}

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing required command: $c"
  done
}

file_size_bytes() {
  stat -f%z "$1" 2>/dev/null || echo 0
}

human_size() {
  local b="$1"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1;
    while(b>=1024 && i<5){b/=1024;i++}
    printf "%.2f %s\n", b, u[i]
  }'
}

validate_vol_label() {
  local label="$1"
  [[ ${#label} -le 11 ]] || err "Volume label too long (max 11 chars): $label"
}

#----------------------------------------------------------------------------
# Cleanup and mount tracking
#----------------------------------------------------------------------------

cleanup_mounts=()
cleanup_dirs=()

cleanup() {
  set +e
  for ((i=${#cleanup_mounts[@]}-1; i>=0; i--)); do
    local m="${cleanup_mounts[$i]}"
    [[ -d "$m" ]] && hdiutil detach "$m" -force >/dev/null 2>&1 || true
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
  mkdir -p "$mnt"
  hdiutil attach -readonly -mountpoint "$mnt" -nobrowse "$iso" \
    || err "Failed to mount ISO: $iso"
  cleanup_mounts+=("$mnt")
}

#----------------------------------------------------------------------------
# File copy helpers
#----------------------------------------------------------------------------

copy_tree() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"
  # ditto preserves HFS+ metadata; fall back to cp -a
  if command -v ditto >/dev/null 2>&1; then
    ditto "$src"/ "$dst"/ || err "Failed to copy tree"
  else
    cp -a "$src"/. "$dst"/ || err "Failed to copy tree"
  fi
}

copy_tree_progress() {
  local src="$1"
  local dst="$2"
  mkdir -p "$dst"

  if command -v rsync >/dev/null 2>&1; then
    msg "Copying with rsync progress..."
    rsync -a --info=progress2 "$src"/ "$dst"/ || err "rsync copy failed"
    return 0
  fi

  if command -v pv >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
    msg "Copying with pv progress..."
    local total_bytes
    total_bytes="$(du -sk "$src" 2>/dev/null | awk '{print $1*1024}')"
    [[ -n "${total_bytes:-}" ]] || total_bytes=0
    (cd "$src" && tar -cf - .) | pv -s "$total_bytes" | (cd "$dst" && tar -xpf -) \
      || err "pv/tar copy failed"
    return 0
  fi

  warn "No rsync/pv available. Copying without progress (this may take a while)..."
  ditto "$src"/ "$dst"/ || cp -a "$src"/. "$dst"/ || err "Copy failed"
}

#----------------------------------------------------------------------------
# Destruction confirmation
#----------------------------------------------------------------------------

confirm_destruction() {
  local dev="$1"
  warn "This will ERASE ALL DATA on: $dev"
  diskutil info "$dev" 2>/dev/null | grep -E "Device:|Disk Size:|Media Name:" || true
  echo ""
  read -r -p "Type the full device path to confirm ($dev): " typed < /dev/tty
  [[ "$typed" == "$dev" ]] || err "Confirmation did not match. Aborting."
}

#============================================================================
# PLATFORM CHECKS
#============================================================================

check_macos_version() {
  local os_ver
  os_ver="$(sw_vers -productVersion)"
  local major
  major="$(echo "$os_ver" | cut -d. -f1)"

  if [[ "$major" -lt 14 ]]; then
    err "macOS 14 (Sonoma) or later is required. You have macOS $os_ver."
  fi
  # macOS 14 (Sonoma), 15 (Sequoia), and 26 (Tahoe)+ are all supported

  msg "macOS $os_ver ($ARCH) detected"
  if [[ "$ARCH" == "arm64" ]]; then
    msg "Apple Silicon detected (Homebrew at $HOMEBREW_PREFIX)"
    warn "NOTE: Standard Windows 11 x64 ISOs cannot boot natively on Apple Silicon."
    warn "      For native ARM: download an ARM64 build from UUP dump."
    warn "      USB creation itself works on all Mac architectures."
  else
    msg "Intel Mac detected (Homebrew at $HOMEBREW_PREFIX)"
  fi
  echo ""
}

detect_macfuse() {
  if [[ -d /Library/Filesystems/macfuse.fs ]]; then
    FUSE_AVAILABLE=1
  elif systemextensionsctl list 2>/dev/null | grep -qi "fuse"; then
    FUSE_AVAILABLE=1
  else
    FUSE_AVAILABLE=0
  fi

  if [[ "$FUSE_AVAILABLE" -eq 1 ]]; then
    msg "macFUSE detected: WIM offline mount operations available"
  else
    warn "macFUSE not found. Offline WIM mount operations will use FUSE-free fallbacks."
    warn "  - Tiny11 offline prune:   SKIPPED (ISO-level removals still apply)"
    warn "  - boot.wim driver patch:  will use 'wimlib-imagex update' instead"
    warn "  - Install macFUSE if needed: https://macfuse.io"
  fi
  echo ""
}

#============================================================================
# HOMEBREW & DEPENDENCIES
#============================================================================

ensure_homebrew() {
  # Add Homebrew to PATH for this session (handles both curl|bash and local runs)
  if [[ -f "$HOMEBREW_PREFIX/bin/brew" ]]; then
    eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)" 2>/dev/null || true
    return 0
  fi

  if command -v brew >/dev/null 2>&1; then
    return 0
  fi

  warn "Homebrew not found at $HOMEBREW_PREFIX."
  if prompt_yn "Install Homebrew now?" "y"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
      || err "Homebrew installation failed"
    # Re-source shellenv after install
    [[ -f "$HOMEBREW_PREFIX/bin/brew" ]] && eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)" 2>/dev/null || true
  else
    err "Homebrew is required. Install it from https://brew.sh"
  fi
}

check_dependencies() {
  msg "Checking dependencies..."
  check_macos_version
  ensure_homebrew

  # Homebrew packages: package_name -> command_to_check
  local -a pkgs=("aria2" "wimlib" "xorriso" "cabextract" "p7zip")
  local -a cmds=("aria2c" "wimlib-imagex" "xorriso" "cabextract" "7z")

  local missing_pkgs=()
  for ((i=0; i<${#pkgs[@]}; i++)); do
    command -v "${cmds[$i]}" >/dev/null 2>&1 || missing_pkgs+=("${pkgs[$i]}")
  done

  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    warn "Missing Homebrew packages: ${missing_pkgs[*]}"
    if prompt_yn "Auto-install with 'brew install'?" "y"; then
      brew install "${missing_pkgs[@]}" || err "Failed to install Homebrew packages"
      msg "Dependencies installed"
    else
      err "Cannot continue without required dependencies"
    fi
  fi

  detect_macfuse
}

#============================================================================
# DRIVER INJECTION
#============================================================================

DRIVERS_DIR="${DRIVERS_DIR:-$ROOT_DIR/drivers}"

extract_any_driver_payloads() {
  local in_dir="$1"
  local out_dir="$2"
  mkdir -p "$out_dir"

  shopt -s nullglob
  local f
  for f in "$in_dir"/*; do
    [[ -f "$f" ]] || continue
    case "$(to_lower "$f")" in
      *.zip)
        mkdir -p "$out_dir/$(basename "$f").d"
        unzip -q "$f" -d "$out_dir/$(basename "$f").d" || true
        ;;
      *.cab)
        command -v cabextract >/dev/null 2>&1 || err "Need cabextract to extract: $f"
        mkdir -p "$out_dir/$(basename "$f").d"
        cabextract -q -d "$out_dir/$(basename "$f").d" "$f" || true
        ;;
      *.msi|*.exe)
        if command -v 7z >/dev/null 2>&1; then
          mkdir -p "$out_dir/$(basename "$f").d"
          7z x -y -o"$out_dir/$(basename "$f").d" "$f" >/dev/null 2>&1 || true
        else
          warn "Skipping $(basename "$f") (no 7z)"
        fi
        ;;
      *.inf) ;;
      *) warn "Unknown driver payload type, ignoring: $(basename "$f")" ;;
    esac
  done
  shopt -u nullglob
}

collect_inf_roots() {
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
    cp -a "$dir"/. "$dest/DriverSet$n"/ 2>/dev/null || true
  done <<< "$inf_root_list"
  msg "Staged $n INF driver set(s)"
}

# FUSE path: mount boot.wim, edit startnet.cmd, commit (identical to Linux)
_patch_boot_wim_via_mount() {
  local iso_tree="$1"
  local boot_wim="$iso_tree/sources/boot.wim"
  local mount_dir
  mount_dir="$(mktemp_dir)"

  msg "Patching boot.wim index 2 via WIM mount..."
  wimlib-imagex mountrw "$boot_wim" 2 "$mount_dir" || err "Failed to mount boot.wim index 2"

  local snc="$mount_dir/Windows/System32/startnet.cmd"
  [[ -f "$snc" ]] || err "startnet.cmd not found inside boot.wim"
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

# FUSE-free path: use wimlib-imagex update to replace startnet.cmd without mounting
_patch_boot_wim_via_update() {
  local iso_tree="$1"
  local boot_wim="$iso_tree/sources/boot.wim"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  msg "Patching boot.wim index 2 via wimlib update (FUSE-free)..."

  cat > "$tmp_dir/startnet.cmd" <<'CMD'
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

  wimlib-imagex update "$boot_wim" 2 \
    --command="add $tmp_dir/startnet.cmd /Windows/System32/startnet.cmd" \
    || err "Failed to update boot.wim via wimlib update"

  rm -rf "$tmp_dir"
}

patch_boot_wim_to_drvload_oem_drivers() {
  local iso_tree="$1"
  local boot_wim="$iso_tree/sources/boot.wim"
  [[ -f "$boot_wim" ]] || err "boot.wim not found at $boot_wim"
  require_cmd wimlib-imagex

  if [[ "$FUSE_AVAILABLE" -eq 1 ]]; then
    _patch_boot_wim_via_mount "$iso_tree"
  else
    _patch_boot_wim_via_update "$iso_tree"
  fi
}

inject_drivers_into_iso_tree() {
  local iso_tree="$1"
  if [[ ! -d "$DRIVERS_DIR" ]]; then
    msg "No drivers directory found ($DRIVERS_DIR). Skipping driver injection."
    return 0
  fi

  local work="$TMP_DIR/driver_work"
  rm -rf "$work"
  mkdir -p "$work/extracted"

  msg "Collecting driver payloads from: $DRIVERS_DIR"
  extract_any_driver_payloads "$DRIVERS_DIR" "$work/extracted"

  local inf_roots
  inf_roots="$(
    {
      collect_inf_roots "$DRIVERS_DIR"
      collect_inf_roots "$work/extracted"
    } | awk '!seen[$0]++'
  )"

  if [[ -z "${inf_roots// }" ]]; then
    warn "No .inf drivers found in $DRIVERS_DIR. Skipping driver injection."
    return 0
  fi

  stage_inf_drivers_into_tree "$iso_tree" "$inf_roots"
  patch_boot_wim_to_drvload_oem_drivers "$iso_tree"
  msg "Driver injection complete."
}

#============================================================================
# STEP 1: FETCH ISO (via UUP dump ZIP)
#============================================================================

pick_file_macos() {
  local prompt_text="$1"
  local result=""
  # Skip GUI picker if over SSH
  if [[ -z "${SSH_CONNECTION:-}" && -z "${SSH_CLIENT:-}" ]]; then
    result="$(osascript -e "POSIX path of (choose file with prompt \"$prompt_text\")" 2>/dev/null || true)"
    result="${result%$'\n'}"  # strip trailing newline osascript adds
  fi
  echo "$result"
}

pick_dir_macos() {
  local prompt_text="$1"
  local result=""
  # Skip GUI picker if over SSH
  if [[ -z "${SSH_CONNECTION:-}" && -z "${SSH_CLIENT:-}" ]]; then
    result="$(osascript -e "POSIX path of (choose folder with prompt \"$prompt_text\")" 2>/dev/null || true)"
    result="${result%$'\n'}"
  fi
  echo "$result"
}

find_uup_download_script() {
  local base_dir="$1"
  local found=""

  found="$(find "$base_dir" -type f -name 'uup_download_macos.sh' 2>/dev/null | head -n1)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  found="$(find "$base_dir" -type f -name 'uup_download_linux.sh' 2>/dev/null | head -n1)"
  if [[ -n "$found" ]]; then
    echo "$found"
    return 0
  fi

  return 1
}

strip_chntpw_from_uup_package() {
  local pkg_dir="$1"
  local patched=0

  # UUP packages may spread dependency checks across multiple sourced scripts.
  while IFS= read -r -d '' script_path; do
    grep -qi "chntpw" "$script_path" || continue

    if perl -0777 -i -pe 's/\bchntpw\b/true/ig' "$script_path" 2>/dev/null; then
      patched=$((patched+1))
    else
      err "Failed to patch UUP script: $script_path"
    fi
  done < <(find "$pkg_dir" -type f -name '*.sh' -print0 2>/dev/null)

  if [[ "$patched" -gt 0 ]]; then
    msg "Removed legacy chntpw dependency references from $patched script(s)."
  fi
}

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
  2. Select a build (e.g., latest stable)
  3. Choose your language and edition(s)
  4. On the download page, select the macOS download package
     (for Apple Silicon, choose the ARM64 build for native boot)
  5. Download the ZIP file (or use the auto-extracted folder from Downloads)

Press Enter when ready to select the downloaded ZIP or extracted folder...
EOF

  read -r -p "" < /dev/tty
  echo ""

  local source_path
  source_path="$(pick_file_macos "Select UUP dump ZIP file (Cancel to choose folder)")"

  if [[ -z "$source_path" ]]; then
    source_path="$(pick_dir_macos "Select extracted UUP dump folder (or Cancel to type path)")"
  fi

  if [[ -z "$source_path" ]]; then
    read -r -p "Path to UUP dump ZIP or extracted folder: " source_path < /dev/tty
  fi

  source_path="${source_path%$'\n'}"
  [[ -e "$source_path" ]] || err "Path not found: $source_path"

  local pkg_dir=""
  if [[ -d "$source_path" ]]; then
    pkg_dir="$source_path"
    msg "Using extracted UUP dump folder: $pkg_dir"
  elif [[ -f "$source_path" ]]; then
    case "$(to_lower "$source_path")" in
      *.zip)
        msg "Extracting UUP dump package..."
        pkg_dir="$TMP_DIR/uupdump"
        rm -rf "$pkg_dir"
        mkdir -p "$pkg_dir"
        unzip -q "$source_path" -d "$pkg_dir" || err "Failed to extract ZIP"
        ;;
      *)
        err "Unsupported file type: $source_path (expected .zip or extracted folder)"
        ;;
    esac
  else
    err "Unsupported path type: $source_path"
  fi

  local host_arch uup_arch
  host_arch="$(normalize_host_arch)"
  uup_arch="$(detect_uup_arch_from_pkg "$pkg_dir" "$source_path")"
  msg "Host CPU architecture: $host_arch"
  if [[ "$uup_arch" == "unknown" ]]; then
    warn "Could not confidently detect UUP package architecture."
  else
    msg "Detected UUP package architecture: $uup_arch"
  fi
  confirm_arch_mismatch_if_needed "$host_arch" "$uup_arch"

  # UUP ZIP contents are sometimes wrapped in an extra folder; search recursively.
  local uup_script=""
  uup_script="$(find_uup_download_script "$pkg_dir" || true)"
  if [[ -z "$uup_script" ]]; then
    err "Invalid UUP dump package: no download script found"
  fi

  case "$(basename "$uup_script")" in
    uup_download_macos.sh)
      msg "Using UUP dump macOS script"
      ;;
    uup_download_linux.sh)
      warn "No macOS UUP script found in package; falling back to Linux script"
      ;;
  esac

  chmod +x "$uup_script"
  local uup_script_dir
  uup_script_dir="$(dirname "$uup_script")"
  strip_chntpw_from_uup_package "$pkg_dir"
  msg "Running UUP dump conversion (this may take a while)..."
  (cd "$uup_script_dir" && bash "$(basename "$uup_script")") || err "UUP dump conversion failed"

  local built_iso
  built_iso="$(find "$pkg_dir" -type f -iname '*.iso' | head -n1)"
  [[ -n "${built_iso:-}" ]] || err "No ISO produced by UUP dump"

  mv "$built_iso" "$ISO_PATH"
  msg "ISO created: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 2: "Tiny11" trimming (best-effort)
#============================================================================

load_preset_lines() {
  local preset="$1"
  local preset_file="$ROOT_DIR/data/removal-presets/${preset}.txt"
  if [[ ! -f "$preset_file" ]]; then
    preset_file="$TMP_DIR/removal-presets/${preset}.txt"
    if [[ ! -f "$preset_file" ]]; then
      mkdir -p "$TMP_DIR/removal-presets"
      local url="https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/data/removal-presets/${preset}.txt"
      msg "Downloading preset: $preset"
      curl -fsSL "$url" -o "$preset_file" 2>/dev/null || return 1
    fi
  fi
  [[ -f "$preset_file" ]] || return 1
  cat "$preset_file"
}

safe_remove_matches() {
  local root="$1"
  local pattern="$2"
  [[ "$pattern" == "/"* || "$pattern" == "*" || -z "$pattern" ]] && return 0
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
  msg "Applying preset: $preset (ISO-level file removals)"
  local lines
  if ! lines="$(load_preset_lines "$preset")"; then
    warn "Failed to load preset: $preset. Skipping removals."
    return 0
  fi
  while IFS= read -r item; do
    [[ -z "$item" || "$item" =~ ^# ]] && continue
    if [[ "$item" == PATH:* ]]; then
      local rel="${item#PATH:}"
      rm -rf "$iso_tree/$rel" 2>/dev/null || true
    fi
  done <<< "$lines"
}

offline_image_best_effort_prune() {
  local iso_tree="$1"
  local preset="$2"
  local wim="$iso_tree/sources/install.wim"
  [[ -f "$wim" ]] || return 0

  if [[ "$FUSE_AVAILABLE" -eq 0 ]]; then
    warn "Skipping offline WIM prune (macFUSE not available)."
    warn "Install macFUSE from https://macfuse.io for full trimming support."
    return 0
  fi

  local image_count
  image_count="$(wimlib-imagex info "$wim" | awk -F': ' '/Image Count:/ {print $2}' | tr -d '\r')"
  [[ -n "${image_count:-}" ]] || return 0

  msg "Offline WIM prune: processing $image_count image(s)..."
  local mount_dir
  mount_dir="$(mktemp_dir)"
  local lines
  lines="$(load_preset_lines "$preset" 2>/dev/null || true)"

  for ((img=1; img<=image_count; img++)); do
    msg "Mounting image $img/$image_count..."
    wimlib-imagex mountrw "$wim" "$img" "$mount_dir" || err "Failed to mount WIM image $img"
    if [[ -n "$lines" ]]; then
      while IFS= read -r item; do
        [[ -z "$item" || "$item" =~ ^# || "$item" == PATH:* ]] && continue
        safe_remove_matches "$mount_dir" "$item"
      done <<< "$lines"
    fi
    msg "Unmounting (commit) image $img..."
    wimlib-imagex unmount "$mount_dir" --commit || err "Failed to unmount WIM image $img"
    sleep 1
  done
}

rebuild_iso_from_tree() {
  local iso_tree="$1"
  local out_iso="$2"
  local volid="$3"
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

  prompt_yn "Apply trimming preset to reduce ISO size?" "y" || {
    msg "Skipping trimming"
    return 0
  }

  echo "Available presets:"
  echo "  minimal    - light removal (consumer apps)"
  echo "  lite       - more removal (+ Help, Media Player, Quick Assist)"
  echo "  aggressive - highest removal (+ Photos, Maps, Camera, etc.)"
  echo "  vanilla    - no changes"
  echo ""

  local preset
  read -r -p "Preset [minimal/lite/aggressive/vanilla]: " preset < /dev/tty
  preset="${preset:-minimal}"

  [[ "$preset" == "vanilla" ]] && { msg "Skipping (vanilla)"; return 0; }

  msg "Preparing ISO working tree..."
  local work_dir="$TMP_DIR/trim"
  rm -rf "$work_dir"
  mkdir -p "$work_dir"

  local iso_ro="$work_dir/iso_ro"
  local iso_tree="$work_dir/iso_tree"
  mkdir -p "$iso_ro" "$iso_tree"

  mount_iso_ro "$ISO_PATH" "$iso_ro"
  msg "Copying ISO contents to writable tree..."
  copy_tree "$iso_ro" "$iso_tree"

  [[ -f "$iso_tree/sources/install.esd" ]] && convert_esd_to_wim_if_needed "$iso_tree"

  apply_preset_to_tree "$iso_tree" "$preset"
  offline_image_best_effort_prune "$iso_tree" "$preset"

  msg "Rebuilding ISO from trimmed tree..."
  local tiny_iso="$OUT_DIR/win11-trimmed.iso"
  rebuild_iso_from_tree "$iso_tree" "$tiny_iso" "WIN11_TRIM"
  mv "$tiny_iso" "$ISO_PATH"
  msg "Trimmed ISO ready: $ISO_PATH"
  echo ""
}

#============================================================================
# STEP 3: USB SETUP (macOS)
#============================================================================

ensure_wim_split_for_fat32_tree() {
  local tree="$1"
  local wim="$tree/sources/install.wim"
  [[ -f "$wim" ]] || return 0

  local size_bytes
  size_bytes="$(file_size_bytes "$wim")"
  if [[ "$size_bytes" -le 4294967295 ]]; then
    return 0
  fi

  msg "install.wim is $(human_size "$size_bytes"). Splitting for FAT32 compatibility..."
  local swm="$tree/sources/install.swm"
  wimlib-imagex split "$wim" "$swm" "$WIM_SPLIT_MB" || err "Failed to split WIM"
  rm -f "$wim"
  msg "WIM split complete (install.swm / install2.swm...)"
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

  [[ -f "$out_tree/sources/install.esd" ]] && convert_esd_to_wim_if_needed "$out_tree"
  ensure_wim_split_for_fat32_tree "$out_tree"
  inject_drivers_into_iso_tree "$out_tree"
}

detect_usb_disks() {
  # Emit lines: /dev/diskX SIZE_BYTES MEDIA_NAME
  local disk
  while IFS= read -r disk; do
    [[ "$disk" =~ ^/dev/disk[0-9]+$ ]] || continue
    local info
    info="$(diskutil info "$disk" 2>/dev/null)" || continue

    # Only external / removable disks (USB, Thunderbolt external, etc.)
    # Exclude disk images, internal, and synthesized APFS containers
    local protocol
    protocol="$(echo "$info" | awk -F': +' '/Protocol:/ {print $2}' | xargs)"
    case "$protocol" in
      USB|Thunderbolt|FireWire|"USB 3.0") ;;  # acceptable external protocols
      *) continue ;;
    esac

    local size_bytes
    size_bytes="$(echo "$info" | awk -F': +' '/Disk Size:/ {
      match($0, /\(([0-9]+) Bytes\)/, a); print a[1]
    }')"
    [[ -n "${size_bytes:-}" ]] || continue

    local media_name
    media_name="$(echo "$info" | awk -F': +' '/Media Name:/ {print $2}' | xargs)"

    echo "$disk $size_bytes $media_name"
  done < <(diskutil list | awk '/^\/dev\/disk[0-9]/ {print $1}')
}

setup_usb() {
  msg "=== Bootable USB Setup ==="
  echo ""
  msg "Detecting removable disks..."

  local devices=()
  local device_sizes=()
  while IFS=' ' read -r dev size_bytes media_name; do
    local size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))
    devices+=("$dev")
    device_sizes+=("$size_gb")
    echo "  ${#devices[@]}) $dev (${size_gb} GB) - ${media_name:-Unknown}"
  done < <(detect_usb_disks)

  if [[ ${#devices[@]} -eq 0 ]]; then
    err "No removable USB devices found. Insert a USB drive (20GB+) and try again."
  fi

  echo ""
  local choice
  read -r -p "Select USB device (1-${#devices[@]}): " choice < /dev/tty
  [[ -n "${choice:-}" ]] || err "No selection made"
  [[ "$choice" -ge 1 && "$choice" -le ${#devices[@]} ]] || err "Invalid selection"

  local usb_dev="${devices[$((choice-1))]}"
  local size_gb="${device_sizes[$((choice-1))]}"

  if [[ "$size_gb" -lt 8 ]]; then
    warn "Selected drive is only ${size_gb}GB. Windows 11 requires at least 8GB."
    prompt_yn "Continue anyway?" "n" || return 1
  fi

  confirm_destruction "$usb_dev"
  prompt_yn "Proceed? This is the last warning." "n" || return 1

  msg "Preparing ISO tree (handles >4GB WIM for FAT32)..."
  local iso_tree="$TMP_DIR/media_iso_tree_usb"
  prepare_iso_tree_for_copy_media "$ISO_PATH" "$iso_tree"

  msg "Unmounting existing volumes on $usb_dev..."
  diskutil unmountDisk "$usb_dev" >/dev/null 2>&1 || true

  msg "Formatting $usb_dev as GPT/FAT32 with label $INSTALLER_VOL_LABEL..."
  validate_vol_label "$INSTALLER_VOL_LABEL"
  # eraseDisk creates: s1=EFI System Partition, s2=FAT32 data partition
  sudo diskutil eraseDisk FAT32 "$INSTALLER_VOL_LABEL" GPT "$usb_dev" \
    || err "Failed to erase and format $usb_dev"

  # Wait for macOS to automount the FAT32 data partition
  local mount_point="/Volumes/$INSTALLER_VOL_LABEL"
  local retries=15
  while [[ ! -d "$mount_point" && $retries -gt 0 ]]; do
    sleep 1
    retries=$((retries - 1))
  done

  if [[ ! -d "$mount_point" ]]; then
    # Try to mount manually
    diskutil mountDisk "${usb_dev}s2" >/dev/null 2>&1 || true
    sleep 2
    [[ -d "$mount_point" ]] || err "Could not find mount point at $mount_point. Try: diskutil mountDisk ${usb_dev}s2"
  fi

  msg "Copying installer files to $mount_point..."
  copy_tree_progress "$iso_tree" "$mount_point"

  msg "Syncing and ejecting $usb_dev..."
  sync
  diskutil eject "$usb_dev" >/dev/null 2>&1 || true

  msg "Bootable USB created on $usb_dev"
  echo ""
}

#============================================================================
# STEP 4: BOOT INSTRUCTIONS
#============================================================================

step_boot_instructions() {
  msg "Step 4: Boot Instructions"
  echo ""

  if [[ "$ARCH" == "arm64" ]]; then
    cat <<'EOF'
Apple Silicon Mac (M1 / M2 / M3 / M4):
  1. Shut down the Mac completely (not restart).
  2. Press and hold the Power button until "Loading startup options" appears.
  3. Select the USB drive from the startup picker.
  4. Click Continue to proceed.

  IMPORTANT: Standard Windows 11 x64 ISOs will not boot natively on Apple
  Silicon. For a native Windows experience on M series, you need:
    - An ARM64 Windows 11 build (available from UUP dump)
    - Or virtualization: Parallels Desktop / VMware Fusion

EOF
  else
    cat <<'EOF'
Intel Mac:
  1. Restart the Mac.
  2. Immediately hold the Option (Alt) key.
  3. In the Startup Manager, select the USB drive (WIN11_INST / EFI Boot).
  4. Windows Setup will start.

  T2 Security Chip (2018+ Intel Macs):
    If the USB does not appear in Startup Manager:
    1. Boot into macOS Recovery (hold Cmd+R at startup).
    2. Open Startup Security Utility.
    3. Set "Allowed Boot Media" to "Allow booting from external media".
    4. Set Security Policy to "Reduced Security" if needed.
    5. Restart and hold Option (Alt).

EOF
  fi
}

#============================================================================
# STEP 5: DONE
#============================================================================

step_done() {
  msg "Step 5: Setup Complete"
  echo ""
  msg "Your Windows 11 USB installer is ready."
  echo ""
  prompt_yn "Restart / shut down now?" "n" || {
    msg "Restart manually when ready to begin Windows installation."
    return 0
  }

  echo ""
  echo "  1) Restart"
  echo "  2) Shut down"
  local choice
  read -r -p "Select (1 or 2): " choice < /dev/tty
  msg "Proceeding in 5 seconds..."
  sleep 5
  case "${choice:-1}" in
    2) sudo shutdown -h now ;;
    *) sudo shutdown -r now ;;
  esac
}

#============================================================================
# INTRO + MAIN
#============================================================================

intro() {
  cat <<EOF
╔═══════════════════════════════════════════════════════════════╗
║        Win-Reboot-Project: Windows 11 Setup (macOS)           ║
╚═══════════════════════════════════════════════════════════════╝

Platform : $(uname -s) $(sw_vers -productVersion) / $ARCH
Flow:
  1. Build ISO from UUP dump (uses uup_download_macos.sh when available)
  2. Optional Tiny11-style trimming (offline WIM prune requires macFUSE)
  3. Create bootable USB drive (diskutil + FAT32, auto-splits WIM >4GB)
  4. Boot instructions (Intel: hold Option | Apple Silicon: hold Power)
  5. Restart / shut down

EOF
  prompt_yn "Continue?" "n" || exit 0
  echo ""
}

main() {
  cd "$ROOT_DIR"
  intro
  check_dependencies
  step_fetch_iso
  step_tiny11
  setup_usb
  step_boot_instructions
  step_done
  msg "All done!"
}

main "$@"
