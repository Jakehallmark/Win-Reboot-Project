# Win-Reboot-Project

Download, customize, trim, and boot Windows 11 from Linux, macOS, or Windows.

## Quick Start

### Option 1: One-Liner (No Git Clone Required)

```bash
# Works on Linux, macOS, and Git Bash on Windows — auto-detects your platform
curl -fsSL https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/win11-setup.sh | bash
```

### Windows PowerShell One-Liner

```powershell
iwr -UseBasicParsing https://raw.githubusercontent.com/Jakehallmark/Win-Reboot-Project/main/windows-setup.ps1 | iex
```

Run that from the folder where you want `out/` and `tmp/` created.

### Option 2: Clone and Run

```bash
git clone https://github.com/Jakehallmark/Win-Reboot-Project.git
cd Win-Reboot-Project
./win11-setup.sh   # Linux: runs directly | macOS: redirects to macos-setup.sh | Git Bash on Windows: redirects to windows-setup.ps1
```

For native PowerShell on Windows:

```powershell
git clone https://github.com/Jakehallmark/Win-Reboot-Project.git
cd Win-Reboot-Project
powershell -ExecutionPolicy Bypass -File .\windows-setup.ps1
```

Or from `cmd.exe`:

```bat
win11-setup.cmd
```

All entrypoints lead into the same platform-specific workflow.

## Windows Support

Windows 10 and Windows 11 can now run the project natively through PowerShell in an Administrator session.

### Windows Requirements

- **Windows 10 or Windows 11**
- **PowerShell as Administrator**
- **USB drive** — 8 GB minimum, 20 GB recommended
- **20+ GB free disk space**
- **Internet connection** for UUP dump and tiny11builder downloads

### Windows Flow

1. **Downloads Windows 11** - Runs the UUP dump Windows package (`uup_download_windows.cmd`)
2. **Runs Tiny11** (optional) - Downloads `ntdevlabs/tiny11builder` and launches `tiny11maker.ps1` or `tiny11Coremaker.ps1`
3. **Injects drivers properly** - Detects `.inf` driver trees and injects them offline into `boot.wim` and `install.wim` with `DISM`
4. **Creates a proper USB** - Uses native Windows tools (`diskpart`, `DISM`, `robocopy`)
5. **Handles large WIM files** - Splits `install.wim` automatically for FAT32 compatibility

At startup, Windows also offers a **drivers-only** mode that updates an already-created installer USB in place.

## macOS Support

macOS 14 (Sonoma), macOS 15 (Sequoia) and macOS 26 (Tahoe) are supported on both **Apple Silicon (M1/M2/M3/M4)** and **Intel** Macs.

```bash
# Run directly on macOS:
./macos-setup.sh

# Or let win11-setup.sh redirect automatically:
./win11-setup.sh
```

### macOS Requirements

- **Homebrew** — auto-prompted if missing (`aria2`, `wimlib`, `xorriso`, `cabextract`, `p7zip`)
- **USB drive** — 8 GB minimum, 20 GB recommended
- **macFUSE** *(optional)* — enables offline WIM trimming and FUSE-based driver injection. Install from [macfuse.io](https://macfuse.io). Without it, basic USB creation and driver injection (via `wimlib update`) still work.

### Apple Silicon (M-series)

Standard Windows 11 **x64** ISOs cannot boot natively on Apple Silicon. For native ARM boot, select an **ARM64** build when downloading from UUP dump. USB creation works on all Mac architectures regardless.

### Intel Mac Boot

Restart, immediately hold **Option (Alt)**, then select the **WIN11_INST** USB drive from Startup Manager.

**T2 chip (2018+ Intel Macs):** If the USB doesn't appear, boot into macOS Recovery (Cmd+R), open Startup Security Utility, and set "Allow booting from external media" + "Reduced Security".

## What It Does

1. **Downloads Windows 11** - Fetches official media from UUP dump
2. **Tiny11 Trimming** (optional) - Uses best-effort trimming on Linux/macOS and native tiny11builder on Windows
3. **Sets Up Installer** - Choose GRUB loopback, USB drive, or dedicated disk where supported
4. **Configures Boot** - Automatic GRUB entry or native UEFI boot instructions
5. **Reboots / boots to Installer** - Start Windows installation when ready

## Requirements

- **Linux, macOS, or Windows**
- **Secure Boot disabled** (required for GRUB loopback on Linux)
- **20+ GB free disk space**
- **Internet connection** (downloads from Microsoft CDN)

The script auto-installs missing dependencies:
- `aria2c` - Fast parallel downloads
- `wimlib-imagex` - Windows image manipulation
- `xorriso` - ISO creation/extraction
- `parted` / `mkfs.fat` - Disk management (for USB/disk options)

On Windows, the native flow uses built-in tooling:
- `uup_download_windows.cmd` - UUP dump Windows downloader/converter
- `tiny11maker.ps1` / `tiny11Coremaker.ps1` - Native Tiny11 image build
- `DISM` - Image conversion, offline driver injection, and WIM splitting
- `diskpart` / `robocopy` - USB formatting and file copy

For Windows driver archives:
- `.zip` uses PowerShell `Expand-Archive`
- `.cab` uses built-in `expand.exe`
- `.msi` uses built-in `msiexec.exe`
- `.exe` extraction uses `7-Zip` when needed; the script can prompt to install it with `winget`

## Three Installation Methods

### Option A: GRUB Loopback (Experimental — Linux only)
- ✅ Fastest and simplest setup on Linux
- ✅ No USB drive needed
- ⚠️ Cannot format the disk containing `/boot` during Windows installation
- ⚠️ Many systems will not boot Windows 11 via ISO loopback (use B or C instead)

### Option B: Dedicated Disk
- ✅ Uses another internal drive
- ✅ Can safely wipe all other disks during Windows installation
- ✅ Choose GRUB or Windows bootloader

### Option C: Bootable USB
- ✅ Most flexible option
- ✅ Completely independent from Linux
- ✅ Can safely wipe ALL internal disks during installation
- ✅ Native first-class path on macOS and Windows too

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

On Windows, the equivalent flow runs the UUP dump Windows package, optionally launches `tiny11maker.ps1`, and then writes the USB with native Windows tooling.

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

```text
Win-Reboot-Project/
├── win11-setup.sh          # Main bash entry point (Linux + macOS + Git Bash on Windows)
├── win11-setup.cmd         # Native Windows launcher for cmd.exe
├── windows-setup.ps1       # Native Windows PowerShell workflow
├── macos-setup.sh          # macOS-specific setup (Sonoma/Sequoia, M-series + Intel)
├── README.md               # This file
├── LICENSE                 # License information
├── data/
│   └── removal-presets/    # Tiny11 package removal lists
├── drivers/                # Optional: place driver archives/INFs here
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
