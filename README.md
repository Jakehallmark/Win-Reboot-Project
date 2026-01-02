# Win-Reboot-Project

Download, customize, and boot Windows 11 from Linux with a single command.

## Quick Start

### Option 1: One-Liner (No Git Clone Required)

```bash
curl -fsSL https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/win11-setup.sh | bash
```

### Option 2: Clone and Run

```bash
git clone https://github.com/Jakehallmark/Win-Reboot-Project.git
cd Win-Reboot-Project
./win11-setup.sh
```

Both methods work identically! The script auto-downloads presets if needed.

## What It Does

1. **Downloads Windows 11** - Fetches official ISO from UUP dump (uupdump.net)
2. **Tiny11 Trimming** (optional) - Removes bloat to reduce ISO size
3. **Sets Up Installer** - Choose GRUB loopback, USB drive, or dedicated disk
4. **Configures Boot** - Automatic GRUB entry or UEFI boot instructions
5. **Reboots to Installer** - Start Windows installation immediately

## Requirements

- **Linux system** (Ubuntu, Debian, Fedora, Arch, Mint supported)
- **Secure Boot disabled** (required for GRUB loopback)
- **20+ GB free disk space**
- **Internet connection** (downloads from Microsoft CDN)

The script auto-installs missing dependencies:
- `aria2c` - Fast parallel downloads
- `wimlib-imagex` - Windows image manipulation
- `xorriso` - ISO creation/extraction
- `parted` / `mkfs.fat` - Disk management (for USB/disk options)

## Three Installation Methods

### Option A: GRUB Loopback (Recommended)
- ✅ Fastest and simplest setup
- ✅ No USB drive needed
- ⚠️ Cannot format the disk containing `/boot` during Windows installation

### Option B: Dedicated Disk
- ✅ Uses another internal drive
- ✅ Can safely wipe all other disks during Windows installation
- ✅ Choose GRUB or Windows bootloader

### Option C: Bootable USB
- ✅ Most flexible option
- ✅ Completely independent from Linux
- ✅ Can safely wipe ALL internal disks during installation

## Tiny11 Trimming Presets

Reduce Windows bloat before installation:

- **minimal** - Remove consumer apps (keep Microsoft Store, Defender, BitLocker)
- **lite** - minimal + remove Windows Help, Media Player, Quick Assist
- **aggressive** - minimal + Photos, Maps, Camera, Calculator, Paint, etc.
- **vanilla** - No modifications (full Windows 11)

## Example Session

```bash
$ ./win11-setup.sh

╔═══════════════════════════════════════════════════════════════╗
║           Win-Reboot-Project: Windows 11 Setup                ║
║        Inspired by the Tiny11 Project by ntdevlabs            ║
╚═══════════════════════════════════════════════════════════════╝

Continue? [y/N]: y

[+] Checking dependencies...
[+] Step 1: Fetch Windows 11 ISO
    Visit: https://uupdump.net
    [File picker opens...]
    
[+] Step 2: Tiny11 trimming (optional)
    Apply Tiny11 trimming? [Y/n]: y
    Preset [minimal/lite/aggressive/vanilla]: minimal
    
[+] Step 3: Installer Media Setup
    Use GRUB loopback? [Y/n]: y
    
[+] Step 4: GRUB Configuration
    [Creates GRUB entry...]
    
[+] Step 5: Reboot
    Reboot now? [y/N]: y
```

## Troubleshooting

**Missing dependencies**
- The script will prompt to auto-install them
- Or install manually for your distro

**"Secure Boot must be disabled"** (GRUB loopback only)
- Restart and enter BIOS/UEFI (usually Del, F2, or F12 at boot)
- Find "Secure Boot" setting and disable it
- USB/Dedicated disk options work with Secure Boot enabled

**GRUB entry not appearing**
- Verify ISO copied: `ls -lh /boot/win11.iso`
- Regenerate GRUB: `sudo grub-mkconfig -o /boot/grub/grub.cfg`

**Want to format Linux disk during Windows install?**
- Use Option B (dedicated disk) or C (USB) instead of GRUB loopback
- Choose "Windows Bootloader" when prompted
- This makes the installer completely independent from Linux

**ISO extraction or WIM mounting fails**
- Ensure 20+ GB free space in `/tmp` or set `TMP_DIR=/path/to/space`
- Check that wimlib-imagex is properly installed

## Project Structure

```
Win-Reboot-Project/
├── win11-setup.sh          # Main script (run this!)
├── README.md               # This file
├── LICENSE                 # License information
├── data/
│   └── removal-presets/    # Tiny11 package removal lists
├── out/                    # Generated ISOs (created automatically)
└── tmp/                    # Temporary files (created automatically)
```

## Credits

Inspired by the excellent [Tiny11 Project](https://github.com/ntdevlabs/tiny11builder) by ntdevlabs.

Windows 11 downloads provided by [UUP dump](https://uupdump.net) (community service).

## License

See [LICENSE](LICENSE) file for details.

## Contributing

This is a simplified, single-script project. For improvements:
1. Test your changes thoroughly
2. Submit pull requests with clear descriptions
3. Keep it simple - the goal is one self-contained script

## Safety Notes

⚠️ **Important Warnings:**
- This tool modifies your boot configuration
- The Windows installer can completely wipe your disks
- **Test in a virtual machine first** if you're unsure
- Always backup important data before proceeding
- Dual-booting requires careful partition management

🔒 **Security:**
- All Windows files download directly from Microsoft CDN
- UUP dump scripts are open source and auditable
- Review the script before running with elevated privileges
