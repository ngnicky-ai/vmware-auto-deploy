#Requires -RunAsAdministrator
<#
.SYNOPSIS
    VMware Workstation Auto Deploy Script

.DESCRIPTION
    Kali Linux VMware image download, extract, configure, and register.
    Add items to $VMs array to deploy multiple VMs.

.EXAMPLE
    .\Deploy-KaliLinux.ps1
    (Run in Administrator PowerShell)
#>

$ErrorActionPreference = 'Stop'

# ===========================================================================
# Configuration
# ===========================================================================
$VMwareDir = "C:\Program Files (x86)\VMware\VMware Workstation"
$vmrunExe  = "$VMwareDir\vmrun.exe"
$vmwareExe = "$VMwareDir\vmware.exe"
$TargetDir = "C:\vmwares"

# VM list - add entries to deploy additional VMs
$VMs = @(
    @{
        Name            = "Kali Linux 2026.1"
        Url             = "https://cdimage.kali.org/kali-2026.1/kali-linux-2026.1-vmware-amd64.7z"
        Archive         = "kali-linux-2026.1-vmware-amd64.7z"
        ExtractedFolder = "kali-linux-2026.1-vmware-amd64.vmwarevm"
        Memory          = 4096
        Network         = "nat"
        AutoStart       = $true
        Downloader      = "BITS"   # direct URL -> use BITS (supports resume)
    }
    @{
        Name            = "bWAPP bee-box v1.6"
        Url             = "https://sourceforge.net/projects/bwapp/files/bee-box/bee-box_v1.6.7z/download"
        Archive         = "bee-box_v1.6.7z"
        ExtractedFolder = "bee-box"
        Memory          = 2048
        Network         = "nat"
        AutoStart       = $true
        Downloader      = "Curl"   # SourceForge redirect -> use curl -L
    }
)

