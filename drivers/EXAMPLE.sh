#!/usr/bin/env bash
# Driver Injection Example Usage

# BEFORE: Place drivers in the drivers/ directory
# Example structure:
#
# drivers/
# ├── README.md                          (usage guide)
# ├── intel-network-driver.zip           (will be extracted)
# ├── amd-chipset-driver.cab             (will be extracted)
# ├── samsung-nvme-driver.exe            (will be extracted)
# └── custom-storage-driver.inf          (copied directly)

# The script automatically:
# 1. Extracts all archives using appropriate tools
# 2. Scans for .inf files in all locations
# 3. Stages drivers into the ISO tree
# 4. Patches boot.wim to auto-load drivers in WinPE

# RESULTING ISO STRUCTURE (after driver injection):
#
# sources/
# └── $OEM$/
#     └── $$/
#         └── INFDRIVERS/
#             ├── DriverSet1/        (first unique driver root)
#             │   ├── driver1.inf
#             │   ├── driver1.sys
#             │   ├── driver1.cat
#             │   └── ... (supporting files)
#             ├── DriverSet2/        (second unique driver root)
#             │   ├── driver2.inf
#             │   └── ... (supporting files)
#             └── ...

# DURING WINPE BOOT:
#
# boot.wim is patched so that startnet.cmd now:
# 1. Runs wpeinit (standard WinPE init)
# 2. Auto-loads all .inf drivers from X:\sources\$OEM$\$$\INFDRIVERS\
#    using: drvload "X:\sources\$OEM$\$$\INFDRIVERS\DriverSetN\driver.inf"
# 3. Launches setup.exe with drivers ready
#
# This makes drivers available for:
# - Network access during setup
# - Storage controller support
# - Other hardware devices

# USAGE:
#
# Step 1: Prepare drivers
#   mkdir -p drivers
#   cp /path/to/your/drivers/* drivers/
#
# Step 2: Run the setup script (driver injection is automatic)
#   ./win11-setup.sh
#
# Step 3: Select your media setup (USB or disk)
#   The drivers will be automatically injected during media prep
