Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = $null
if ($MyInvocation -and $MyInvocation.MyCommand) {
    $pathProperty = $MyInvocation.MyCommand.PSObject.Properties["Path"]
    if ($pathProperty) {
        $scriptPath = $pathProperty.Value
    }
}

if ([string]::IsNullOrWhiteSpace($scriptPath)) {
    $Script:RootDir = (Get-Location).Path
} else {
    $Script:RootDir = Split-Path -Parent $scriptPath
}

$Script:TmpDir = Join-Path $Script:RootDir "tmp"
$Script:OutDir = Join-Path $Script:RootDir "out"
$Script:IsoPath = Join-Path $Script:OutDir "win11.iso"
$Script:DriversDir = Join-Path $Script:RootDir "drivers"
$Script:InstallerVolLabel = "WIN11_INST"
$Script:WimSplitMb = 3800
$Script:Tiny11ZipUrl = "https://github.com/ntdevlabs/tiny11builder/archive/refs/heads/main.zip"

New-Item -ItemType Directory -Force -Path $Script:TmpDir, $Script:OutDir | Out-Null

function Write-Msg {
    param([string]$Message)
    Write-Host "[+] $Message"
}

function Write-WarnMsg {
    param([string]$Message)
    Write-Warning $Message
}

function Fail {
    param([string]$Message)
    throw $Message
}

function Prompt-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Prompt $suffix"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return $answer.Trim().ToLowerInvariant() -eq "y"
}

function Prompt-Choice {
    param(
        [string]$Prompt,
        [string[]]$Choices,
        [int]$DefaultIndex = 0
    )

    while ($true) {
        for ($i = 0; $i -lt $Choices.Count; $i++) {
            Write-Host ("  {0}) {1}" -f ($i + 1), $Choices[$i])
        }

        $raw = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Choices[$DefaultIndex]
        }

        $choiceNumber = 0
        if ([int]::TryParse($raw, [ref]$choiceNumber)) {
            if ($choiceNumber -ge 1 -and $choiceNumber -le $Choices.Count) {
                return $Choices[$choiceNumber - 1]
            }
        }

        Write-WarnMsg "Invalid selection. Please try again."
    }
}

function Assert-Windows {
    if ($env:OS -ne "Windows_NT") {
        Fail "This script must be run on Windows."
    }
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "Run this PowerShell session as Administrator."
    }
}

function Assert-Command {
    param([string[]]$Names)

    foreach ($name in $Names) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            Fail "Missing required command: $name"
        }
    }
}

function Test-CommandExists {
    param([string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-DriveLetterFromPath {
    param([string]$Path)

    $resolved = (Resolve-Path $Path).Path
    return ([System.IO.Path]::GetPathRoot($resolved)).TrimEnd('\').TrimEnd(':')
}

function Invoke-External {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $Script:RootDir
    )

    $argText = if ($Arguments.Count -gt 0) { $Arguments -join " " } else { "" }
    $display = ("Running: {0} {1}" -f $FilePath, $argText).Trim()
    Write-Msg $display

    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        Fail ("Command failed with exit code {0}: {1}" -f $process.ExitCode, $FilePath)
    }
}

function Invoke-ExternalCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @()
    )

    $argText = if ($Arguments.Count -gt 0) { $Arguments -join " " } else { "" }
    $display = ("Running: {0} {1}" -f $FilePath, $argText).Trim()
    Write-Msg $display

    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        if ($output) {
            $output | ForEach-Object { Write-WarnMsg "$_" }
        }
        Fail ("Command failed with exit code {0}: {1}" -f $exitCode, $FilePath)
    }

    return @($output)
}

function Get-LatestFile {
    param(
        [string]$SearchRoot,
        [string]$Filter
    )

    $match = Get-ChildItem -Path $SearchRoot -Recurse -File -Filter $Filter |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1

    return $match
}

