Win-Reboot-Project
==================

**Version 1.0.0**

Tooling to download a fresh, official Windows 11 ISO from Microsoft via UUP dump, optionally apply Tiny11-style trimming on Linux, and add a GRUB menu entry to boot straight into the installer (no USB). Secure Boot must be off for the GRUB loopback flow.

Status
------
- Scripts are scaffolded; no binaries vendored. Downloads come directly from Microsoft CDN through the UUP dump helper.
- Use in a VM first. This workflow modifies your bootloader and preps an on-disk installer that can wipe the machine.

Prerequisites (host)
--------------------
- Linux with GRUB and UEFI (Secure Boot disabled for loopback chainload).
- ~15 GB free space (`~/Win-Reboot-Project/out` + `/boot/win11.iso`).
- Packages (auto-detected in scripts but install as needed):
  - Debian/Ubuntu: `aria2 cabextract wimtools genisoimage p7zip-full grub-common`
  - Fedora/RHEL: `aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools`
  - Arch: `aria2 cabextract wimlib cdrtools p7zip grub`
- Network access to Microsoft CDN and GitHub (for UUP dump helper).

High-level flow
---------------
1. `scripts/fetch_iso.sh` — Resolve latest public Win11 GA build, download/build ISO via UUP dump, store at `out/win11.iso`.
2. `scripts/tiny11.sh` — Optional interactive trimming of `install.wim/install.esd` using wimlib with presets (minimal/lite/vanilla).
3. `scripts/grub_entry.sh` — Copy ISO to `/boot/win11.iso`, add GRUB menu entry to chainload the installer, regenerate grub.cfg.
4. `scripts/reboot_to_installer.sh` — Sanity checks and reboot into the new GRUB entry.

Tiny11 references
-----------------
- Based on `ntdevlabs/tiny11builder` PowerShell flow; this repo does not ship their scripts.
- Presets live in `data/removal-presets/*.txt` and are intentionally conservative to keep OOBE/activation working.
- Uses `wimlib-imagex mount` to edit the image and optional registry tweaks via `hivexregedit`/`reged`.

Safety notes
------------
- Do not run on production machines without a tested backup/restore plan.
- Double-check `/etc/default/grub` and target disk; GRUB edits are host-wide.
- Secure Boot must be disabled for the GRUB chainloader. If chainload fails, consider wimboot/iPXE as a fallback (not implemented here).

Quickstart
----------
```bash
# Interactive mode (recommended for first-time users)
./scripts/interactive_setup.sh

# OR Manual step-by-step:

# 0) Check dependencies
./scripts/check_deps.sh

# 1) Download latest public Win11 ISO (Retail, x64, en-US by default)
./scripts/fetch_iso.sh

# 2) Optional: apply Tiny11-style trimming with prompts
./scripts/tiny11.sh out/win11.iso --preset minimal

# 3) Add GRUB entry (copies ISO to /boot/win11.iso) and regenerate grub.cfg
sudo ./scripts/grub_entry.sh out/win11.iso

# 4) Reboot into installer (after reviewing grub.cfg)
sudo ./scripts/reboot_to_installer.sh

# OR using Make:
make check && make fetch && make trim && sudo make grub
```

Testing / dry runs
------------------
- `scripts/fetch_iso.sh --dry-run` will show the build ID and download plan.
- `grub_entry.sh` uses `grub-script-check` when available before touching grub.cfg.
- Consider mounting `out/win11.iso` and `boot.wim` with 7z/wimlib to verify structure before GRUB changes.

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
- [data/removal-presets/](data/removal-presets/) - Tiny11 removal preset files

Next steps (development)
------------------------
- Add distro-specific Secure Boot guidance and wimboot fallback
- Test on more Linux distributions
- Add support for Windows 10 ISOs
- Implement alternative boot methods (wimboot/iPXE)
