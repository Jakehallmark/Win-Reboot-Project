#!/usr/bin/env bash
set -euo pipefail

# Download latest public Windows 11 ISO via UUP dump (Microsoft CDN).
# Default: Retail, x64, en-us, Professional. Produces out/win11.iso.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib_error.sh" 2>/dev/null || {
  echo "[!] Error: Cannot load error handling library" >&2
  echo "[!] Make sure lib_error.sh exists in $SCRIPT_DIR" >&2
  exit 1
}

CHANNEL="retail"
ARCH="amd64"
LANG="en-us"
EDITIONS="professional"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
TMP_DIR="${TMP_DIR:-$ROOT_DIR/tmp}"
UPDATE_ID="${UPDATE_ID:-}"
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: fetch_iso.sh [--lang LANG] [--edition EDITION] [--arch ARCH]
                    [--channel CHANNEL] [--update-id ID] [--dry-run]

Options:
  --lang LANG          Language code (e.g., en-us, en-gb, es-es, fr-fr)
  --edition EDITION    Edition(s) - single or comma-separated list
                       Examples: professional, home, core, enterprise, education
                                 professional,home,core (multiple editions)
  --arch ARCH          Architecture: amd64 (x64) or arm64
  --channel CHANNEL    Release channel: retail (stable) or rp (release preview)
  --update-id ID       Specific build ID (skips API query, avoids rate limits)
  --dry-run            Show what would be downloaded without actually downloading

Defaults: 
  Channel:    retail (stable release)
  Arch:       amd64 (64-bit Intel/AMD)
  Language:   en-us (English - United States)
  Edition:    professional
  Output:     out/win11.iso

Examples:
  # Download default (Retail, Professional, en-us, x64)
  ./scripts/fetch_iso.sh
  
  # Download specific edition and language
  ./scripts/fetch_iso.sh --edition home --lang es-es
  
  # Download multiple editions
  ./scripts/fetch_iso.sh --edition professional,home,core
  
  # Use specific build ID (avoids API rate limits)
  ./scripts/fetch_iso.sh --update-id 5510915e-64a2-4775-9c03-2057f94e36fc
  
  # Release Preview channel with ARM architecture
  ./scripts/fetch_iso.sh --channel rp --arch arm64

Notes:
  - Uses UUP dump API to resolve a build ID unless --update-id is provided
  - Downloads a generated UUP dump package, then runs its uup_download_linux.sh
  - Network must reach uupdump.net and Microsoft CDN
  - To find available editions/languages for a build, use interactive mode
  - API rate limiting: Use --update-id to skip the query step if already known
EOF
}

msg() { echo "[+] $*" >&2; }

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
  
  local api="https://api.uupdump.net/fetchupd.php?arch=${ARCH}&ring=${CHANNEL}&build=latest"
  msg "Querying UUP dump for latest Windows 11 (${CHANNEL}/${ARCH})"
  
  local json
  json="$(curl -fsSL "$api" 2>&1)" || 
    fatal_error "Failed to reach UUP dump API" 20 "Could not connect to api.uupdump.net"
  
  # Check if response is valid JSON before parsing
  if ! echo "$json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    echo "[DEBUG] API Response: $json" >&2
    fatal_error "UUP dump API returned invalid response" 20 "API may be rate limiting or experiencing issues. Try again in a few moments."
  fi
  
  UPDATE_ID="$(python3 - "$json" <<'PY'
import json,sys
try:
    # JSON payload is passed as argv[1] to avoid stdin conflicts with heredocs
    input_data = sys.argv[1].strip() if len(sys.argv) > 1 else ""
    if not input_data:
        print("Empty API response", file=sys.stderr)
        sys.exit(1)

    data=json.loads(input_data)
    response=data.get("response",{})

    # Check for API errors
    if "error" in response:
        print(f"API Error: {response['error']}", file=sys.stderr)
        sys.exit(1)

    update_id=response.get("updateId","")
    if not update_id:
        sys.exit(1)
    print(update_id)
except Exception as e:
    print(f"Error parsing JSON: {e}", file=sys.stderr)
    sys.exit(1)
PY
)" || fatal_error "Could not parse update ID from UUP dump response" 20 "API response may be invalid or rate limited. Wait a moment and retry."
  
  [[ -n "$UPDATE_ID" ]] || fatal_error "Empty update ID received" 20 "UUP dump may not have builds available"
}

download_package_zip() {
  check_disk_space "$TMP_DIR" 1000 "UUP dump package download"
  mkdir -p "$TMP_DIR"
  register_temp_dir "$TMP_DIR/uupdump-${UPDATE_ID}"
  
  local zip_path="$TMP_DIR/uupdump-${UPDATE_ID}.zip"
  register_temp_file "$zip_path"
  
  local get_url="https://uupdump.net/get.php?id=${UPDATE_ID}&pack=${LANG}&edition=${EDITIONS}&aria2=2"
  echo "[+] Downloading UUP dump package: $get_url" >&2
  
  if ! curl -L "$get_url" -o "$zip_path" >&2; then
    return 1  # Network error - will be retried
  fi
  
  # Check if we got an error response (HTML/text instead of ZIP)
  local file_size
  file_size=$(stat -c%s "$zip_path" 2>/dev/null || echo 0)
  
  if [[ $file_size -lt 1000 ]]; then
    # Likely an error message, not a real package
    local content
    content=$(cat "$zip_path" 2>/dev/null)
    
    # Check if it's an error message
    if [[ "$content" == *"error"* ]] || [[ "$content" == *"ERROR"* ]] || [[ "$content" == *"not found"* ]]; then
      return 2  # Build not available - will be retried with different channel
    fi
    
    return 2  # Unknown error - will be retried
  fi
  
  # Check if the file is actually a ZIP archive (use -b to get only the description, not the filename)
  if ! file -b "$zip_path" | grep -qi "zip\|compress"; then
    local file_type
    file_type=$(file -b "$zip_path")
    
    # Check if it's an error response (HTML, aria2, or plain text)
    if [[ "$file_type" == *"HTML"* ]] || [[ "$file_type" == *"text"* ]]; then
      return 1  # Build unavailable - return error
    fi
    
    return 1  # Non-ZIP file
  fi
  
  verify_file "$zip_path" 0 "UUP dump package"
  echo "$zip_path"
  return 0
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
  zip_path="$(download_package_zip)" || fatal_error "Failed to download ISO" 20 \
    "Check your options and network connection. Visit https://uupdump.net to manually find a working build ID and use --update-id"
  
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