function Get-7ZipCommand {
    foreach ($name in @("7z.exe", "7z")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }

    foreach ($path in @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

function Get-DriverPayloadSummary {
    param([string]$Root)

    $summary = [ordered]@{
        Zip = 0
        Cab = 0
        Msi = 0
        Exe = 0
        Inf = 0
    }

    if (-not (Test-Path -LiteralPath $Root)) {
        return [pscustomobject]$summary
    }

    Get-ChildItem -Path $Root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        switch ($_.Extension.ToLowerInvariant()) {
            ".zip" { $summary.Zip++ }
            ".cab" { $summary.Cab++ }
            ".msi" { $summary.Msi++ }
            ".exe" { $summary.Exe++ }
            ".inf" { $summary.Inf++ }
        }
    }

    return [pscustomobject]$summary
}

function Install-7ZipIfNeeded {
    if (Get-7ZipCommand) {
        return
    }

    if (-not (Test-CommandExists "winget.exe")) {
        Write-WarnMsg "7-Zip is not installed and winget is unavailable. MSI/EXE driver extraction will be skipped."
        return
    }

    if (-not (Prompt-YesNo "7-Zip is recommended for extracting MSI/EXE driver packages. Install it with winget now?" $true)) {
        Write-WarnMsg "Skipping 7-Zip install. MSI/EXE driver extraction may be unavailable."
        return
    }

    Invoke-External -FilePath "winget.exe" -Arguments @(
        "install",
        "--id", "7zip.7zip",
        "--exact",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
}

function Check-Dependencies {
    Write-Msg "Checking Windows dependencies..."

    Assert-Command -Names @(
        "dism.exe",
        "diskpart.exe",
        "robocopy.exe",
        "expand.exe",
        "msiexec.exe",
        "Mount-DiskImage",
        "Dismount-DiskImage",
        "Get-Disk",
        "Get-Partition",
        "Get-Volume",
        "Invoke-WebRequest"
    )

    $driverSummary = Get-DriverPayloadSummary -Root $Script:DriversDir
    if (($driverSummary.Msi + $driverSummary.Exe) -gt 0) {
        Install-7ZipIfNeeded
    }

    Write-Msg "Dependencies look good."
    Write-Host ""
}

function Get-NormalizedHostArch {
    $raw = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        $env:PROCESSOR_ARCHITEW6432
    } else {
        $env:PROCESSOR_ARCHITECTURE
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return "unknown"
    }

    switch -Regex ($raw.ToLowerInvariant()) {
        '^(arm64|aarch64|armv8|armv9)' { return "arm64" }
        '^(amd64|x86_64|x64|x86|i386|i486|i586|i686)' { return "x64" }
        default { return "unknown" }
    }
}

function Get-UupPackageArch {
    param(
        [string]$PackageRoot,
        [string]$SourcePath
    )

    $armHits = 0
    $x64Hits = 0
    $sourceName = [System.IO.Path]::GetFileName($SourcePath)

    if (-not [string]::IsNullOrWhiteSpace($sourceName)) {
        $sourceLower = $sourceName.ToLowerInvariant()
        if ($sourceLower -match 'arm64|aarch64') {
            $armHits += 4
        }
        if ($sourceLower -match 'amd64|x64|x86_64') {
            $x64Hits += 4
        }
    }

    Get-ChildItem -Path $PackageRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $nameLower = $_.Name.ToLowerInvariant()
        if ($nameLower -match 'arm64|aarch64') {
            $armHits++
        }
        if ($nameLower -match 'amd64|x64|x86_64') {
            $x64Hits++
        }
    }

    if ($armHits -gt 0 -and $x64Hits -eq 0) {
        return "arm64"
    }
    if ($x64Hits -gt 0 -and $armHits -eq 0) {
        return "x64"
    }
    if ($armHits -ge ($x64Hits * 2)) {
        return "arm64"
    }
    if ($x64Hits -ge ($armHits * 2)) {
        return "x64"
    }

    return "unknown"
}

function Confirm-ArchMismatchIfNeeded {
    param(
        [string]$HostArch,
        [string]$TargetArch
    )

    if ($HostArch -eq "unknown" -or $TargetArch -eq "unknown" -or $HostArch -eq $TargetArch) {
        return
    }

    if ($HostArch -eq "arm64" -and $TargetArch -eq "x64") {
        Write-WarnMsg "Detected Windows on ARM64, but the selected UUP package appears to be x64/amd64."
        Write-WarnMsg "x64 media will not boot natively on ARM-only systems."
    } elseif ($HostArch -eq "x64" -and $TargetArch -eq "arm64") {
        Write-WarnMsg "Detected x86_64 Windows host, but the selected UUP package appears to be ARM64."
        Write-WarnMsg "ARM64 media may not boot or install on x86_64 systems."
    } else {
        Write-WarnMsg "Host CPU architecture ($HostArch) does not match selected UUP architecture ($TargetArch)."
    }

    if (-not (Prompt-YesNo "Proceed anyway with this architecture mismatch?" $false)) {
        Fail "Aborted by user due to architecture mismatch."
    }
}

