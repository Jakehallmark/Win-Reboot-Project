#!/usr/bin/env bash
set -euo pipefail

# Test suite for Win-Reboot-Project scripts
# Validates syntax, checks for common issues, and runs dry-run tests

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

msg() { echo "[OK] $*"; }
err() { echo "[FAIL] $*" >&2; }
info() { echo "[i] $*"; }

test_syntax() {
  local script="$1"
  info "Testing syntax: $script"
  if bash -n "$script" 2>/dev/null; then
    msg "Syntax valid: $(basename "$script")"
    PASS=$((PASS + 1))
  else
    err "Syntax error: $(basename "$script")"
    FAIL=$((FAIL + 1))
  fi
}

test_executable() {
  local script="$1"
  info "Testing executable: $script"
  if [[ -x "$script" ]]; then
    msg "Executable: $(basename "$script")"
    PASS=$((PASS + 1))
  else
    err "Not executable: $(basename "$script")"
    FAIL=$((FAIL + 1))
  fi
}

test_help_flag() {
  local script="$1"
  info "Testing --help flag: $script"
  if "$script" --help >/dev/null 2>&1 || "$script" -h >/dev/null 2>&1; then
    msg "Help flag works: $(basename "$script")"
    PASS=$((PASS + 1))
  else
    err "Help flag failed: $(basename "$script")"
    FAIL=$((FAIL + 1))
  fi
}

test_shebang() {
  local script="$1"
  info "Testing shebang: $script"
  local shebang
  shebang="$(head -n1 "$script")"
  if [[ "$shebang" =~ ^#!/usr/bin/env\ bash$ ]]; then
    msg "Correct shebang: $(basename "$script")"
    PASS=$((PASS + 1))
  else
    err "Incorrect shebang: $(basename "$script") - $shebang"
    FAIL=$((FAIL + 1))
  fi
}

test_set_opts() {
  local script="$1"
  info "Testing set options: $script"
  if grep -q "set -euo pipefail" "$script"; then
    msg "Has 'set -euo pipefail': $(basename "$script")"
    PASS=$((PASS + 1))
  else
    err "Missing 'set -euo pipefail': $(basename "$script")"
    FAIL=$((FAIL + 1))
  fi
}

test_preset_file() {
  local preset="$1"
  info "Testing preset file: $preset"
  local issues=0
  
  # Check for valid syntax (no invalid @include)
  while IFS= read -r line; do
    if [[ "$line" =~ ^@include[[:space:]]+(.+)$ ]]; then
      local include_file="$ROOT_DIR/data/removal-presets/${BASH_REMATCH[1]}.txt"
      if [[ ! -f "$include_file" ]]; then
        err "Invalid @include in $(basename "$preset"): ${BASH_REMATCH[1]}.txt not found"
        issues=$((issues + 1))
      fi
    fi
  done <"$preset"
  
  if [[ $issues -eq 0 ]]; then
    msg "Valid preset file: $(basename "$preset")"
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
}

main() {
  echo "================================"
  echo "Win-Reboot-Project Test Suite"
  echo "================================"
  echo ""
  
  # Test all scripts
  for script in "$ROOT_DIR"/scripts/*.sh; do
    [[ -f "$script" ]] || continue
    echo "--- Testing: $(basename "$script") ---"
    test_syntax "$script"
    test_executable "$script"
    test_shebang "$script"
    test_set_opts "$script"
    
    # Test help flag for main scripts
    if [[ "$(basename "$script")" =~ ^(fetch_iso|tiny11|grub_entry|cleanup)\.sh$ ]]; then
      test_help_flag "$script"
    fi
    echo ""
  done
  
  # Test preset files
  echo "--- Testing preset files ---"
  for preset in "$ROOT_DIR"/data/removal-presets/*.txt; do
    [[ -f "$preset" ]] || continue
    test_preset_file "$preset"
  done
  echo ""
  
  # Test file structure
  echo "--- Testing file structure ---"
  info "Checking directory structure"
  local required_dirs=("scripts" "data" "data/removal-presets")
  for dir in "${required_dirs[@]}"; do
    if [[ -d "$ROOT_DIR/$dir" ]]; then
      msg "Directory exists: $dir"
      PASS=$((PASS + 1))
    else
      err "Directory missing: $dir"
      FAIL=$((FAIL + 1))
    fi
  done
  
  local required_files=("README.md" "INSTALL.md" "LICENSE" "Makefile" ".gitignore")
  for file in "${required_files[@]}"; do
    if [[ -f "$ROOT_DIR/$file" ]]; then
      msg "File exists: $file"
      PASS=$((PASS + 1))
    else
      err "File missing: $file"
      FAIL=$((FAIL + 1))
    fi
  done
  echo ""
  
  # Summary
  echo "================================"
  echo "Test Results"
  echo "================================"
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  echo ""
  
  if [[ $FAIL -eq 0 ]]; then
    msg "All tests passed!"
    exit 0
  else
    err "Some tests failed"
    exit 1
  fi
}

main "$@"
