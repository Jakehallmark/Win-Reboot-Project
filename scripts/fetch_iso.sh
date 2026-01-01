#!/usr/bin/env bash
set -euo pipefail

# Download latest public Windows 11 ISO via UUP dump (Microsoft CDN).
# Default: Retail, x64, en-us, Professional. Produces out/win11.iso.

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
err() { echo "[!] $*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || err "Missing command: $c"
  done
}

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
  require_cmd curl python3
  local api="https://api.uupdump.net/listbuilds.php?arch=${ARCH}&ring=${CHANNEL}&search=Windows%2011"
  msg "Querying UUP dump for latest Windows 11 (${CHANNEL}/${ARCH})"
  local json
  json="$(curl -fsSL "$api")" || err "Failed to reach UUP dump API"
  UPDATE_ID="$(python3 - "$json" <<'PY'
import json,sys
data=json.loads(sys.stdin.read())
builds=data.get("builds",[])
if not builds:
    sys.exit(1)
# pick first entry (should be newest)
print(builds[0].get("uuid",""))
PY
)"
  [[ -n "$UPDATE_ID" ]] || err "Could not parse update ID from UUP dump response"
}

download_package_zip() {
  mkdir -p "$TMP_DIR"
  local zip_path="$TMP_DIR/uupdump-${UPDATE_ID}.zip"
  local get_url="https://uupdump.net/get.php?id=${UPDATE_ID}&pack=${LANG}&edition=${EDITIONS}&aria2=2"
  msg "Downloading UUP dump package: $get_url"
  curl -fL "$get_url" -o "$zip_path" || err "Failed to download UUP dump package"
  echo "$zip_path"
}

run_uupdump_package() {
  local pkg_dir="$1"
  local iso_out="$OUT_DIR/win11.iso"
  mkdir -p "$OUT_DIR"
  msg "Running UUP dump helper (this may take a while)..."
  (cd "$pkg_dir" && bash ./uup_download_linux.sh) || err "uup_download_linux.sh failed"
  local built_iso
  built_iso="$(find "$pkg_dir" -maxdepth 1 -type f -name '*.iso' | head -n1)"
  [[ -n "$built_iso" ]] || err "No ISO produced by UUP dump helper"
  msg "Copying ISO to $iso_out"
  cp "$built_iso" "$iso_out"
  msg "ISO ready: $iso_out"
}

main() {
  parse_args "$@"
  require_cmd unzip
  [[ -n "$UPDATE_ID" ]] || detect_latest_update_id
  msg "Using update ID: $UPDATE_ID"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "Dry run only. Would fetch: id=$UPDATE_ID lang=$LANG editions=$EDITIONS arch=$ARCH channel=$CHANNEL"
    exit 0
  fi
  local zip_path
  zip_path="$(download_package_zip)"
  local pkg_dir="$TMP_DIR/uupdump-${UPDATE_ID}"
  rm -rf "$pkg_dir"
  unzip -q "$zip_path" -d "$pkg_dir" || err "Failed to unzip package"
  [[ -x "$pkg_dir/uup_download_linux.sh" ]] || chmod +x "$pkg_dir/uup_download_linux.sh"
  run_uupdump_package "$pkg_dir"
}

main "$@"