function Get-UupPackageRoot {
    Write-Host ""
    Write-Host "Download a Windows 11 build from UUP dump:"
    Write-Host ""
    Write-Host "  1. Visit https://uupdump.net"
    Write-Host "  2. Select a Windows 11 build, language, and edition"
    Write-Host "  3. On the download page, choose the Windows package"
    Write-Host "  4. Download the ZIP package"
    Write-Host ""

    while ($true) {
        $sourcePath = Read-Host "Path to the UUP dump ZIP or extracted folder"
        if ([string]::IsNullOrWhiteSpace($sourcePath)) {
            Write-WarnMsg "A path is required."
            continue
        }

        $sourcePath = $sourcePath.Trim('"')
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Write-WarnMsg "Path not found: $sourcePath"
            continue
        }

        if ((Get-Item -LiteralPath $sourcePath) -is [System.IO.DirectoryInfo]) {
            Write-Msg "Using extracted UUP dump folder: $sourcePath"
            return @{
                PackageRoot = (Resolve-Path $sourcePath).Path
                SourcePath = (Resolve-Path $sourcePath).Path
            }
        }

        if ($sourcePath.ToLowerInvariant().EndsWith(".zip")) {
            $dest = Join-Path $Script:TmpDir "uupdump"
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $dest
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Write-Msg "Extracting UUP dump package..."
            Expand-Archive -LiteralPath $sourcePath -DestinationPath $dest -Force
            return @{
                PackageRoot = $dest
                SourcePath = (Resolve-Path $sourcePath).Path
            }
        }

        Write-WarnMsg "Unsupported file type. Provide a ZIP file or extracted folder."
    }
}

function Step-FetchIso {
    Write-Msg "Step 1: Fetch Windows 11 ISO"
    Write-Host ""

    if ((Test-Path -LiteralPath $Script:IsoPath) -and (Prompt-YesNo "ISO already exists at $Script:IsoPath. Use it?" $true)) {
        return
    }

    $uupPackage = Get-UupPackageRoot
    $pkgRoot = $uupPackage.PackageRoot
    $sourcePath = $uupPackage.SourcePath
    $launcher = Get-ChildItem -Path $pkgRoot -Recurse -File -Filter "uup_download_windows.cmd" |
        Select-Object -First 1

    if (-not $launcher) {
        Fail "Invalid UUP dump package: uup_download_windows.cmd was not found."
    }

    $hostArch = Get-NormalizedHostArch
    $uupArch = Get-UupPackageArch -PackageRoot $pkgRoot -SourcePath $sourcePath
    Write-Msg "Host CPU architecture: $hostArch"
    if ($uupArch -eq "unknown") {
        Write-WarnMsg "Could not confidently detect the UUP package architecture."
    } else {
        Write-Msg "Detected UUP package architecture: $uupArch"
    }
    Confirm-ArchMismatchIfNeeded -HostArch $hostArch -TargetArch $uupArch

    Write-Msg "Running the Windows UUP dump script. This can take a while."
    Invoke-External -FilePath "cmd.exe" -Arguments @("/c", $launcher.FullName) -WorkingDirectory $launcher.DirectoryName

    $builtIso = Get-LatestFile -SearchRoot $pkgRoot -Filter "*.iso"
    if (-not $builtIso) {
        Fail "No ISO was produced by the UUP dump package."
    }

    Copy-Item -LiteralPath $builtIso.FullName -Destination $Script:IsoPath -Force
    Write-Msg "ISO ready: $Script:IsoPath"
    Write-Host ""
}

function Get-Tiny11Workspace {
    $zipPath = Join-Path $Script:TmpDir "tiny11builder.zip"
    $extractRoot = Join-Path $Script:TmpDir "tiny11builder"

    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $extractRoot
    Write-Msg "Downloading tiny11builder..."
    Invoke-WebRequest -UseBasicParsing -Uri $Script:Tiny11ZipUrl -OutFile $zipPath
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force

    $workspace = Get-ChildItem -Path $extractRoot -Directory | Select-Object -First 1
    if (-not $workspace) {
        Fail "Failed to extract tiny11builder."
    }

    return $workspace.FullName
}

