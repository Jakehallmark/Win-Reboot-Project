#!/usr/bin/env bash
set -euo pipefail

# Download latest public Windows 11 ISO via UUP dump (Microsoft CDN).
# Default: Retail, x64, en-us, Professional. Produces out/win11.iso.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib_error.sh" 2>/dev/null || {
  echo "[!] Error: Cannot load error handling library" >&2
  echo "[!] Make sure lib_error.sh exists in $SCRIPT_DIR" >&2
  exit 1
}

CHANNEL="retail"
ARCH="amd64"
LANG="en-us"
EDITIONS="professional"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"
TMP_DIR="${TMP_DIR:-$(pwd)/tmp}"
UPDATE_ID="${UPDATE_ID:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: fetch_iso.sh [--lang en-us] [--edition professional,home] [--arch amd64]
                    [--channel retail|rp] [--update-id <id>] [--dry-run]

Defaults: Retail, amd64, en-us, Professional. Output -> out/win11.iso
Notes:
  - Uses UUP dump API to resolve a build ID unless --update-id is provided.
  - Downloads a generated UUP dump package, then runs its uup_download_linux.sh.
  - Network must reach uupdump.net and Microsoft CDN.
EOF
}

msg() { echo "[+] $*"; }

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lang) LANG="$2"; shift 2;;
      --edition|--editions) EDITIONS="$2"; shift 2;;
      --arch) ARCH="$2"; shift 2;;
      --channel) CHANNEL="$2"; shift 2;;
      --update-id) UPDATE_ID="$2"; shift 2;;
      --dry-run) DRY_RUN=1; shift;;
      -h|--help) usage; exit 0;;
      *) err "Unknown arg: $1";;
    esac
  done
}

detect_latest_update_id() {
  require_commands curl python3
  check_network "https://api.uupdump.net"
  
  local api="https://api.uupdump.net/listbuilds.php?arch=${ARCH}&ring=${CHANNEL}&search=Windows%2011"
  msg "Querying UUP dump for latest Windows 11 (${CHANNEL}/${ARCH})"
  
  local json
  json="$(curl -fsSL "$api" 2>&1)" || 
    fatal_error "Failed to reach UUP dump API" 20 "Could not connect to api.uupdump.net"
  
  UPDATE_ID="$(python3 - "$json" <<'PY'
import json,sys
try:
    data=json.loads(sys.stdin.read())
    builds=data.get("builds",[])
    if not builds:
        sys.exit(1)
    print(builds[0].get("uuid",""))
except Exception as e:
    print(f"Error parsing JSON: {e}", file=sys.stderr)
    sys.exit(1)
PY
)" || fatal_error "Could not parse update ID from UUP dump response" 20 "API response may be invalid"
  
  [[ -n "$UPDATE_ID" ]] || fatal_error "Empty update ID received" 20 "UUP dump may not have builds available"
}

download_package_zip() {
  check_disk_space "$TMP_DIR" 1000 "UUP dump package download"
  mkdir -p "$TMP_DIR"
  register_temp_dir "$TMP_DIR/uupdump-${UPDATE_ID}"
  
  local zip_path="$TMP_DIR/uupdump-${UPDATE_ID}.zip"
  register_temp_file "$zip_path"
  
  local get_url="https://uupdump.net/get.php?id=${UPDATE_ID}&pack=${LANG}&edition=${EDITIONS}&aria2=2"
  msg "Downloading UUP dump package: $get_url"
  
  curl -fL "$get_url" -o "$zip_path" 2>&1 || 
    fatal_error "Failed to download UUP dump package" 20 \
      "Check network connection and try again"
  
  verify_file "$zip_path" 0 "UUP dump package"
  echo "$zip_path"
}

run_uupdump_package() {
  local pkg_dir="$1"
  local iso_out="$OUT_DIR/win11.iso"
  
  check_disk_space "$OUT_DIR" 6000 "ISO output"
  mkdir -p "$OUT_DIR"
  
  msg "Running UUP dump helper (this may take a while)..."
  msg "This process downloads from Microsoft CDN and builds the ISO"
  
  if ! (cd "$pkg_dir" && bash ./uup_download_linux.sh 2>&1 | tee "$TMP_DIR/uup_build.log"); then
    fatal_error "UUP dump helper script failed" 40 \
      "Check $TMP_DIR/uup_build.log for details. May be due to network issues or disk space."
  fi
  
  local built_iso
  built_iso="$(find "$pkg_dir" -maxdepth 1 -type f -name '*.iso' | head -n1)"
  
  if [[ -z "$built_iso" ]]; then
    fatal_error "No ISO produced by UUP dump helper" 40 \
      "Build completed but no ISO file found. Check $TMP_DIR/uup_build.log"
  fi
  
  verify_file "$built_iso" 4000 "Built ISO"
  
  msg "Copying ISO to $iso_out"
  cp "$built_iso" "$iso_out" || 
    fatal_error "Failed to copy ISO" 60 "Check permissions and disk space"
  
  success_msg "ISO ready: $iso_out"
}

main() {
  parse_args "$@"
  
  # Check prerequisites
  require_commands unzip aria2c curl python3
  
  # Detect or use provided update ID
  [[ -n "$UPDATE_ID" ]] || detect_latest_update_id
  msg "Using update ID: $UPDATE_ID"
  
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run only. Would fetch: id=$UPDATE_ID lang=$LANG editions=$EDITIONS arch=$ARCH channel=$CHANNEL"
    echo "Estimated download size: ~5-6 GB"
    echo "Output location: $OUT_DIR/win11.iso"
    exit 0
  fi
  
  # Download and extract package
  local zip_path
  zip_path="$(download_package_zip)"
  
  local pkg_dir="$TMP_DIR/uupdump-${UPDATE_ID}"
  rm -rf "$pkg_dir"
  
  msg "Extracting UUP dump package..."
  unzip -q "$zip_path" -d "$pkg_dir" 2>&1 || 
    fatal_error "Failed to extract package" 40 "ZIP file may be corrupted"
  
  [[ -x "$pkg_dir/uup_download_linux.sh" ]] || chmod +x "$pkg_dir/uup_download_linux.sh"
  
  # Run the build process
  run_uupdump_package "$pkg_dir"
}

main "$@"
