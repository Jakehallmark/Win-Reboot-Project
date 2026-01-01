# Installation Guide

This guide walks through the complete installation process for Win-Reboot-Project.

## Prerequisites Check

Before starting, verify your system meets the requirements:

### System Requirements
- **Linux distribution** with GRUB bootloader
- **UEFI firmware** (BIOS mode not supported for loopback)
- **Secure Boot disabled** (required for GRUB chainloading)
- **~15-20 GB free disk space**
  - `~/Win-Reboot-Project/out`: 5-6 GB (ISO storage)
  - `~/Win-Reboot-Project/tmp`: 8-10 GB (temporary working files)
  - `/boot`: 5-6 GB (installer ISO copy)

### Required Packages

Run the dependency checker:
```bash
./scripts/check_deps.sh
```

#### Debian/Ubuntu/Linux Mint
```bash
sudo apt update
sudo apt install -y aria2 cabextract wimtools genisoimage p7zip-full grub-common curl python3 unzip
```

#### Fedora/RHEL/CentOS/Rocky
```bash
sudo dnf install -y aria2 cabextract wimlib-utils genisoimage p7zip p7zip-plugins grub2-tools curl python3 unzip
```

#### Arch/Manjaro
```bash
sudo pacman -S aria2 cabextract wimlib cdrtools p7zip grub curl python3
```

#### Optional (for registry tweaks)
```bash
# Debian/Ubuntu
sudo apt install libhivex-bin

# Fedora/RHEL
sudo dnf install hivex

# Arch
sudo pacman -S hivex
```

## Installation Methods

### Method 1: Interactive Setup (Recommended)

The easiest way to get started:

```bash
make interactive
# OR
./scripts/interactive_setup.sh
```

This will guide you through all steps with prompts.

### Method 2: Manual Step-by-Step

For more control over the process:

#### Step 1: Download Windows 11 ISO
```bash
# Download latest retail build (default: Professional, x64, en-us)
./scripts/fetch_iso.sh

# Custom options
./scripts/fetch_iso.sh --lang en-gb --edition home --arch amd64

# Dry run to see what would be downloaded
./scripts/fetch_iso.sh --dry-run
```

Output: `out/win11.iso` (~5-6 GB)

#### Step 2: Apply Tiny11 Trimming (Optional)
```bash
# Minimal preset (recommended, conservative removals)
./scripts/tiny11.sh out/win11.iso --preset minimal

# Lite preset (more aggressive)
./scripts/tiny11.sh out/win11.iso --preset lite

# Aggressive preset (maximum removal)
./scripts/tiny11.sh out/win11.iso --preset aggressive

# Skip modifications
./scripts/tiny11.sh out/win11.iso --preset vanilla

# Custom removal list
./scripts/tiny11.sh out/win11.iso --custom-list /path/to/custom.txt
```

Output: `out/win11-tiny.iso`

#### Step 3: Add GRUB Entry
```bash
# Add GRUB menu entry (requires root)
sudo ./scripts/grub_entry.sh out/win11.iso

# Custom destination
sudo ./scripts/grub_entry.sh out/win11.iso --dest /boot/custom-win11.iso
```

This will:
- Copy ISO to `/boot/win11.iso`
- Create `/etc/grub.d/40_custom_win11`
- Regenerate `/boot/grub/grub.cfg`

#### Step 4: Reboot to Installer
```bash
# Reboot immediately (requires root)
sudo ./scripts/reboot_to_installer.sh

# OR reboot manually
sudo reboot
```

At the GRUB menu, select **"Windows 11 installer (ISO loop)"**

### Method 3: Using Make

```bash
# Check dependencies
make check

# Download ISO
make fetch

# Apply Tiny11 trimming
make trim

# Add GRUB entry and reboot
sudo make grub
sudo make reboot
```

## Preset Comparison

| Preset | Size Reduction | Apps Removed | Risk Level |
|--------|---------------|--------------|------------|
| vanilla | 0% | None | None |
| minimal | ~5-10% | Bloatware (Xbox, Cortana, etc.) | Low |
| lite | ~15-20% | Bloatware + Recovery + Help | Medium |
| aggressive | ~20-25% | Bloatware + More system apps | Higher |