function Invoke-Tiny11Build {
    param(
        [ValidateSet("regular", "core")]
        [string]$Mode
    )

    $workspace = Get-Tiny11Workspace
    $scriptName = if ($Mode -eq "core") { "tiny11Coremaker.ps1" } else { "tiny11maker.ps1" }
    $builderScript = Join-Path $workspace $scriptName

    if (-not (Test-Path -LiteralPath $builderScript)) {
        Fail "Could not find $scriptName in the tiny11builder package."
    }

    Write-Msg "Mounting ISO for tiny11builder..."
    $mounted = Mount-DiskImage -ImagePath $Script:IsoPath -PassThru
    try {
        $volume = $mounted | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
        if (-not $volume) {
            Fail "Mounted ISO did not expose a drive letter."
        }

        $isoLetter = [string]$volume.DriveLetter
        $scratchLetter = Get-DriveLetterFromPath -Path $Script:TmpDir
        Write-Msg "Running $scriptName with ISO $isoLetter and scratch drive $scratchLetter"

        Invoke-External -FilePath "powershell.exe" -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $builderScript,
            "-ISO", $isoLetter,
            "-SCRATCH", $scratchLetter
        ) -WorkingDirectory $workspace
    }
    finally {
        Dismount-DiskImage -ImagePath $Script:IsoPath -ErrorAction SilentlyContinue | Out-Null
    }

    $tinyIso = Join-Path $workspace "tiny11.iso"
    if (-not (Test-Path -LiteralPath $tinyIso)) {
        Fail "tiny11builder completed without producing tiny11.iso"
    }

    Copy-Item -LiteralPath $tinyIso -Destination $Script:IsoPath -Force
    Write-Msg "Tiny11 ISO ready: $Script:IsoPath"
}

function Step-Tiny11 {
    Write-Msg "Step 2: Tiny11 build (Windows native)"
    Write-Host ""

    $choice = Prompt-Choice -Prompt "Select Tiny11 mode" -Choices @(
        "regular (recommended)",
        "core (aggressive)",
        "skip"
    ) -DefaultIndex 0

    switch ($choice) {
        "skip" {
            Write-Msg "Skipping Tiny11 build."
        }
        "core (aggressive)" {
            Invoke-Tiny11Build -Mode "core"
        }
        default {
            Invoke-Tiny11Build -Mode "regular"
        }
    }

    Write-Host ""
}

function Copy-DirectoryRobocopy {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $args = @($Source, $Destination, "/E", "/R:1", "/W:1", "/NFL", "/NDL", "/NP", "/NJH", "/NJS")
    $proc = Start-Process -FilePath "robocopy.exe" -ArgumentList $args -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ge 8) {
        Fail "robocopy failed with exit code $($proc.ExitCode)"
    }
}

function Get-InfRootDirectories {
    param([string]$SearchRoot)

    if (-not (Test-Path -LiteralPath $SearchRoot)) {
        return @()
    }

    $dirs = Get-ChildItem -Path $SearchRoot -Recurse -File -Filter "*.inf" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Directory.FullName } |
        Sort-Object -Unique

    return @($dirs)
}

