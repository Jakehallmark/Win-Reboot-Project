Win-Reboot-Project
==================

**Version 1.0.0**

A collection of tools to download a fresh Windows 11 ISO from Microsoft (via UUP dump), optionally trim it down Tiny11-style on Linux, and add a GRUB menu entry so you can boot straight into the installer without needing a USB drive. Note that Secure Boot needs to be disabled for the GRUB loopback method to work.

Status
------
- All scripts are ready to use. No binaries are included - everything downloads directly from Microsoft's CDN through the UUP dump helper.
- Comprehensive error handling with automatic cleanup and detailed troubleshooting guidance.
- Try this in a VM first. This setup modifies your bootloader and sets up an on-disk installer that can completely wipe your machine.

Prerequisites
-------------
- Linux with GRUB and UEFI (Secure Boot must be disabled for loopback chainloading)
- About 15 GB free space for `~/Win-Reboot-Project/out` and `/boot/win11.iso`
- GUI file picker (zenity or kdialog) for interactive file selection, or fallback to text input
- Required packages (scripts will check for these, but you'll need to install them):
  - Debian/Ubuntu: `aria2 cabextract wimtools genisoimage p7zip-full grub-common python3 python3-hivex unzip curl chntpw`
  - Fedora/RHEL: `aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools python3 hivex unzip curl chntpw`
  - Arch: `aria2 cabextract wimlib cdrtools p7zip grub python3 hivex unzip curl chntpw`
- Internet access to reach Microsoft's CDN, UUP dump, and GitHub

How it works
------------
1. **Interactive Setup** (`scripts/interactive_setup.sh`) guides you through:
   - Directing you to https://uupdump.net to select your preferred Windows 11 build, language, and edition
   - Opening a file picker dialog to select your downloaded UUP dump ZIP file
   - Extracting and running the UUP dump conversion script to build the ISO
   - Saving the result to `out/win11.iso`
2. `scripts/tiny11.sh` (optional) trims down `install.wim/install.esd` using wimlib with your choice of presets (minimal, lite, aggressive, or vanilla)
3. `scripts/grub_entry.sh` copies the ISO to `/boot/win11.iso`, adds a GRUB menu entry to chainload the installer, and regenerates grub.cfg
4. `scripts/reboot_to_installer.sh` does some sanity checks and reboots into the new GRUB entry

Tiny11 Attribution
------------------
This project is inspired by and based on the excellent work of the [Tiny11 Project](https://github.com/ntdevlabs/tiny11builder) by ntdevlabs.

Kudos to ntdevlabs for their pioneering work in creating lightweight, bloat-free Windows 11 installations. Their Tiny11Builder provided the foundation and methodology that made this Linux-based implementation possible.

### Our Implementation
- Adapts the Tiny11Builder PowerShell workflow to pure bash for Linux systems
- Uses `wimlib-imagex` for WIM manipulation instead of DISM
- Presets in `data/removal-presets/*.txt` are inspired by Tiny11's conservative approach
- Maintains OOBE/activation compatibility through careful component selection
- Implements registry tweaks for TPM/Secure Boot bypass similar to Tiny11's methods

### Key Differences
- **Platform**: Linux native (bash) vs Windows (PowerShell)
- **Distribution**: GRUB chainload vs USB/ISO boot
- **Automation**: Full CLI automation with interactive mode

**Please visit and support the original Tiny11 project**: https://github.com/ntdevlabs/tiny11builder

Safety notes
------------
- Don't run this on a production machine unless you have a solid backup and restore plan.
- Double-check `/etc/default/grub` and your target disk. GRUB changes affect the entire system.
- Secure Boot must be disabled for the GRUB chainloader to work. If chainloading fails, you might want to look into wimboot or iPXE as alternatives (though those aren't implemented here yet).

Quick Install
-------------

Run this one-liner to download and launch the interactive setup (no git clone needed):

```bash
curl -fsSL https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/install.sh | bash
```

Or if you prefer wget:

```bash
wget -qO- https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/install.sh | bash
```

This will clone the repo to `~/Win-Reboot-Project` and launch the interactive setup.

Usage
-----

**Interactive Mode (Recommended):**
```bash
# This is the easiest way - it guides you through everything
./scripts/interactive_setup.sh
```

The interactive setup will:
1. Check and install dependencies
2. Direct you to https://uupdump.net
3. Ask you to download a Windows 11 build ZIP
4. Show a file picker to select your downloaded ZIP
5. Build the ISO from the ZIP
6. Optionally apply Tiny11 trimming
7. Configure GRUB (with sudo)
8. Offer to reboot into the installer

**Manual Step-by-Step (if you prefer):**
```bash
# 0) Check/install dependencies
./scripts/check_deps.sh --auto-install

# 1) Download ISO
#    Visit https://uupdump.net, select build/language/edition, download the ZIP
#    Then run interactive_setup.sh and select the ZIP file

# 2) Optional: Apply Tiny11-style trimming
./scripts/tiny11.sh out/win11.iso --preset minimal

# 3) Add GRUB entry (requires sudo)
sudo ./scripts/grub_entry.sh out/win11.iso

# 4) Reboot into installer
sudo ./scripts/reboot_to_installer.sh
```

**Using Make:**
```bash
make check          # Check dependencies
make install        # Run interactive setup
make trim           # Apply Tiny11 trimming
sudo make grub      # Add GRUB entry
sudo make reboot    # Reboot to installer
```

Testing & Verification
----------------------
- The `grub_entry.sh` script uses `grub-script-check` (when available) before modifying grub.cfg
- You might want to mount `out/win11.iso` and check `boot.wim` with `7z` or `wimlib` to verify everything looks right before making GRUB changes
- If you need to re-download or use a different build, simply run `./scripts/interactive_setup.sh` again

Available scripts
-----------------
- **fetch_iso.sh** - Download Windows 11 ISO from Microsoft via UUP dump
- **tiny11.sh** - Apply Tiny11-style trimming to reduce ISO size
- **grub_entry.sh** - Add GRUB bootloader entry for the installer
- **reboot_to_installer.sh** - Reboot directly to the Windows installer
- **check_deps.sh** - Verify all required dependencies are installed
- **interactive_setup.sh** - Guided setup wizard (recommended for new users)
- **cleanup.sh** - Remove temporary files and optionally GRUB entries

Cleanup
-------
```bash
# Clean temporary files only
./scripts/cleanup.sh

# Remove ISOs from out/ directory
./scripts/cleanup.sh --iso

# Remove GRUB entry (requires root)
sudo ./scripts/cleanup.sh --grub

# Remove everything
sudo ./scripts/cleanup.sh --all
```

Documentation
-------------
- [INSTALL.md](INSTALL.md) - Comprehensive installation guide
- [QUICKREF.md](QUICKREF.md) - Quick reference card
- [CREDITS.md](CREDITS.md) - Credits and acknowledgments
- [data/removal-presets/](data/removal-presets/) - Tiny11 removal preset files

Credits & Acknowledgments
-------------------------
**Tiny11 Project** - https://github.com/ntdevlabs/tiny11builder
- Created by ntdevlabs
- Original concept and methodology for Windows 11 debloating
- Inspiration for this Linux implementation

**UUP Dump** - https://uupdump.net
- Community-driven Windows update retrieval service
- Enables direct downloads from Microsoft CDN

**wimlib** - https://wimlib.net
- Cross-platform WIM manipulation library
- Essential for Linux-based Windows image editing

Next steps (development)
------------------------
- Add distro-specific Secure Boot guidance and wimboot fallback
- Test on more Linux distributions
- Add support for Windows 10 ISOs
- Implement alternative boot methods (wimboot/iPXE)
