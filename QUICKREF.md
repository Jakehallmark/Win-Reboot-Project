# Quick Reference

## One-Command Setup

```bash
./scripts/interactive_setup.sh
```

## Manual Flow

```bash
# 1. Check dependencies
./scripts/check_deps.sh

# 2. Download Windows 11 ISO
./scripts/fetch_iso.sh

# 3. Apply Tiny11 trimming (optional)
./scripts/tiny11.sh out/win11.iso --preset minimal

# 4. Add GRUB entry
sudo ./scripts/grub_entry.sh out/win11.iso

# 5. Reboot to installer
sudo ./scripts/reboot_to_installer.sh
```

## Make Commands

| Command | Description |
|---------|-------------|
| `make status` | Show project status |
| `make check` | Check dependencies |
| `make fetch` | Download ISO |
| `make trim` | Apply Tiny11 trimming |
| `sudo make grub` | Add GRUB entry |
| `sudo make reboot` | Reboot to installer |
| `make test` | Run test suite |
| `make clean` | Clean tmp files |

## Script Options

### fetch_iso.sh
```bash
--lang en-us|en-gb|...     # Language
--edition pro|home|...     # Windows edition
--arch amd64               # Architecture
--channel retail|rp        # Release channel
--update-id <UUID>         # Specific build
--dry-run                  # Show plan only
```

### tiny11.sh
```bash
--preset minimal|lite|aggressive|vanilla
--image-index N            # WIM image index
--custom-list <file>       # Custom removal list
--skip-reg                 # Skip registry tweaks
```

### cleanup.sh
```bash
--iso                      # Remove ISOs
--grub                     # Remove GRUB entry (needs sudo)
--all                      # Remove everything
```

## Presets

| Preset | Size Reduction | Risk |
|--------|---------------|------|
| vanilla | 0% | None |
| minimal | ~5-10% | Low |
| lite | ~15-20% | Medium |
| aggressive | ~20-25% | Higher |

## File Locations

- **Downloaded ISO**: `out/win11.iso`
- **Trimmed ISO**: `out/win11-tiny.iso`
- **Boot ISO**: `/boot/win11.iso`
- **GRUB Entry**: `/etc/grub.d/40_custom_win11`
- **Temporary Files**: `tmp/`

## Common Tasks

### Check project status
```bash
./scripts/status.sh
# OR
make status
```

### Download specific build
```bash
./scripts/fetch_iso.sh --update-id <UUID>
```

### Use aggressive trimming
```bash
./scripts/tiny11.sh out/win11.iso --preset aggressive
```

### Cleanup after installation
```bash
sudo ./scripts/cleanup.sh --all
```

### Test everything
```bash
./scripts/test.sh
```

## Troubleshooting Quick Fixes

### ISO download fails
```bash
# Check connectivity
curl -I https://uupdump.net

# Try dry run first
./scripts/fetch_iso.sh --dry-run
```

### GRUB entry not showing
```bash
# Verify file exists
ls -la /etc/grub.d/40_custom_win11

# Manually regenerate
sudo grub-mkconfig -o /boot/grub/grub.cfg

# Check for entry
grep -A5 "Windows 11" /boot/grub/grub.cfg
```

### Out of space
```bash
# Check space
df -h /boot
df -h $HOME

# Clean up
./scripts/cleanup.sh
./scripts/cleanup.sh --iso
```

### Missing dependencies
```bash
# Check what's missing
./scripts/check_deps.sh

# Ubuntu/Debian
sudo apt install aria2 cabextract wimtools p7zip-full

# Fedora
sudo dnf install aria2 cabextract wimlib-utils p7zip

# Arch
sudo pacman -S aria2 cabextract wimlib p7zip
```

## Safety Reminders

- ⚠️ **Secure Boot must be disabled**
- ⚠️ **Test in VM first**
- ⚠️ **Backup important data**
- ⚠️ **Double-check disk selection in Windows installer**
- ⚠️ **GRUB changes affect all OS boots**

## Getting Help

1. Check [INSTALL.md](INSTALL.md) for detailed guide
2. Run `./scripts/status.sh` to see current state
3. Open an issue on GitHub with error details