function Expand-CabArchive {
    param(
        [string]$SourceFile,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Invoke-External -FilePath "expand.exe" -Arguments @(
        "-F:*",
        $SourceFile,
        $Destination
    )
}

function Expand-MsiArchive {
    param(
        [string]$SourceFile,
        [string]$Destination
    )

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Invoke-External -FilePath "msiexec.exe" -Arguments @(
        "/a",
        $SourceFile,
        "/qn",
        "TARGETDIR=$Destination"
    )
}

function Expand-With7Zip {
    param(
        [string]$SourceFile,
        [string]$Destination
    )

    $sevenZip = Get-7ZipCommand
    if (-not $sevenZip) {
        Write-WarnMsg "7-Zip is not available. Skipping archive: $SourceFile"
        return $false
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    Invoke-External -FilePath $sevenZip -Arguments @(
        "x",
        "-y",
        "-o$Destination",
        $SourceFile
    )
    return $true
}

function Expand-DriverPayloads {
    param(
        [string]$InputRoot,
        [string]$OutputRoot
    )

    New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

    Get-ChildItem -Path $InputRoot -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $source = $_.FullName
        $safeName = $_.BaseName.Replace(' ', '_')
        $dest = Join-Path $OutputRoot ($safeName + "_" + $_.Name.GetHashCode())

        try {
            switch ($_.Extension.ToLowerInvariant()) {
                ".zip" {
                    New-Item -ItemType Directory -Force -Path $dest | Out-Null
                    Expand-Archive -LiteralPath $source -DestinationPath $dest -Force
                }
                ".cab" {
                    Expand-CabArchive -SourceFile $source -Destination $dest
                }
                ".msi" {
                    Expand-MsiArchive -SourceFile $source -Destination $dest
                }
                ".exe" {
                    [void](Expand-With7Zip -SourceFile $source -Destination $dest)
                }
                default { }
            }
        }
        catch {
            Write-WarnMsg "Failed to extract driver payload: $source"
        }
    }
}

function Get-DriverSourceDirectories {
    if (-not (Test-Path -LiteralPath $Script:DriversDir)) {
        Write-Msg "No drivers directory found at $Script:DriversDir. Skipping driver injection."
        return @()
    }

    $extractRoot = Join-Path $Script:TmpDir "driver_extract"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $extractRoot
    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

    Write-Msg "Scanning driver payloads in $Script:DriversDir"
    Expand-DriverPayloads -InputRoot $Script:DriversDir -OutputRoot $extractRoot

    $roots = @()
    $roots += Get-InfRootDirectories -SearchRoot $Script:DriversDir
    $roots += Get-InfRootDirectories -SearchRoot $extractRoot
    $roots = $roots | Sort-Object -Unique

    if ($roots.Count -eq 0) {
        Write-WarnMsg "No .inf driver files were found under $Script:DriversDir."
        return @()
    }

    Write-Msg ("Detected {0} unique INF driver director{1}." -f $roots.Count, $(if ($roots.Count -eq 1) { "y" } else { "ies" }))
    return @($roots)
}

function Get-WimIndexes {
    param([string]$WimPath)

    $output = Invoke-ExternalCapture -FilePath "dism.exe" -Arguments @(
        "/English",
        "/Get-WimInfo",
        "/WimFile:$WimPath"
    )

    $indexes = foreach ($line in $output) {
        if ($line -match '^\s*Index\s*:\s*(\d+)\s*$') {
            [int]$matches[1]
        }
    }

    if (-not $indexes) {
        Fail "Failed to determine WIM indexes for $WimPath"
    }

    return @($indexes)
}

function Add-DriversToMountedImage {
    param(
        [string]$MountDir,
        [string[]]$DriverRoots
    )

    foreach ($driverRoot in $DriverRoots) {
        Invoke-External -FilePath "dism.exe" -Arguments @(
            "/English",
            "/Image:$MountDir",
            "/Add-Driver",
            "/Driver:$driverRoot",
            "/Recurse"
        )
    }
}

function Mount-WimImage {
    param(
        [string]$WimPath,
        [int]$Index,
        [string]$MountDir
    )

    New-Item -ItemType Directory -Force -Path $MountDir | Out-Null
    Invoke-External -FilePath "dism.exe" -Arguments @(
        "/English",
        "/Mount-Image",
        "/ImageFile:$WimPath",
        "/Index:$Index",
        "/MountDir:$MountDir"
    )
}

function Unmount-WimImage {
    param(
        [string]$MountDir,
        [bool]$Commit = $true
    )

    $mode = if ($Commit) { "/Commit" } else { "/Discard" }
    Invoke-External -FilePath "dism.exe" -Arguments @(
        "/English",
        "/Unmount-Image",
        "/MountDir:$MountDir",
        $mode
    )
}

function Inject-DriversIntoWim {
    param(
        [string]$WimPath,
        [int[]]$Indexes,
        [string[]]$DriverRoots,
        [string]$Label
    )

    foreach ($index in $Indexes) {
        $mountDir = Join-Path $Script:TmpDir ("mount_{0}_{1}" -f $Label, $index)
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $mountDir

        $mounted = $false
        try {
            Write-Msg "Mounting $Label index $index for driver injection..."
            Mount-WimImage -WimPath $WimPath -Index $index -MountDir $mountDir
            $mounted = $true

            Write-Msg "Injecting drivers into $Label index $index..."
            Add-DriversToMountedImage -MountDir $mountDir -DriverRoots $DriverRoots

            Write-Msg "Committing $Label index $index..."
            Unmount-WimImage -MountDir $mountDir -Commit $true
            $mounted = $false
        }
        catch {
            if ($mounted) {
                try {
                    Unmount-WimImage -MountDir $mountDir -Commit $false
                }
                catch {
                    Write-WarnMsg "Failed to discard mounted image at $mountDir after an error."
                }
            }
            throw
        }
    }
}

function Inject-DriversIntoIsoTree {
    param([string]$TreeRoot)

    $driverRoots = Get-DriverSourceDirectories
    if ($driverRoots.Count -eq 0) {
        return
    }

    $bootWim = Join-Path $TreeRoot "sources\boot.wim"
    if (Test-Path -LiteralPath $bootWim) {
        Inject-DriversIntoWim -WimPath $bootWim -Indexes @(2) -DriverRoots $driverRoots -Label "boot"
    } else {
        Write-WarnMsg "boot.wim was not found. Skipping WinPE driver injection."
    }

    $installWim = Join-Path $TreeRoot "sources\install.wim"
    if (-not (Test-Path -LiteralPath $installWim)) {
        $splitSwm = Join-Path $TreeRoot "sources\install.swm"
        if (Test-Path -LiteralPath $splitSwm) {
            Write-WarnMsg "This media already uses split install.swm files. boot.wim can still be updated, but install image driver injection is skipped."
        }
        Write-WarnMsg "install.wim was not found. Skipping install image driver injection."
        return
    }

    $installIndexes = Get-WimIndexes -WimPath $installWim
    Inject-DriversIntoWim -WimPath $installWim -Indexes $installIndexes -DriverRoots $driverRoots -Label "install"
    Write-Msg "Driver injection complete."
}

function Convert-InstallEsdToWimIfNeeded {
    param([string]$TreeRoot)

    $sources = Join-Path $TreeRoot "sources"
    $esd = Join-Path $sources "install.esd"
    $wim = Join-Path $sources "install.wim"

    if (-not (Test-Path -LiteralPath $esd)) {
        return
    }

    Write-Msg "Converting install.esd to install.wim..."
    Invoke-External -FilePath "dism.exe" -Arguments @(
        "/English",
        "/Export-Image",
        "/SourceImageFile:$esd",
        "/SourceIndex:1",
        "/DestinationImageFile:$wim",
        "/Compress:max",
        "/CheckIntegrity"
    )

    for ($index = 2; $true; $index++) {
        $export = Start-Process -FilePath "dism.exe" -ArgumentList @(
            "/English",
            "/Export-Image",
            "/SourceImageFile:$esd",
            "/SourceIndex:$index",
            "/DestinationImageFile:$wim",
            "/Compress:max",
            "/CheckIntegrity"
        ) -Wait -PassThru -NoNewWindow

        if ($export.ExitCode -eq 0) {
            continue
        }

        if ($export.ExitCode -eq 2 -or $export.ExitCode -eq 87) {
            break
        }

        Fail "DISM export failed while converting install.esd (index $index)."
    }

    Remove-Item -Force $esd
}

function Ensure-WimSplitForFat32Tree {
    param([string]$TreeRoot)

    $wim = Join-Path $TreeRoot "sources\install.wim"
    if (-not (Test-Path -LiteralPath $wim)) {
        return
    }

    $wimInfo = Get-Item -LiteralPath $wim
    if ($wimInfo.Length -le [uint64]4294967295) {
        return
    }

    Write-Msg "install.wim is larger than 4 GB. Splitting for FAT32..."
    $swm = Join-Path $TreeRoot "sources\install.swm"
    Invoke-External -FilePath "dism.exe" -Arguments @(
        "/English",
        "/Split-Image",
        "/ImageFile:$wim",
        "/SWMFile:$swm",
        "/FileSize:$Script:WimSplitMb"
    )
    Remove-Item -Force $wim
}

function Prepare-IsoTreeForCopyMedia {
    param([string]$IsoPath)

    $treeRoot = Join-Path $Script:TmpDir "media_iso_tree"
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $treeRoot
    New-Item -ItemType Directory -Force -Path $treeRoot | Out-Null

    Write-Msg "Mounting ISO for USB preparation..."
    $mounted = Mount-DiskImage -ImagePath $IsoPath -PassThru
    try {
        $volume = $mounted | Get-Volume | Where-Object DriveLetter | Select-Object -First 1
        if (-not $volume) {
            Fail "Mounted ISO did not expose a drive letter."
        }

        $src = "$($volume.DriveLetter):\"
        Write-Msg "Copying ISO contents to a writable staging tree..."
        Copy-DirectoryRobocopy -Source $src -Destination $treeRoot
    }
    finally {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
    }

    Convert-InstallEsdToWimIfNeeded -TreeRoot $treeRoot
    Inject-DriversIntoIsoTree -TreeRoot $treeRoot
    Ensure-WimSplitForFat32Tree -TreeRoot $treeRoot
    return $treeRoot
}

function Get-UsbDisks {
    Get-Disk |
        Where-Object { $_.BusType -eq "USB" } |
        Sort-Object Number
}

function Select-UsbDisk {
    $usbDisks = @(Get-UsbDisks)
    if ($usbDisks.Count -eq 0) {
        Fail "No USB disks were found. Insert a USB drive and try again."
    }

    foreach ($disk in $usbDisks) {
        $sizeGb = [math]::Round($disk.Size / 1GB, 1)
        Write-Host ("  {0}) Disk {0} - {1} - {2} GB" -f $disk.Number, $disk.FriendlyName, $sizeGb)
    }

    $selectedRaw = Read-Host "Select the USB disk number"
    $selectedNumber = 0
    if (-not [int]::TryParse($selectedRaw, [ref]$selectedNumber)) {
        Fail "Invalid disk number."
    }

    $selectedDisk = $usbDisks | Where-Object Number -eq $selectedNumber | Select-Object -First 1
    if (-not $selectedDisk) {
        Fail "USB disk $selectedNumber was not found in the available list."
    }

    return $selectedDisk
}

function Get-UsbVolumeRootFromDisk {
    param([int]$DiskNumber)

    $volumes = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
        Where-Object DriveLetter |
        ForEach-Object { Get-Volume -Partition $_ -ErrorAction SilentlyContinue } |
        Where-Object DriveLetter)

    if ($volumes.Count -eq 0) {
        Fail "No mounted volume with a drive letter was found on USB disk $DiskNumber."
    }

    if ($volumes.Count -eq 1) {
        return "$($volumes[0].DriveLetter):\"
    }

    Write-Host ""
    Write-Host "Mounted volumes on the selected USB disk:"
    foreach ($volume in $volumes) {
        Write-Host ("  {0}) {1}:\  Label={2}  FS={3}" -f $volume.DriveLetter, $volume.DriveLetter, $volume.FileSystemLabel, $volume.FileSystem)
    }

    while ($true) {
        $selectedLetter = Read-Host "Select the drive letter to update"
        if ([string]::IsNullOrWhiteSpace($selectedLetter)) {
            Write-WarnMsg "A drive letter is required."
            continue
        }

        $selectedLetter = $selectedLetter.Trim().TrimEnd(':').ToUpperInvariant()
        $match = $volumes | Where-Object { $_.DriveLetter.ToString().ToUpperInvariant() -eq $selectedLetter } | Select-Object -First 1
        if ($match) {
            return "$selectedLetter`:\"
        }

        Write-WarnMsg "That drive letter was not found on the selected USB disk."
    }
}

