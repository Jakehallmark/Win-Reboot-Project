# Driver Injection

Place driver files in this directory for automatic injection into the Windows 11 ISO during media preparation.

## Supported Formats

The script automatically extracts and stages drivers from:
- `*.zip` - Driver archives (extracted via `unzip`)
- `*.cab` - Cabinet archives (extracted via `cabextract`)
- `*.msi` - Installer packages (extracted via `7z` if available)
- `*.exe` - Executable installers (extracted via `7z` if available)
- `*.inf` - Raw INF driver files (copied directly)

## How It Works

1. **Collection**: Drivers are scanned recursively for `.inf` files
2. **Staging**: INF drivers are staged into `sources/$OEM$/$$/INFDRIVERS/` in the ISO tree
3. **Boot Patching**: The WinPE boot.wim is patched to auto-load all staged INF drivers via `drvload` before Setup runs
4. **Installation**: During Windows Setup, drivers are available in WinPE and can be used for storage/network device support

## Usage

### Basic Steps

1. Place driver archives or INF files in this directory:
   ```
   drivers/
   ├── network-driver.zip
   ├── storage-driver.cab
   └── custom-driver.inf
   ```

2. Run the main setup script - driver injection happens automatically during media preparation

### Extracting Tools

For the script to extract drivers, ensure you have:
- `unzip` - for ZIP archives
- `cabextract` - for CAB files
- `7z` (p7zip) - optional, for MSI/EXE extraction

Install missing tools:
```bash
# Ubuntu/Debian
sudo apt-get install unzip cabextract p7zip-full

# Fedora/RHEL
sudo dnf install unzip cabextract p7zip-plugins

# Arch
sudo pacman -S unzip cabextract p7zip
```

## Directory Structure

The script creates nested directories for driver organization:
```
sources/$OEM$/$$/INFDRIVERS/
├── DriverSet1/      (First unique .inf root directory)
├── DriverSet2/      (Second unique .inf root directory)
└── ...
```

## Notes

- **Network Drivers**: Essential for setup to access network resources during installation
- **Storage Drivers**: Required for NVMe/RAID/specialized storage controllers not built into Windows
- **Best Effort**: Extraction is non-critical; if a tool is missing, extraction for that format is skipped
- **WinPE Access**: Drivers are loaded in WinPE (X: drive), making them available during the setup phase
- **Boot Patching**: The startnet.cmd in boot.wim index 2 is patched to auto-run `drvload` for all INF files

## Example: Network Driver from Vendor Zip

```bash
# 1. Download vendor driver package
wget https://vendor.com/drivers/network-driver.zip -O drivers/network-driver.zip

# 2. (Optional) Extract and inspect the contents
unzip -l drivers/network-driver.zip | grep -i "\.inf"

# 3. Run the setup script
./win11-setup.sh
# The driver will be automatically extracted and staged
```

## Troubleshooting

- **No drivers found**: Check that `.inf` files exist inside your driver archives
- **Extraction fails**: Ensure the required extraction tool is installed
- **Drivers not loading in WinPE**: Verify the boot.wim patch was successful (check script output)
- **Setup can't find drivers**: Drivers are at `X:\sources\$OEM$\$$\INFDRIVERS` in WinPE