# ===========================================================================
# Output helpers
# ===========================================================================
function Write-Step { param($msg) Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Info { param($msg) Write-Host "    $msg" -ForegroundColor Gray }
function Write-OK   { param($msg) Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Fail { param($msg) Write-Host "  [X] $msg" -ForegroundColor Red }

# ===========================================================================
# Helper: set or add a key in a VMX file (array of lines)
# ===========================================================================
function Set-VMXKey {
    param(
        [string[]] $Lines,
        [string]   $Key,
        [string]   $Value
    )
    $escapedKey = [regex]::Escape($Key)
    $pattern    = "^$escapedKey\s*=.*$"
    $newLine    = "$Key = `"$Value`""

    if ($Lines -match $pattern) {
        return $Lines -replace $pattern, $newLine
    }
    return $Lines + $newLine
}

# ===========================================================================
# Pre-flight checks
# ===========================================================================
Write-Host "============================================" -ForegroundColor White
Write-Host "  VMware Workstation Auto Deploy Script"     -ForegroundColor White
Write-Host "============================================" -ForegroundColor White

# VMware check
if (-not (Test-Path $vmrunExe)) {
    Write-Fail "vmrun.exe not found: $vmrunExe"
    Write-Fail "Please verify VMware Workstation is installed correctly."
    exit 1
}
Write-OK "VMware Workstation found: $VMwareDir"

# Create target directory
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    Write-OK "Created: $TargetDir"
} else {
    Write-Info "Directory exists: $TargetDir"
}

# 7-Zip: check installed paths, fall back to downloading 7zr.exe
$toolsDir  = "$TargetDir\_tools"
$7zipPaths = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe",
    "$toolsDir\7zr.exe"
)
$7zipExe = $7zipPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $7zipExe) {
    Write-Step "7-Zip not installed - downloading standalone 7zr.exe"
    if (-not (Test-Path $toolsDir)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    }
    $7zrPath = "$toolsDir\7zr.exe"
    Write-Info "Downloading: https://www.7-zip.org/a/7zr.exe"
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $7zrPath -UseBasicParsing
    $ProgressPreference = 'Continue'
    $7zipExe = $7zrPath
    Write-OK "7zr.exe ready: $7zrPath"
} else {
    Write-OK "7-Zip found: $7zipExe"
}

# ===========================================================================
# Deploy each VM
# ===========================================================================
foreach ($vm in $VMs) {
    Write-Host "`n============================================" -ForegroundColor Yellow
    Write-Host "  VM: $($vm.Name)"                           -ForegroundColor Yellow
    Write-Host "============================================" -ForegroundColor Yellow

    $archivePath   = "$TargetDir\$($vm.Archive)"
    $extractedPath = "$TargetDir\$($vm.ExtractedFolder)"

    # ------------------------------------------------------------------
    # Step 1: Download image
    # ------------------------------------------------------------------
    Write-Step "Step 1: Download image"
    if (Test-Path $archivePath) {
        $sizeMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 1)
        Write-Info "File already exists ($sizeMB MB) - skipping: $archivePath"
    } else {
        Write-Info "URL : $($vm.Url)"
        Write-Info "Dest: $archivePath"
        Write-Warn "This may take a while for large files..."

        if ($vm.Downloader -eq "Curl") {
            # curl -L follows SourceForge multi-hop redirects reliably
            Write-Info "Downloader: curl (redirect-following mode)"
            curl.exe -L --progress-bar -o $archivePath $vm.Url
            if ($LASTEXITCODE -ne 0) {
                Write-Fail "curl download failed (exit code: $LASTEXITCODE)"
                exit 1
            }
        } else {
            # BITS: resumable background transfer for direct URLs
            Write-Info "Downloader: BITS (progress shown in transfer window)"
            Start-BitsTransfer `
                -Source      $vm.Url `
                -Destination $archivePath `
                -DisplayName "$($vm.Name) Download" `
                -Description "Downloading VMware image..."
        }

        $sizeMB = [math]::Round((Get-Item $archivePath).Length / 1MB, 1)
        Write-OK "Download complete ($sizeMB MB)"
    }

    # ------------------------------------------------------------------
    # Step 2: Extract archive
    # ------------------------------------------------------------------
    Write-Step "Step 2: Extract archive"
    if (Test-Path $extractedPath) {
        Write-Info "Already extracted - skipping: $extractedPath"
    } else {
        Write-Info "$archivePath  -->  $TargetDir"
        Write-Warn "Extracting large file, please wait..."

        # -mmt=on  : use all CPU threads (speeds up LZMA2 decompression)
        & $7zipExe x $archivePath "-o$TargetDir" -y -mmt=on
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Extraction failed (exit code: $LASTEXITCODE)"
            exit 1
        }
        Write-OK "Extracted to: $extractedPath"
    }

    # Locate .vmx file - search configured folder first, fall back to TargetDir
    $searchRoot = if (Test-Path $extractedPath) { $extractedPath } else { $TargetDir }
    $vmxFile = Get-ChildItem -Path $searchRoot -Filter "*.vmx" -Recurse `
                             -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vmxFile) {
        Write-Fail ".vmx file not found in: $searchRoot"
        exit 1
    }
    $vmxPath = $vmxFile.FullName
    Write-Info "VMX file: $vmxPath"

    # ------------------------------------------------------------------
    # Step 3: Configure VMX (RAM, network)
    # ------------------------------------------------------------------
    Write-Step "Step 3: Apply VMX settings"

    $vmxContent = Get-Content $vmxPath
    $vmxContent = Set-VMXKey $vmxContent "memsize"                  $vm.Memory
    $vmxContent = Set-VMXKey $vmxContent "ethernet0.present"        "TRUE"
    $vmxContent = Set-VMXKey $vmxContent "ethernet0.connectionType" $vm.Network
    $vmxContent | Set-Content $vmxPath -Encoding UTF8

    Write-OK "RAM    : $($vm.Memory) MB ($([math]::Round($vm.Memory/1024,0)) GB)"
    Write-OK "Network: $($vm.Network)"

    # ------------------------------------------------------------------
    # Step 4: Register VM with VMware
    # ------------------------------------------------------------------
    Write-Step "Step 4: Register VM"
    Write-Info "vmrun registerVM `"$vmxPath`""

    & $vmrunExe registerVM $vmxPath 2>&1 | ForEach-Object { Write-Info $_ }

    if ($LASTEXITCODE -eq 0) {
        Write-OK "VM registered successfully"
    } else {
        Write-Warn "Registration warning (may already be registered, code: $LASTEXITCODE)"
    }

    # ------------------------------------------------------------------
    # Step 5: Power on VM (optional)
    # ------------------------------------------------------------------
    if ($vm.AutoStart) {
        Write-Step "Step 5: Power on VM"
        Write-Info "vmrun start `"$vmxPath`" gui"

        & $vmrunExe start $vmxPath gui
        if ($LASTEXITCODE -eq 0) {
            Write-OK "VM started in VMware Workstation GUI"
        } else {
            Write-Warn "Could not start VM automatically (code: $LASTEXITCODE)"
            Write-Info "Open VMware Workstation and start it manually."
        }
    }

    Write-OK "[$($vm.Name)] deployment complete!"
    Write-Info "VMX: $vmxPath"
}

# ===========================================================================
# Done
# ===========================================================================
Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  All VMs deployed!"                          -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Info "Open VMware Workstation to verify:"
Write-Info "  $vmwareExe"
Write-Host ""
