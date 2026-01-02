# Installer Media Setup Options

## Overview

The new `setup_installer_media.sh` script provides **three flexible options** for setting up your Windows 11 installer, replacing the simple GRUB loopback approach.

This allows you to safely wipe **all drives** during Windows installation, rather than being constrained by the location of the ISO.

## Option 1: Resize Current Disk (10GB Partition)

**What it does:**
- Creates a new 10GB partition on your current Linux drive
- Copies the ISO to this partition
- Sets up a GRUB entry to boot from this partition

**Pros:**
- No additional hardware needed
- Uses existing storage space

**Cons:**
- Requires shrinking LVM/filesystem (complex and risky)
- **Not yet fully implemented** (marked for future enhancement)
- Still keeps partition on main disk during installation

**When to use:** Advanced users only, not recommended

---

## Option 2: Use Another Internal Disk

**What it does:**
- Detects other internal disks on your system
- Formats the selected disk completely (FAT32)
- Copies the ISO to that disk
- Creates a GRUB entry to boot from it

**Pros:**
- ✅ Can safely format **all other disks** during Windows installation
- Works with existing GRUB setup
- No USB drive needed
- Clean separation of installer and system

**Cons:**
- Requires having a spare internal disk
- That disk will be formatted

**When to use:** You have 2+ internal drives (your setup!)

**Example:**
```
You have: nvme1n1 (Linux) + nvme0n1 (spare)
Result:   Put Windows installer on nvme0n1, wipe nvme1n1 freely
```

---

## Option 3: Bootable USB

**What it does:**
- Detects USB drives with sufficient space (10GB+)
- Writes ISO directly to USB device (making it bootable)
- USB becomes a standalone Windows installer

**Pros:**
- ✅ Completely independent from internal disks
- ✅ Can safely format **all internal disks** during Windows installation
- Most flexible option
- Can reuse USB for future Windows installations

**Cons:**
- Requires a USB drive with 10GB+ capacity
- Takes longer than copying to disk (DD write is slower)
- USB drive is fully consumed (not usable for other things)

**When to use:** You want maximum flexibility or don't have a spare internal disk

---

## Default (Legacy): GRUB Loopback

If you select "Use simple GRUB loopback setup", the script falls back to the original behavior:

**What it does:**
- Copies ISO to `/boot/win11.iso`
- Chainloads into Windows bootloader via GRUB
- ISO runs from your current disk

**Limitations:**
- ⚠️ Cannot format the disk containing `/boot` during installation
- ⚠️ Can only safely format other disks
- Still requires GRUB to be present

---

## Comparison Table

| Feature | Option 1 | Option 2 | Option 3 | Default |
|---------|----------|----------|----------|---------|
| No extra hardware | ✅ | ❌ | ❌ | ✅ |
| Can wipe all disks | ❌ | ✅ | ✅ | ❌ |
| Works on all systems | ❌ | ⚠️ | ✅ | ✅ |
| Setup complexity | Hard | Easy | Easy | Very Easy |
| Risk level | High | Medium | Low | Low |
| Implementation status | ⏳ Planned | ✅ Working | ✅ Working | ✅ Working |

---

## How to Use

### During Interactive Setup

1. **Step 1-2:** Download and optionally trim ISO (same as before)

2. **Step 3 - Media Setup:**
   ```
   Choose how to boot the Windows installer:
   
   Option A) GRUB loopback (simple, installer runs from /boot)
   Option B) Dedicated partition/disk (more flexible)
   Option C) Bootable USB (most flexible)
   ```

3. Select your preferred option and follow prompts

4. The script handles all formatting, partition creation, and ISO copying

### Standalone Usage

```bash
# Manually set up media for an existing ISO
sudo ./scripts/setup_installer_media.sh /path/to/win11.iso
```

---

## Your Hardware

Your system has optimal hardware for Option 2:

```
nvme1n1 (465.8G) - Your Linux system
nvme0n1 (465.8G) - Currently has some btrfs data

Recommended:
Put Windows installer on nvme0n1 (can wipe during install)
Keep nvme1n1 for Linux or wipe it too
```

---

## Safety Considerations

⚠️ **All options ask for confirmation before proceeding**

- Option 1: Requires filesystem shrinking confirmation
- Option 2: Shows "WARNING: This will completely format [disk]"
- Option 3: Warns "This will completely erase [device]"

**Best practice:** Know your partition layout before running:
```bash
lsblk  # Review this output before proceeding
```

---

## Troubleshooting

### "No removable USB devices detected"
- Plug in a USB drive (10GB+)
- Wait 2-3 seconds for Linux to recognize it
- Try again

### "Insufficient space available"
- Option 2 requires the target disk to be at least 10GB
- Plug in larger USB or use different disk

### Media setup completes but GRUB doesn't show new entry
- Option 2/3 creates new GRUB entry automatically
- If missing, regenerate manually:
  ```bash
  sudo grub-mkconfig -o /boot/grub/grub.cfg
  ```

### Windows installer won't boot from new media
- Verify you selected correct device in BIOS/UEFI
- Ensure Secure Boot is disabled
- Check GRUB entry created correctly: `cat /etc/grub.d/40_custom_win11`

---

## Future Enhancements

Option 1 (resize current disk) is partially implemented but disabled:
- Requires safe LVM shrinking
- Complex fallback logic needed
- Marked for future improvement when more robust partition tools are available

Current recommendation: Use Option 2 or 3 instead
