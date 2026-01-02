# Driver Injection Implementation Summary

## Overview

Driver injection has been successfully integrated into the Win-Reboot-Project setup script. This allows users to automatically inject device drivers (network, storage, etc.) into the Windows 11 installation media.

## What Was Added

### 1. **Driver Injection Functions** (in win11-setup.sh)

- **`require_extractors_for_drivers()`** - Ensures required utilities are available
- **`extract_any_driver_payloads()`** - Extracts drivers from various formats:
  - `.zip` archives (via unzip)
  - `.cab` files (via cabextract)
  - `.msi` packages (via 7z)
  - `.exe` executables (via 7z)
  - `.inf` files (copied directly)

- **`collect_inf_roots()`** - Finds all directories containing .inf driver files
- **`stage_inf_drivers_into_tree()`** - Copies drivers to the ISO tree at `sources/$OEM$/$$/INFDRIVERS/`
- **`patch_boot_wim_to_drvload_oem_drivers()`** - Modifies WinPE boot.wim to auto-load drivers via drvload
- **`inject_drivers_into_iso_tree()`** - Main orchestration function that coordinates all steps

### 2. **Integration Point**

The `inject_drivers_into_iso_tree()` function is called automatically in:
- `prepare_iso_tree_for_copy_media()` - called during USB/disk setup

This means drivers are injected right after:
1. Copying ISO contents to writable tree
2. Converting ESD to WIM (if needed)
3. Splitting WIM for FAT32 compatibility (if needed)

### 3. **Directory Structure**

- **`/drivers/`** - New directory for user to place driver files
- **`/drivers/README.md`** - Complete documentation on using driver injection

## How It Works

### User Flow

1. Place driver files in the `./drivers/` directory:
   ```
   drivers/
   ├── network-driver.zip
   ├── storage-driver.cab
   └── custom.inf
   ```

2. Run the setup script normally - driver injection happens automatically

3. During media preparation, the script:
   - Extracts driver archives
   - Finds all .inf files
   - Stages them in the ISO tree at `sources/$OEM$/$$/INFDRIVERS/DriverSet1/`, etc.
   - Patches boot.wim to auto-load drivers in WinPE

### Boot Flow

When Windows boots from the media:
1. WinPE loads from boot.wim
2. startnet.cmd runs (patched to include drvload)
3. For each .inf in `X:\sources\$OEM$\$$\INFDRIVERS\`:
   - `drvload` loads the driver
4. Setup.exe launches with drivers ready

## Dependencies

Optional extraction tools (warn if missing, skip that format):
- `unzip` - for ZIP archives
- `cabextract` - for CAB files
- `7z` (p7zip) - for MSI/EXE extraction
- `wimlib-imagex` - already required by script

All tools are checked during dependency validation in the script.

## Key Features

✅ **Automatic extraction** - Handles multiple driver package formats  
✅ **Best-effort** - Missing tools skip that format, don't fail the whole process  
✅ **Clean staging** - Drivers organized as DriverSet1, DriverSet2, etc.  
✅ **Boot integration** - Seamlessly patches WinPE to load drivers  
✅ **Non-intrusive** - Only activates if drivers directory exists with driver files  

## Configuration

The drivers directory path can be overridden:
```bash
DRIVERS_DIR=/custom/path/to/drivers ./win11-setup.sh
```

Default: `$ROOT_DIR/drivers` (relative to script)

## Testing

To verify driver injection works:
1. Place a test driver archive in `./drivers/`
2. Run the script through media setup
3. Check script output for:
   ```
   [+] Collecting driver payloads from: /path/to/drivers
   [+] Staged N INF driver set(s) to sources/$OEM$/$$/INFDRIVERS
   [+] Patching boot.wim (index 2) to auto-load INF drivers in WinPE...
   [+] ✓ Driver injection complete (WinPE will drvload all staged INFs).
   ```

## Files Modified

- **win11-setup.sh** - Added ~200 lines of driver injection code
- **drivers/README.md** - Created detailed user documentation

## Notes

- Drivers are available in WinPE at: `X:\sources\$OEM$\$$\INFDRIVERS\`
- Common use cases: Network drivers, NVMe/RAID storage drivers
- The original boot.wim is backed up as `startnet.cmd.orig` inside the mounted image
