<#
    uninstall_llama_cpp.ps1
    ------------------------
    Uninstalls all prerequisites and removes the source code
    downloaded by the install_llama_cpp.ps1 script.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Assert-Admin {
    $id  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prn = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $prn.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this script from an *elevated* PowerShell window."
    }
}

function Test-Command ([string]$Name) {
    (Get-Command $Name -ErrorAction SilentlyContinue) -ne $null
}

# --- CUDA: generic discovery (12.4+ including 13.x) -------------------------

function Get-CudaInstalls {
    $root = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    foreach ($d in Get-ChildItem $root -Directory) {
        if ($d.Name -match '^v(\d+)\.(\d+)$') {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            $ver = [version]::new($maj, $min)
            $out += [pscustomobject]@{ Version=$ver; Major=$maj; Minor=$min; Path=$d.FullName }
        }
    }
    $out
}

function Test-CUDAExact {
    param([Parameter(Mandatory=$true)][string]$MajorMinor) # e.g. '12.4'
    $target = [version]("$MajorMinor")
    $hit = Get-CudaInstalls | Where-Object {
        $_.Version.Major -eq $target.Major -and $_.Version.Minor -eq $target.Minor
    } | Select-Object -First 1
    return $null -ne $hit
}


function Remove-FromMachinePath([string]$Dir) {
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = (Get-ItemProperty -Path $regPath -Name Path).Path
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if (-not ($parts -contains $Dir)) { return } # Not in path, nothing to do

    Write-Host "-> removing '$Dir' from system PATH ..."
    $newParts = $parts | Where-Object { $_ -ne $Dir }
    $new = $newParts -join ';'
    Set-ItemProperty -Path $regPath -Name Path -Value $new
}

# Run winget non-interactively to uninstall a package
function Uninstall-Winget {
    param(
        [Parameter(Mandatory=$true)][string]$Id
    )
    if (-not (Test-Command winget)) {
        Write-Warning "The 'winget' command is not available. Skipping uninstallation of $Id."
        return
    }
    Write-Host "-> uninstalling $Id ..."
    $argList = @(
        'uninstall','--id',$Id,
        '--source','winget',
        '--silent','--disable-interactivity',
        '--accept-source-agreements','--force'
    )

    $log = Join-Path $env:TEMP ("winget_uninstall_{0}.log" -f ($Id -replace '[^A-Za-z0-9]+','_'))
    & winget @argList *> $log
    $exitCode = $LASTEXITCODE

    # -1978335212: WINGET_ERR_NO_PACKAGE_FOUND (already uninstalled or never installed)
    # 1603 = "Fatal error during installation" (often means "already uninstalled")
    # 1605 = "This action is only valid for products that are currently installed."
    if ($exitCode -and $exitCode -notin @(0, 1603, 1605, -1978335212)) {
        Write-Warning "winget returned exit code $exitCode while uninstalling $Id. See log: $log"
    } else {
        Write-Host "[OK] Uninstalled $Id"
    }
}

function Uninstall-CUDA124-FromNVIDIA {
    if (-not (Test-CUDAExact -MajorMinor '12.4')) {
        return # Not installed, nothing to do
    }

    Write-Host "--- Attempting to uninstall CUDA Toolkit 12.4 (manual install) ---"

    $uninstallKeys = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $cudaUninstall = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object {
            $_.PSObject.Properties.Name -contains 'DisplayName' -and
            (
                $_.DisplayName -like '*NVIDIA CUDA Toolkit 12.4*' -or
                (
                    $_.DisplayName -like '*NVIDIA CUDA Toolkit*' -and
                    $_.PSObject.Properties.Name -contains 'DisplayVersion' -and
                    $_.DisplayVersion -like '12.4*'
                )
            )
        } | Select-Object -First 1

    if ($cudaUninstall -and $cudaUninstall.UninstallString) {
        Write-Host "  Found uninstaller: $($cudaUninstall.UninstallString)"
        Write-Host "  Launching uninstaller. Please follow the on-screen instructions."

        try {
            # The uninstall string can be complex (e.g., 'MsiExec.exe /I{GUID}'),
            # so using cmd /c is a robust way to execute it.
            $p = Start-Process -FilePath "cmd.exe" -ArgumentList "/c ""$($cudaUninstall.UninstallString)""" -Wait -PassThru
            if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { # 3010 = success, reboot required
                Write-Host "[OK] CUDA 12.4 uninstaller finished."
            } else {
                Write-Warning "CUDA 12.4 uninstaller finished with exit code $($p.ExitCode)."
            }
        } catch {
            Write-Warning "Failed to start the CUDA 12.4 uninstaller: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "Could not find an uninstaller for NVIDIA CUDA Toolkit 12.4. Manual uninstallation may be required from 'Add or Remove Programs'."
    }
    Write-Host ""
}

# ---------------------------------------------------------------------------
# Main routine
# ---------------------------------------------------------------------------

Assert-Admin

# --- Uninstall CUDA 12.4 if present (from non-winget install) ---
# This is for the fallback path in the installer, which downloads from NVIDIA
# directly. The winget uninstall for Nvidia.CUDA will be tried later for
# other versions or if this fails.
Uninstall-CUDA124-FromNVIDIA

# --- Uninstall portable Ninja ---
$ninjaDir = 'C:\Program Files\Ninja'
if (Test-Path $ninjaDir) {
    Write-Host "--- Removing portable Ninja installation ---"
    Remove-FromMachinePath -Dir $ninjaDir
    try {
        Remove-Item -Path $ninjaDir -Recurse -Force
        Write-Host "[OK] Removed Ninja directory."
    } catch {
        Write-Warning "Could not remove Ninja directory at $ninjaDir. You may need to remove it manually."
        Write-Warning $_.Exception.Message
    }
    Write-Host ""
}

$reqs = @(
    'Kitware.CMake',
    'Ninja-build.Ninja',
    'Microsoft.VisualStudio.2022.BuildTools',
    'Nvidia.CUDA'
)

Write-Host "--- Uninstalling winget packages ---"
foreach ($r in $reqs) {
    Uninstall-Winget -Id $r
}

Write-Host ""
Write-Host "--- Removing cloned llama.cpp repository ---"
$llamaRepo = Join-Path $ScriptRoot 'vendor'
if (Test-Path $llamaRepo) {
    Remove-Item -Path $llamaRepo -Recurse -Force
    Write-Host "[OK] Removed vendor directory."
} else {
    Write-Host "  Vendor directory not found."
}

Write-Host ""
Write-Host "Done! Uninstallation complete."