**Recommendation**: Start with `minimal` for maximum compatibility.

## Verification Steps

### Before GRUB Changes

1. Verify ISO integrity:
```bash
ls -lh out/win11.iso
# Should be ~5-6 GB

# Check ISO structure
7z l out/win11.iso | grep -E "(boot|efi|sources)"
```

2. Mount and inspect (optional):
```bash
mkdir -p /tmp/iso_mount
sudo mount -o loop out/win11.iso /tmp/iso_mount
ls -la /tmp/iso_mount/sources/
sudo umount /tmp/iso_mount
```

### After GRUB Changes

1. Verify GRUB entry exists:
```bash
grep -A 5 "Windows 11 installer" /boot/grub/grub.cfg
```

2. Check GRUB syntax:
```bash
sudo grub-script-check /etc/grub.d/40_custom_win11
```

## Troubleshooting

### ISO Download Fails
- Check internet connection
- Verify UUP dump is accessible: `curl -I https://uupdump.net`
- Try with `--dry-run` first to see build ID

### GRUB Entry Not Appearing
- Verify `/boot/win11.iso` exists
- Check `/etc/grub.d/40_custom_win11` permissions (should be executable)
- Manually regenerate: `sudo grub-mkconfig -o /boot/grub/grub.cfg`

### Chainload Fails (Black Screen)
- **Secure Boot must be disabled** (most common issue)
- Check UEFI settings: Boot mode must be UEFI, not Legacy
- Verify ISO path in GRUB config matches actual location
- Try alternative boot method (not implemented): wimboot/iPXE

### Out of Disk Space
- Clean temporary files: `./scripts/cleanup.sh`
- Remove old ISOs: `./scripts/cleanup.sh --iso`
- Check available space: `df -h /boot` and `df -h $HOME`

### Tiny11 Trimming Fails
- Ensure `wimlib-imagex` is installed
- Check tmp/ has enough space (~10 GB)
- Try with `--preset vanilla` to skip trimming

## Cleanup

### Remove Temporary Files
```bash
make clean
# OR
./scripts/cleanup.sh
```

### Remove Everything (Including GRUB Entry)
```bash
make clean-all
# OR
sudo ./scripts/cleanup.sh --all
```

### Remove Only GRUB Entry
```bash
sudo ./scripts/cleanup.sh --grub
```

## Security Considerations

1. **Secure Boot**: Must be disabled for GRUB loopback chainloading
2. **Source Verification**: ISOs are downloaded directly from Microsoft CDN via UUP dump
3. **Backup**: Always backup important data before modifying bootloader
4. **VM Testing**: Test the full flow in a virtual machine first
5. **GRUB Modification**: Changes are system-wide and affect all OS boots

## Next Steps After Installation

Once Windows 11 is installed:

1. Re-enable Secure Boot if desired (after Windows setup)
2. Remove GRUB entry: `sudo ./scripts/cleanup.sh --grub`
3. Clean up project files: `./scripts/cleanup.sh --all`
4. Configure Windows 11 according to your preferences

## Advanced Usage

### Custom Build ID
```bash
# Use specific Windows build
./scripts/fetch_iso.sh --update-id <UUID from uupdump.net>
```

### Custom Removal List
Create `my-removals.txt`:
```
# My custom removals
@include minimal
Program Files/Custom/App/*
```

Apply:
```bash
./scripts/tiny11.sh out/win11.iso --custom-list my-removals.txt
```

### Multiple Windows Versions
```bash
# Download multiple editions
./scripts/fetch_iso.sh --edition professional,home,enterprise

# Keep multiple ISOs in /boot with different names
sudo ./scripts/grub_entry.sh out/win11-pro.iso --dest /boot/win11-pro.iso
sudo ./scripts/grub_entry.sh out/win11-home.iso --dest /boot/win11-home.iso
```

## Support

- **Issues**: https://github.com/Jakehallmark/Win-Reboot-Project/issues
- **UUP Dump**: https://uupdump.net
- **Tiny11 Reference**: https://github.com/ntdevlabs/tiny11builder