function Step-DriversOnlyUsb {
    Write-Msg "Step 1: Drivers-Only USB Update"
    Write-Host ""
    Write-Host "This mode updates an existing Windows installer USB without rebuilding it."
    Write-Host "It injects drivers into the media already on the selected USB drive."
    Write-Host ""

    $selectedDisk = Select-UsbDisk
    $usbRoot = Get-UsbVolumeRootFromDisk -DiskNumber $selectedDisk.Number

    if (-not (Test-Path -LiteralPath (Join-Path $usbRoot "sources\boot.wim"))) {
        Fail "The selected USB does not appear to contain Windows setup media (missing sources\boot.wim)."
    }

    Write-Msg "Updating existing installer media at $usbRoot"
    Inject-DriversIntoIsoTree -TreeRoot $usbRoot
    Write-Host ""
}

function Confirm-DiskDestruction {
    param([int]$DiskNumber)

    Write-WarnMsg "This will erase all data on disk $DiskNumber."
    $typed = Read-Host "Type the disk number to confirm"
    if ($typed -ne [string]$DiskNumber) {
        Fail "Confirmation did not match."
    }
}

function New-DiskpartScript {
    param(
        [int]$DiskNumber,
        [string]$DriveLetter
    )

    $scriptPath = Join-Path $Script:TmpDir "diskpart-usb.txt"
    @(
        "select disk $DiskNumber"
        "clean"
        "convert gpt"
        "create partition primary"
        "format fs=fat32 quick label=$Script:InstallerVolLabel"
        "assign letter=$DriveLetter"
        "exit"
    ) | Set-Content -Path $scriptPath -Encoding ASCII

    return $scriptPath
}

