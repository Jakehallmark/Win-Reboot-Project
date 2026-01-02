# Win-Reboot-Project: Windows 11 Setup for Linux

A simplified, all-in-one script to download, customize, and boot Windows 11 from Linux.

## Quick Start

```bash
# Clone and run
git clone https://github.com/Jakehallmark/Win-Reboot-Project.git
cd Win-Reboot-Project
./win11-setup.sh
```

That's it! The script will guide you through:

1. **Download Windows 11** - Fetches ISO from UUP dump (uupdump.net)
2. **Tiny11 Trimming** (optional) - Reduce ISO size by removing bloat
3. **Setup Installer Media** - Choose GRUB loopback, USB, or dedicated disk
4. **Boot Configuration** - Automatic GRUB entry or UEFI boot instructions
5. **Reboot to Installer** - Start Windows installation

## Prerequisites

- **Linux system** (Ubuntu, Debian, Fedora, Arch supported)
- **Secure Boot disabled**
- **20+ GB free space**
- **Internet connection** (for downloading Windows files)

The script will auto-install dependencies if needed:
- `aria2c` - Fast downloads
- `wimlib-imagex` - WIM image manipulation
- `xorriso` - ISO creation
- `parted` / `mkfs.fat` - Disk management (for USB/disk options)

## Features

### Three Installer Options

**Option A: GRUB Loopback** (Recommended)
- Fastest setup
- ISO stays in `/boot`
- Limitation: Can't format disk containing `/boot`

**Option B: Dedicated Disk**
- Uses another internal disk
- Can format all other disks during install
- Choose GRUB or Windows bootloader

**Option C: Bootable USB**
- Most flexible
- Completely independent
- Can format ALL internal disks

### Tiny11 Presets

- **minimal** - Remove consumer apps (keep Store, Defender)
- **lite** - minimal + remove Help, Media Player, Quick Assist
- **aggressive** - minimal + Photos, Maps, Calculator, Paint, etc.
- **vanilla** - No modifications

## Directory Structure

```
Win-Reboot-Project/
├── win11-setup.sh          # Main standalone script (run this!)
├── README.md               # This file
├── out/                    # Generated ISOs
├── tmp/                    # Temporary work files
├── data/
│   └── removal-presets/    # Tiny11 package lists
└── scripts/                # Legacy modular scripts (optional)
```

## Troubleshooting

**"Missing required command"**
- Run the script again, it will offer to auto-install dependencies

**"Secure Boot must be disabled"**
- Enter BIOS/UEFI (Del/F2 at boot)
- Find "Secure Boot" setting
- Set to "Disabled"

**GRUB entry not appearing**
- Verify: `ls /boot/win11.iso`
- Regenerate: `sudo grub-mkconfig -o /boot/grub/grub.cfg`

**Can't format system disk during Windows install**
- Use Option B or C instead of GRUB loopback
- This allows formatting all disks

## Credits

Inspired by the [Tiny11 Project](https://github.com/ntdevlabs/tiny11builder) by ntdevlabs.

## License

See [LICENSE](LICENSE) file.