function Initialize-BootUsb {
    param([int]$DiskNumber)

    $preferred = @('W','U','T','S','R','Q','P','O','N')
    $used = (Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
    $driveLetter = $preferred | Where-Object { $_ -notin $used } | Select-Object -First 1
    if (-not $driveLetter) {
        Fail "Could not find a free drive letter for the USB target."
    }

    $scriptPath = New-DiskpartScript -DiskNumber $DiskNumber -DriveLetter $driveLetter
    Invoke-External -FilePath "diskpart.exe" -Arguments @("/s", $scriptPath)

    $volumePath = "$driveLetter`:\"
    if (-not (Test-Path -LiteralPath $volumePath)) {
        Fail "USB volume was not mounted after diskpart completed."
    }

    return $volumePath
}

function Step-UsbSetup {
    Write-Msg "Step 3: Bootable USB"
    Write-Host ""

    $selectedDisk = Select-UsbDisk

    Confirm-DiskDestruction -DiskNumber $selectedDisk.Number
    if (-not (Prompt-YesNo "Continue?" $false)) {
        Fail "Cancelled."
    }

    $isoTree = Prepare-IsoTreeForCopyMedia -IsoPath $Script:IsoPath
    $usbRoot = Initialize-BootUsb -DiskNumber $selectedDisk.Number

    Write-Msg "Copying bootable Windows media to $usbRoot"
    Copy-DirectoryRobocopy -Source $isoTree -Destination $usbRoot
    Write-Msg "Bootable USB created successfully."
    Write-Host ""
}

function Step-Finish {
    param([string]$Mode = "full")

    $stepNumber = if ($Mode -eq "drivers-only") { 2 } else { 4 }
    Write-Msg "Step ${stepNumber}: Finish"
    Write-Host ""
    if ($Mode -eq "drivers-only") {
        Write-Host "The selected Windows installer USB has been updated with the detected drivers."
        Write-Host "You can boot from that USB when you're ready."
    } else {
        Write-Host "Your Windows 11 USB installer is ready."
        Write-Host "Use your firmware boot menu to boot from the USB drive."
    }
    Write-Host ""
}

function Show-Intro {
    Write-Host @"
╔═══════════════════════════════════════════════════════════════╗
║      Win-Reboot-Project: Windows 11 Setup (Windows)          ║
╚═══════════════════════════════════════════════════════════════╝

Flow:
  1. Build ISO from UUP dump using uup_download_windows.cmd
  2. Optional Tiny11 build using ntdevlabs/tiny11builder
  3. Create a bootable FAT32 USB and split install.wim if needed
  4. Boot from the USB drive

Extras:
  - Drivers-only mode can update an existing installer USB in place

"@

    if (-not (Prompt-YesNo "Continue?" $false)) {
        exit 0
    }

    Write-Host ""
    return Prompt-Choice -Prompt "Choose startup mode" -Choices @(
        "full build + USB creation",
        "drivers-only on existing USB"
    ) -DefaultIndex 0
}

function Main {
    Assert-Windows
    Assert-Administrator

    Set-Location $Script:RootDir
    Check-Dependencies
    $startupMode = Show-Intro

    if ($startupMode -eq "drivers-only on existing USB") {
        Step-DriversOnlyUsb
        Step-Finish -Mode "drivers-only"
        return
    }

    Step-FetchIso
    Step-Tiny11
    Step-UsbSetup
    Step-Finish -Mode "full"
}

Main
