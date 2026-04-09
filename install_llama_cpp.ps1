<#
    install_llama_cpp.ps1
    --------------------
    Installs all prerequisites and builds ggerganov/llama.cpp on Windows.

    • Works on Windows PowerShell 7
    • Uses the Ninja generator (fast, no VS-integration dependency)
    • Re-usable: just run the script; it installs only what is missing
    • Pass -CudaArch <SM> to target a different GPU
      (89 = Ada; GTX-1070 = 61, RTX-30-series = 86, etc.)
#>

[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [ValidateSet('auto', 'cuda', 'vulkan', 'cpu')]
    [string]$Backend = 'auto',
    [version]$PinnedCudaVersion,
    [version]$MaxCudaVersion = [version]'13.1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Make PS5 iwr happy and TLS modern
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

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

function Test-VSTools {
    $vswhere = Join-Path ${Env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { return $false }

    $instRoot = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null

    if ([string]::IsNullOrWhiteSpace($instRoot)) { return $false }

    $vcvars = Join-Path $instRoot 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { return $false }

    $cl = Get-ChildItem -Path (Join-Path $instRoot 'VC\Tools\MSVC') `
        -Recurse -Filter cl.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cl) { return $false }

    # Windows SDK tools (needed by CMake generator/linker steps)
    $sdkBin = 'C:\Program Files (x86)\Windows Kits\10\bin'
    $rc = Get-ChildItem $sdkBin -Recurse -Filter rc.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    $mt = Get-ChildItem $sdkBin -Recurse -Filter mt.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not ($rc -and $mt)) { return $false }

    return $true
}

function Get-GraphicsAdapters {
    try {
        @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        @()
    }
}

function Get-GraphicsSummary {
    $gpus = Get-GraphicsAdapters
    $names = @($gpus | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    [pscustomobject]@{
        Devices   = $gpus
        Names     = $names
        HasNvidia = $null -ne ($gpus | Where-Object {
            $_.AdapterCompatibility -match 'NVIDIA' -or $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro|Tesla'
        } | Select-Object -First 1)
        HasAmd    = $null -ne ($gpus | Where-Object {
            $_.AdapterCompatibility -match 'AMD|Advanced Micro Devices' -or $_.Name -match 'AMD|Radeon'
        } | Select-Object -First 1)
        HasIntel  = $null -ne ($gpus | Where-Object {
            $_.AdapterCompatibility -match 'Intel' -or $_.Name -match 'Intel'
        } | Select-Object -First 1)
    }
}

function Resolve-Backend {
    param([Parameter(Mandatory = $true)][string]$Requested)

    if ($Requested -ne 'auto') {
        return $Requested
    }

    $graphics = Get-GraphicsSummary
    if ($graphics.HasNvidia) { return 'cuda' }
    if ($graphics.HasAmd -or $graphics.HasIntel) { return 'vulkan' }
    return 'cpu'
}

# --- CUDA: generic discovery (12.4+ including 13.x) -------------------------

function Get-CudaInstalls {
    $root = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    foreach ($d in Get-ChildItem $root -Directory) {
        $nvcc = Join-Path $d.FullName 'bin\nvcc.exe'
        if (($d.Name -match '^v(\d+)\.(\d+)$') -and (Test-Path $nvcc)) {
            $maj = [int]$Matches[1]; $min = [int]$Matches[2]
            $ver = [version]::new($maj, $min)
            $out += [pscustomobject]@{ Version=$ver; Major=$maj; Minor=$min; Path=$d.FullName }
        }
    }
    $out
}

function Get-CudaVersionKey {
    param([Parameter(Mandatory = $true)][version]$Version)
    [version]::new($Version.Major, $Version.Minor)
}

function Test-CudaVersionCompatible {
    param(
        [Parameter(Mandatory = $true)][version]$Version,
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    $key = Get-CudaVersionKey -Version $Version

    if ($Pinned) {
        $pinnedKey = Get-CudaVersionKey -Version $Pinned
        return $key.Major -eq $pinnedKey.Major -and $key.Minor -eq $pinnedKey.Minor
    }

    $minKey = Get-CudaVersionKey -Version $Min
    if ($key -lt $minKey) { return $false }

    if ($Max) {
        $maxKey = Get-CudaVersionKey -Version $Max
        if ($key -gt $maxKey) { return $false }
    }

    return $true
}

function Get-CompatibleCudaInstalls {
    param(
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    Get-CudaInstalls |
        Sort-Object Version -Descending |
        Where-Object {
            Test-CudaVersionCompatible -Version $_.Version -Min $Min -Max $Max -Pinned $Pinned
        }
}

function Test-CUDA {
    $min = [version]'12.4'
    $installs = Get-CudaInstalls
    if (-not $installs) { return $false }
    return ($installs | Where-Object { $_.Version -ge $min } | Select-Object -First 1) -ne $null
}

function Test-CompatibleCudaInstalled {
    param(
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    (Get-CompatibleCudaInstalls -Min $Min -Max $Max -Pinned $Pinned | Select-Object -First 1) -ne $null
}

function Test-CUDAExact {
    param([Parameter(Mandatory=$true)][string]$MajorMinor) # e.g. '12.4'
    $target = [version]("$MajorMinor")
    $hit = Get-CudaInstalls | Where-Object {
        $_.Version.Major -eq $target.Major -and $_.Version.Minor -eq $target.Minor
    } | Select-Object -First 1
    return $null -ne $hit
}

function Get-VulkanSdkInstalls {
    $roots = @()

    if ($env:VULKAN_SDK -and (Test-Path $env:VULKAN_SDK)) {
        $roots += $env:VULKAN_SDK
    }

    $defaultRoot = 'C:\VulkanSDK'
    if (Test-Path $defaultRoot) {
        $roots += Get-ChildItem $defaultRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }

    $roots |
        Sort-Object -Unique |
        ForEach-Object {
            $root = $_
            $glslc = Join-Path $root 'Bin\glslc.exe'
            $lib = Join-Path $root 'Lib\vulkan-1.lib'
            $header = Join-Path $root 'Include\vulkan\vulkan.h'
            if ((Test-Path $glslc) -and (Test-Path $lib) -and (Test-Path $header)) {
                [pscustomobject]@{
                    Root    = $root
                    Bin     = Join-Path $root 'Bin'
                    Glslc   = $glslc
                    Lib     = $lib
                    Include = Join-Path $root 'Include'
                }
            }
        } |
        Sort-Object Root -Descending
}

function Test-VulkanSdk {
    (Get-VulkanSdkInstalls | Select-Object -First 1) -ne $null
}

function Use-VulkanSdk {
    $sdk = Get-VulkanSdkInstalls | Select-Object -First 1
    if (-not $sdk) {
        throw "No Vulkan SDK installation was found. Install the LunarG Vulkan SDK and re-run the script."
    }

    $env:VULKAN_SDK = $sdk.Root
    if (-not ($env:Path -split ';' | Where-Object { $_ -ieq $sdk.Bin })) {
        $env:Path = "$($sdk.Bin);$env:Path"
    }

    Write-Host "  Using Vulkan SDK at $($sdk.Root)"
    @(
        "-DVulkan_INCLUDE_DIR=$($sdk.Include)"
        "-DVulkan_LIBRARY=$($sdk.Lib)"
        "-DVulkan_GLSLC_EXECUTABLE=$($sdk.Glslc)"
    )
}

function Install-CUDA124-FromNVIDIA {
    # Installs CUDA 12.4.1 silently (toolkit only; no driver, no GFE)
    $url = 'https://developer.download.nvidia.com/compute/cuda/12.4.1/local_installers/cuda_12.4.1_551.78_windows.exe'
    $exe = Join-Path $env:TEMP 'cuda_12.4.1_551.78_windows.exe'
    if (-not (Test-Path $exe)) {
        Write-Host "-> downloading CUDA 12.4.1 (local installer) ..."
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    }

    # Toolkit-only selection (no driver = no GeForce Experience)
    $toolkitPkgs = @(
        'nvcc_12.4',         # compiler
        'cudart_12.4',       # CUDA runtime
        'cublas_12.4',       # cuBLAS runtime
        'cublas_dev_12.4'    # cuBLAS headers/libs for build
    )

    $args = @('-s') + $toolkitPkgs + '-n'

    Write-Host "-> installing CUDA 12.4.1 (silent, toolkit only) ..."
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -Wait -PassThru

    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "CUDA 12.4.1 installer failed with exit code $($p.ExitCode)."
    }

    Refresh-Env

    $nvcc = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.4\bin\nvcc.exe'
    if (-not (Test-Path $nvcc)) {
        throw "CUDA 12.4.1 appears not to be installed correctly (missing $nvcc)."
    }
    Write-Host "[OK] CUDA 12.4.1 (nvcc present)"
}

function Get-InstallableCudaVersions {
    if (-not (Test-Command winget)) { return @() }

    try {
        $out = & winget show --id Nvidia.CUDA --exact --versions --source winget --accept-source-agreements --disable-interactivity 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $out) { return @() }

        $versions = foreach ($line in $out) {
            if ($line -match '^\s*(\d+\.\d+(?:\.\d+)?)\s*$') {
                try {
                    [version]$Matches[1]
                } catch {
                }
            }
        }

        $versions | Sort-Object -Descending -Unique
    } catch {
        @()
    }
}

function Get-LatestCompatibleInstallableCudaVersion {
    param(
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    Get-InstallableCudaVersions |
        Where-Object {
            Test-CudaVersionCompatible -Version $_ -Min $Min -Max $Max -Pinned $Pinned
        } |
        Select-Object -First 1
}

function Get-HigherInstalledCudaVersion {
    param([Parameter(Mandatory = $true)][version]$TargetVersion)

    $targetKey = Get-CudaVersionKey -Version $TargetVersion

    Get-CudaInstalls |
        Where-Object { (Get-CudaVersionKey -Version $_.Version) -gt $targetKey } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

function Get-CudaVersionLabel {
    param([version]$Version)

    if ($Version) { return $Version.ToString(2) }
    return 'none'
}

function Test-WingetCudaSidegradeBlocked {
    param([Parameter(Mandatory = $true)][version]$TargetVersion)

    $targetKey = Get-CudaVersionKey -Version $TargetVersion
    $exactInstall = Get-CudaInstalls | Where-Object {
        (Get-CudaVersionKey -Version $_.Version) -eq $targetKey
    } | Select-Object -First 1

    if ($exactInstall) { return $false }
    return $null -ne (Get-HigherInstalledCudaVersion -TargetVersion $TargetVersion)
}

function Should-InstallNewerCuda {
    param(
        [Parameter(Mandatory = $true)][version]$InstalledVersion,
        [Parameter(Mandatory = $true)][version]$AvailableVersion
    )

    $installedKey = Get-CudaVersionKey -Version $InstalledVersion
    $availableKey = Get-CudaVersionKey -Version $AvailableVersion

    if ($availableKey -le $installedKey) { return $false }

    $blockingHigherCuda = Get-HigherInstalledCudaVersion -TargetVersion $AvailableVersion
    if ($blockingHigherCuda) {
        Write-Warning ("CUDA {0} is installable, but CUDA {1} is already present. winget will not install the older Nvidia.CUDA package side-by-side, so keeping CUDA {2}. To move to CUDA {0}, remove 'NVIDIA CUDA Toolkit {1}' first or install CUDA {0} manually from NVIDIA's archive." -f $AvailableVersion.ToString(2), $blockingHigherCuda.Version.ToString(2), $InstalledVersion.ToString(2))
        return $false
    }

    try {
        Write-Host ""
        Write-Host ("A newer compatible CUDA toolkit is installable: {0} installed, {1} available." -f $InstalledVersion.ToString(), $AvailableVersion.ToString()) -ForegroundColor Yellow
        Write-Host "Press Enter to keep the existing CUDA install, or type 'U' to install the newer compatible version." -ForegroundColor Yellow
        $reply = Read-Host 'CUDA choice'
        return $reply -match '^(u|upgrade|y|yes)$'
    } catch {
        Write-Warning "Could not prompt for CUDA upgrade choice. Keeping the existing installation."
        return $false
    }
}

function Install-CudaToolkitVersion {
    param([Parameter(Mandatory = $true)][version]$Version)

    $versionText = $Version.ToString()
    $versionKey = Get-CudaVersionKey -Version $Version

    if (Test-WingetCudaSidegradeBlocked -TargetVersion $Version) {
        $higher = Get-HigherInstalledCudaVersion -TargetVersion $Version
        throw "Cannot install CUDA $versionText while CUDA $($higher.Version.ToString(2)) is already installed via the Nvidia.CUDA package. winget treats this as a downgrade and does not install the older toolkit side-by-side. Remove 'NVIDIA CUDA Toolkit $($higher.Version.ToString(2))' first, or install CUDA $versionText manually from NVIDIA's archive."
    }

    if ($versionKey -eq [version]'12.4') {
        try {
            Install-Winget -Id 'Nvidia.CUDA' -Version $versionText
        } catch {
            Write-Warning ("winget path failed for CUDA {0}: {1}" -f $versionText, $_.Exception.Message)
            Install-CUDA124-FromNVIDIA
        }

        if (-not (Test-CUDAExact -MajorMinor '12.4')) {
            $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
            throw "CUDA 12.4 did not get installed. Installed versions: $have"
        }
        return
    }

    Install-Winget -Id 'Nvidia.CUDA' -Version $versionText
    Refresh-Env

    $installed = Get-CudaInstalls | Where-Object {
        (Get-CudaVersionKey -Version $_.Version) -eq $versionKey
    } | Select-Object -First 1

    if (-not $installed) {
        $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
        throw "CUDA $versionText did not get installed. Installed versions: $have"
    }
}



function Wait-Until ($TestFn, [int]$TimeoutMin, [string]$What) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $maxLen = 0
    while ($sw.Elapsed.TotalMinutes -lt $TimeoutMin) {
        if (& $TestFn) {
            $msg = "  $($What): done."
            $maxLen = [Math]::Max($maxLen, $msg.Length)
            Write-Host ("`r{0}{1}" -f $msg, ' ' * ($maxLen - $msg.Length)) -NoNewline
            Write-Host ""
            return
        }
        $msg = "  waiting for $($What) ... $($sw.Elapsed.ToString('mm\:ss'))"
        $maxLen = [Math]::Max($maxLen, $msg.Length)
        Write-Host ("`r{0}{1}" -f $msg, ' ' * ($maxLen - $msg.Length)) -NoNewline
        Start-Sleep -Milliseconds 250
    }
    Write-Host ""
    throw "$($What) did not finish in $TimeoutMin minutes."
}


function Refresh-Env {
    # Pull fresh Machine+User env into this process (esp. PATH, CUDA_PATH)
    $machine = [Environment]::GetEnvironmentVariables('Machine')
    $user    = [Environment]::GetEnvironmentVariables('User')

    foreach ($k in $machine.Keys) { Set-Item -Path "Env:$k" -Value $machine[$k] }
    foreach ($k in $user.Keys)    { Set-Item -Path "Env:$k" -Value $user[$k] }

    # Re-compose PATH explicitly (User appended to Machine by convention)
    $rawPath = "$([Environment]::GetEnvironmentVariable('Path','Machine'));$([Environment]::GetEnvironmentVariable('Path','User'))"

    # Filter out MSYS2/Cygwin paths which conflict with MSVC builds
    $parts = $rawPath -split ';' | Where-Object {
        $_ -and $_ -notmatch 'msys64|mingw64|ucrt64|cygwin'
    }
    $env:Path = $parts -join ';'

    # Try to discover native OpenSSL
    $sslRoots = @(
        'C:\Program Files\OpenSSL-Win64',
        'C:\Program Files\OpenSSL'
    )
    $env:OPENSSL_ROOT_DIR = $null
    foreach ($r in $sslRoots) {
        if (Test-Path (Join-Path $r 'include\openssl\ssl.h')) {
            $env:OPENSSL_ROOT_DIR = $r
            break
        }
    }

    if (-not $env:VULKAN_SDK) {
        $sdk = Get-VulkanSdkInstalls | Select-Object -First 1
        if ($sdk) {
            $env:VULKAN_SDK = $sdk.Root
        }
    }
}

function Ensure-CommandAvailable([string]$Cmd, [int]$TimeoutMin = 5) {
    Refresh-Env
    Wait-Until { Test-Command $Cmd } $TimeoutMin "command '$Cmd' to appear on PATH"
}

function Add-ToMachinePath([string]$Dir) {
    if (-not (Test-Path $Dir)) { return }
    $regPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $current = (Get-ItemProperty -Path $regPath -Name Path).Path
    $parts = $current -split ';' | Where-Object { $_ -ne '' }
    if ($parts -contains $Dir) { return }
    $new = ($parts + $Dir) -join ';'
    Set-ItemProperty -Path $regPath -Name Path -Value $new
}

function Assert-LastExitCode([string]$What) {
    if ($LASTEXITCODE -ne 0) {
        throw "$What failed with exit code $LASTEXITCODE."
    }
}

# Run winget non-interactively, force community source, and redirect output to a log
function Install-Winget {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [string]$InstallerArgs = '',   # for MSI and some EXEs; passed to --custom
        [string]$Version = ''
    )
    if (-not (Test-Command winget)) {
        throw "The 'winget' command is not available. Install the Microsoft 'App Installer' from the Store and try again."
    }
    Write-Host "-> installing $Id $($Version) ..."
    $argList = @(
        'install','--id',$Id,
        '--source','winget',              # avoid msstore agreements/UI
        '--silent','--disable-interactivity',
        '--accept-source-agreements','--accept-package-agreements'
    )
    if ($Version) {
        $argList += @('--version', $Version)
    }
    if ($InstallerArgs) {
        $argList += @('--custom', $InstallerArgs)
    }

    $log = Join-Path $env:TEMP ("winget_install_{0}.log" -f ($Id -replace '[^A-Za-z0-9]+','_'))

    & winget @argList *> $log
    $exitCode = $LASTEXITCODE

    # -1978335189: "no applicable upgrade found" (OK for up-to-date installs)
    # -1978335212: "no package found matching input criteria"
    if ($Version -and $exitCode -eq -1978335212) {
        throw "winget could not find $Id version $Version. See log: $log"
    }
    if ($exitCode -and $exitCode -notin @(-1978335189, -1978335212)) {
        throw "winget failed (exit $exitCode) while installing $Id. See log: $log"
    }

    Refresh-Env

}

function Install-VSTools {
    # Require winget (silent + no GUI)
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "The 'winget' command is not available. Install the Microsoft 'App Installer' from the Store and try again."
    }

    Write-Host "-> installing VS 2022 Build Tools (silent, via winget) ..."
    $installPath = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools'

    # Common component set
    $customCommon = @(
        '--add Microsoft.VisualStudio.Workload.VCTools',
        '--add Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '--add Microsoft.VisualStudio.Component.VC.CoreBuildTools',
        '--add Microsoft.VisualStudio.Component.VC.Redist.14.Latest',
        '--includeRecommended',
        ('--installPath "{0}"' -f $installPath)
    ) -join ' '

    # Prefer Win11 SDK; fall back to Win10 SDK if not available on this machine/feed
    $customWin11 = "$customCommon --add Microsoft.VisualStudio.Component.Windows11SDK.22621"
    $customWin10 = "$customCommon --add Microsoft.VisualStudio.Component.Windows10SDK.19041"

    $logDir = Join-Path $env:TEMP "vsbuildtools_logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $log = Join-Path $logDir "winget_vstools.log"

    # Kill any running VS installer UI just in case
    Get-Process -Name "vs_installer","VisualStudioInstaller" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    # Helper to invoke winget silently with a given --custom payload
    function Invoke-VsInstall([string]$customArgs) {
        & winget install --id Microsoft.VisualStudio.2022.BuildTools `
            --source winget `
            --silent --disable-interactivity `
            --accept-source-agreements --accept-package-agreements `
            --custom $customArgs *> $log
        return $LASTEXITCODE
    }

    # Try Win11 SDK set first; if that fails, try Win10 SDK set
    $code = Invoke-VsInstall $customWin11
    if ($code -ne 0 -and $code -ne 3010) {
        Write-Host "  Win11 SDK component not available; retrying with Win10 SDK ..."
        $code = Invoke-VsInstall $customWin10
    }

    if ($code -ne 0 -and $code -ne 3010) {
        throw "VS Build Tools install failed (exit $code). See log: $log"
    }

    Refresh-Env
}

function Wait-VSToolsReady { Wait-Until { Test-VSTools } 20 'Visual Studio Build Tools' }
function Wait-CUDAReady    { Wait-Until { Test-CUDA    } 30 'CUDA Toolkit' }
function Wait-VulkanSdkReady { Wait-Until { Test-VulkanSdk } 10 'Vulkan SDK' }

# Bring MSVC variables (cl, link, lib paths, etc.) into this PowerShell session
function Import-VSEnv {
    $vswhere = Join-Path ${Env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsroot  = & $vswhere -latest -products * `
               -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
               -property installationPath 2>$null
    if (-not $vsroot) { throw "VS Build Tools not found." }

    $vcvars = Join-Path $vsroot 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) {
        throw "VS C++ Build Tools look registered at '$vsroot' but vcvars64.bat is missing.
Try re-installing the Build Tools with the Windows SDK component (see Install-VSTools)."
    }

    Write-Host "  importing MSVC environment from $vcvars"
    $envDump = cmd /s /c "`"$vcvars`" && set"
    foreach ($line in $envDump -split "`r?`n") {
        if ($line -match '^(.*?)=(.*)$') {
            $name,$value = $Matches[1],$Matches[2]
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}

# Ninja: install portable to C:\Program Files\Ninja and add to PATH
function Install-NinjaPortable {
    if (Test-Command ninja) { return }
    Write-Host "-> installing Ninja (portable) ..."
    $url  = 'https://github.com/ninja-build/ninja/releases/latest/download/ninja-win.zip'
    $zip  = Join-Path $env:TEMP 'ninja-win.zip'
    $dest = 'C:\Program Files\Ninja'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $dest -Force
    Remove-Item $zip -Force
    Add-ToMachinePath $dest
    Refresh-Env
    Ensure-CommandAvailable -Cmd 'ninja' -TimeoutMin 2
    Write-Host "[OK] Ninja"
}

# If the selected backend or toolchain changed since the last configure, clear
# the cache so CMake does not try to reuse incompatible settings.
function Reset-CMakeCacheIfBuildSignatureChanged {
    param(
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$Signature
    )

    $signaturePath = Join-Path $BuildDir '.llama-installer-build-signature'
    $previousSignature = if (Test-Path $signaturePath) { Get-Content $signaturePath -Raw } else { $null }

    if ($previousSignature -eq $Signature) { return }

    $cachePath = Join-Path $BuildDir 'CMakeCache.txt'
    $resolvedBuildDir = (Resolve-Path -LiteralPath $BuildDir).Path
    $resolvedRepoRoot = (Resolve-Path -LiteralPath (Join-Path $ScriptRoot 'vendor\llama.cpp')).Path
    if (-not $resolvedBuildDir.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset CMake cache outside the vendored llama.cpp tree: $resolvedBuildDir"
    }

    if (Test-Path $cachePath) {
        Write-Host "-> Build backend changed; clearing cached CMake configuration in $resolvedBuildDir" -ForegroundColor Yellow
        Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue
    }

    $cacheDir = Join-Path $BuildDir 'CMakeFiles'
    if (Test-Path $cacheDir) {
        Remove-Item -LiteralPath $cacheDir -Recurse -Force
    }
}

function Set-BuildSignature {
    param(
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$Signature
    )

    $signaturePath = Join-Path $BuildDir '.llama-installer-build-signature'
    Set-Content -LiteralPath $signaturePath -Value $Signature -NoNewline
}

# Select newest CUDA (>=12.4), export env, return CMake arg
function Use-LatestCuda {
    param(
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    $installs = Get-CompatibleCudaInstalls -Min $Min -Max $Max -Pinned $Pinned
    $pick = $installs | Select-Object -First 1

    if (-not $pick) {
        $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
        if ($Pinned) {
            throw "No CUDA version matching $($Pinned.ToString(2)) found. Installed versions: $have"
        }
        if ($Max) {
            throw "No CUDA version between $($Min.ToString(2)) and $($Max.ToString(2)) found. Installed versions: $have"
        }
        throw "No CUDA version >= $($Min.ToString(2)) found. Installed versions: $have"
    }

    $env:CUDA_PATH = $pick.Path
    $envName = "CUDA_PATH_V{0}_{1}" -f $pick.Major, $pick.Minor
    Set-Item -Path ("Env:$envName") -Value $pick.Path
    $cudaBin = Join-Path $pick.Path 'bin'
    if (-not ($env:Path -split ';' | Where-Object { $_ -ieq $cudaBin })) { $env:Path = "$cudaBin;$env:Path" }

    Write-Host "  Using CUDA toolkit $($pick.Version) at $($pick.Path)"
    "-DCUDAToolkit_ROOT=$($pick.Path)"
}

# Auto-detect CUDA architecture without nvidia-smi.exe
function Get-GpuCudaArch {
    # Try NVML (driver component) first
    $nvmlDirs = @(
        (Join-Path ${Env:ProgramFiles} 'NVIDIA Corporation\NVSMI'),
        "$env:SystemRoot\System32",
        "$env:SystemRoot\SysWOW64"
    ) | Where-Object { Test-Path (Join-Path $_ 'nvml.dll') }

    $cs = @"
using System;
using System.Runtime.InteropServices;
public static class NvmlHelper {
    [DllImport("kernel32.dll", SetLastError = true, CharSet=CharSet.Unicode)]
    public static extern bool SetDllDirectory(string lpPathName);

    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlInit_v2();
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlShutdown();
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetCount_v2(out int count);
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);
    [DllImport("nvml.dll", CallingConvention = CallingConvention.Cdecl)]
    private static extern int nvmlDeviceGetCudaComputeCapability(IntPtr device, out int major, out int minor);

    public static int GetMaxSm() {
        int rc = nvmlInit_v2();
        if (rc != 0) return -1;
        try {
            int count;
            rc = nvmlDeviceGetCount_v2(out count);
            if (rc != 0 || count < 1) return -1;
            int best = -1;
            for (uint i = 0; i < count; i++) {
                IntPtr dev;
                rc = nvmlDeviceGetHandleByIndex_v2(i, out dev);
                if (rc != 0) continue;
                int maj, min;
                rc = nvmlDeviceGetCudaComputeCapability(dev, out maj, out min);
                if (rc != 0) continue;
                int sm = maj * 10 + min;
                if (sm > best) best = sm;
            }
            return best;
        } finally {
            nvmlShutdown();
        }
    }
}
"@

    # Compile the helper just once
    try { Add-Type -TypeDefinition $cs -Language CSharp -ErrorAction Stop | Out-Null } catch { }

    foreach ($dir in $nvmlDirs) {
        try {
            [NvmlHelper]::SetDllDirectory($dir) | Out-Null
            $sm = [NvmlHelper]::GetMaxSm()
            if ($sm -ge 10) { return [int]$sm } # e.g., 86, 89, 75, ...
        } catch { }
    }

    # Fallback: heuristic via GPU name (WMI)
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
                Where-Object { $_.AdapterCompatibility -like '*NVIDIA*' } |
                Select-Object -First 1
        if ($gpu) {
            $name = $gpu.Name
            $map = @(
                @{ Re = 'RTX\s*50|Blackwell|GB\d{3}'; SM = 100 } # best guess
                @{ Re = 'RTX\s*4\d|RTX\s*40|Ada|^AD';        SM = 89 }
                @{ Re = 'RTX\s*3\d|RTX\s*30|A[4-9]000|A30|A40|^GA|MX[34]50'; SM = 86 }
                @{ Re = 'RTX\s*2\d|RTX\s*20|Quadro\s*RTX|TITAN\s*RTX|T4|GTX\s*16|TU\d{2}'; SM = 75 }
                @{ Re = 'GTX\s*10|^GP|P10|P40|TITAN\s*Xp|TITAN\s*X\b';       SM = 61 }
                @{ Re = 'GTX\s*9|^GM|Tesla\s*M';                             SM = 52 }
                @{ Re = 'GTX\s*7|GTX\s*8|^GK|Tesla\s*K|K80|GT\s*7';          SM = 35 }
            )
            foreach ($m in $map) { if ($name -match $m.Re) { return [int]$m.SM } }
        }
    } catch { }

    return $null  # unknown
}

# ---------------------------------------------------------------------------
# Main routine
# ---------------------------------------------------------------------------

Assert-Admin

# --- Base prerequisites (excluding CUDA, which is handled dynamically) ---
$reqs = @(
    @{
        Name          = 'Git'
        Test          = { Test-Command git }
        Id            = 'Git.Git'
        Cmd           = 'git'
        InstallerArgs = '/VERYSILENT /NORESTART /SP- /NOCANCEL'  # Inno Setup
    },
    @{
        Name          = 'CMake'
        Test          = { Test-Command cmake }
        Id            = 'Kitware.CMake'
        Cmd           = 'cmake'
        InstallerArgs = 'ADD_CMAKE_TO_PATH=System ALLUSERS=1'     # MSI properties; 100% silent
    },
    @{
        Name     = 'VS Build Tools'
        Test     = { Test-VSTools }
        Id       = 'Microsoft.VisualStudio.2022.BuildTools'
        # Installed via dedicated function (quiet)
    },
    @{
        Name          = 'Ninja'
        Test          = { Test-Command ninja }
        Id            = 'Ninja-build.Ninja'
        Cmd           = 'ninja'
    }
)

$SelectedBackend = Resolve-Backend -Requested $Backend
$GraphicsSummary = Get-GraphicsSummary
$DetectedSm = $null
$RequiredCudaVersion = [version]'12.4'
$MaxCompatibleCudaVersion = $MaxCudaVersion
$EffectivePinnedCudaVersion = $PinnedCudaVersion
$HadCompatibleCudaBeforeInstall = $false
$backendPrereq = $null

if ($GraphicsSummary.Names.Count -gt 0) {
    Write-Host ("-> Detected display adapters: {0}" -f ($GraphicsSummary.Names -join '; '))
}
Write-Host ("-> Selected backend: {0}" -f $SelectedBackend) -ForegroundColor Cyan

switch ($SelectedBackend) {
    'cuda' {
        $DetectedSm = Get-GpuCudaArch
        $backendPrereq = @{
            Name    = 'CUDA Toolkit'
            Test    = { Test-CompatibleCudaInstalled -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion }
            Id      = 'Nvidia.CUDA'
            Version = ''
        }

        if ($DetectedSm) {
            if ($DetectedSm -lt 70) {
                if ($PinnedCudaVersion -and (Get-CudaVersionKey -Version $PinnedCudaVersion) -ne [version]'12.4') {
                    throw "Detected sm_$DetectedSm requires CUDA 12.4 for compatibility. Requested pinned CUDA version: $($PinnedCudaVersion.ToString(2))."
                }
                Write-Host "-> GPU detected: sm_$DetectedSm (pre-Turing) – selecting CUDA 12.4 for compatibility."
                $backendPrereq.Name    = 'CUDA Toolkit 12.4'
                $backendPrereq.Version = '12.4.1'
                $backendPrereq.Test    = { Test-CUDAExact -MajorMinor '12.4' }
                $RequiredCudaVersion = [version]'12.4'
                $MaxCompatibleCudaVersion = [version]'12.4'
                $EffectivePinnedCudaVersion = [version]'12.4'
            } elseif ($DetectedSm -ge 100) {
                Write-Host "-> GPU detected: sm_$DetectedSm (Blackwell) – selecting CUDA 12.8+ for optimal performance."
                $backendPrereq.Name    = 'CUDA Toolkit 12.8'
                $backendPrereq.Version = '12.8.0'
                $RequiredCudaVersion = [version]'12.8'
            } else {
                Write-Host "-> GPU detected: sm_$DetectedSm – selecting latest CUDA."
            }
        } else {
            Write-Host "-> GPU SM could not be determined pre-install – selecting latest CUDA."
        }

        if ($MaxCompatibleCudaVersion) {
            $requiredKey = Get-CudaVersionKey -Version $RequiredCudaVersion
            $maxKey = Get-CudaVersionKey -Version $MaxCompatibleCudaVersion
            if ($maxKey -lt $requiredKey) {
                throw "Configured MaxCudaVersion $($MaxCompatibleCudaVersion.ToString(2)) is below the required CUDA version $($RequiredCudaVersion.ToString(2))."
            }
        }

        if ($EffectivePinnedCudaVersion) {
            $requiredKey = Get-CudaVersionKey -Version $RequiredCudaVersion
            $pinnedKey = Get-CudaVersionKey -Version $EffectivePinnedCudaVersion
            if ($pinnedKey -lt $requiredKey) {
                throw "Configured PinnedCudaVersion $($EffectivePinnedCudaVersion.ToString(2)) is below the required CUDA version $($RequiredCudaVersion.ToString(2))."
            }
        }

        if ($EffectivePinnedCudaVersion) {
            Write-Host ("-> CUDA pin active: {0}" -f $EffectivePinnedCudaVersion.ToString(2)) -ForegroundColor Cyan
        } elseif ($MaxCompatibleCudaVersion) {
            Write-Host ("-> CUDA cap active: using/installing at most CUDA {0}" -f $MaxCompatibleCudaVersion.ToString(2)) -ForegroundColor Cyan
        }

        $HadCompatibleCudaBeforeInstall = (Get-CompatibleCudaInstalls -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion | Select-Object -First 1) -ne $null
    }
    'vulkan' {
        $backendPrereq = @{
            Name = 'Vulkan SDK'
            Test = { Test-VulkanSdk }
            Id   = 'KhronosGroup.VulkanSDK'
            Cmd  = 'glslc'
        }
        Write-Host "-> Vulkan backend selected. This is the recommended Windows path for AMD and Intel GPUs."
    }
    'cpu' {
        Write-Host "-> CPU backend selected. GPU acceleration will be disabled at build time."
    }
}

if ($backendPrereq) {
    $reqs += $backendPrereq
}


# --- Install all prerequisites ---
foreach ($r in $reqs) {
    if (-not (& $r.Test)) {
        switch ($r.Name) {
            'VS Build Tools' {
                Install-VSTools
                Wait-VSToolsReady
            }
            'CUDA Toolkit 12.4' {
                try {
                    # Try winget first (if it has that exact minor)
                    Install-Winget -Id $r.Id -Version $r.Version
                } catch {
                    Write-Warning "winget path failed for CUDA 12.4.1: $($_.Exception.Message)"
                    Install-CUDA124-FromNVIDIA            # <<< direct NVIDIA fallback
                }
                # After either path, verify
                if (-not (Test-CUDAExact -MajorMinor '12.4')) {
                    $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
                    throw "CUDA 12.4 did not get installed. Installed versions: $have"
                }
            }
            'Vulkan SDK' {
                Install-Winget -Id $r.Id
                Wait-VulkanSdkReady
            }
            default {
                $installerArgs = $r.ContainsKey('InstallerArgs') ? $r['InstallerArgs'] : ''
                $version = $r.ContainsKey('Version')       ? $r['Version']       : ''
                if ($r.Id -eq 'Nvidia.CUDA' -and [string]::IsNullOrWhiteSpace($version)) {
                    $targetCuda = Get-LatestCompatibleInstallableCudaVersion -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion
                    if (-not $targetCuda) {
                        throw "No compatible CUDA toolkit is currently installable for the configured range. Required: >= $($RequiredCudaVersion.ToString(2)); Max: $(Get-CudaVersionLabel -Version $MaxCompatibleCudaVersion); Pinned: $(Get-CudaVersionLabel -Version $EffectivePinnedCudaVersion)."
                    }
                    Install-CudaToolkitVersion -Version $targetCuda
                } else {
                    Install-Winget -Id $r.Id -InstallerArgs $installerArgs -Version $version
                    if ($r.Name -ne 'Ninja') {
                        if ($r.ContainsKey('Cmd') -and $r['Cmd']) {
                            Ensure-CommandAvailable -Cmd $r['Cmd'] -TimeoutMin 5
                        } else {
                            Refresh-Env
                        }
                    }
                }
            }
        }
        if (-not (& $r.Test)) {
            throw "$($r.Name) could not be installed automatically."
        }
    }
    Write-Host ("[OK] {0}" -f $r.Name)
}

# Ninja: install portable (more reliable than winget IDs/sources)
if (-not (Test-Command ninja)) {
    Install-NinjaPortable
} else {
    Write-Host "[OK] Ninja"
}

if ($SkipBuild) { Write-Host 'SkipBuild set – done.'; return }

if ($SelectedBackend -eq 'cuda' -and $HadCompatibleCudaBeforeInstall) {
    $installedCuda = Get-CompatibleCudaInstalls -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion | Select-Object -First 1
    $availableCuda = Get-LatestCompatibleInstallableCudaVersion -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion

    if ($installedCuda -and $availableCuda) {
        if (Should-InstallNewerCuda -InstalledVersion $installedCuda.Version -AvailableVersion $availableCuda) {
            Write-Host ("-> Installing newer compatible CUDA toolkit {0} ..." -f $availableCuda.ToString()) -ForegroundColor Cyan
            Install-CudaToolkitVersion -Version $availableCuda
        } else {
            Write-Host ("-> Keeping installed CUDA toolkit {0}." -f $installedCuda.Version.ToString()) -ForegroundColor Gray
        }
    }
}

$backendCmakeArgs = @()
$BuildSignature = "backend=$SelectedBackend"

switch ($SelectedBackend) {
    'cuda' {
        $hasCompatible = Get-CompatibleCudaInstalls -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion | Select-Object -First 1
        if (-not $hasCompatible) {
            $expected = if ($EffectivePinnedCudaVersion) {
                $EffectivePinnedCudaVersion.ToString(2)
            } elseif ($MaxCompatibleCudaVersion) {
                "$($RequiredCudaVersion.ToString(2)) through $($MaxCompatibleCudaVersion.ToString(2))"
            } else {
                "$($RequiredCudaVersion.ToString(2)) or newer"
            }
            $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
            throw "CUDA $expected did not get installed. Installed versions: $have"
        }

        $cudaRootArg = Use-LatestCuda -Min $RequiredCudaVersion -Max $MaxCompatibleCudaVersion -Pinned $EffectivePinnedCudaVersion
        $CudaArchArg = $DetectedSm ? "$DetectedSm" : 'native'
        if ($DetectedSm) {
            Write-Host ("-> Using detected compute capability sm_{0}" -f $DetectedSm)
        } else {
            Write-Host "-> Using CMAKE_CUDA_ARCHITECTURES=native (toolkit will detect during compile)."
        }

        $backendCmakeArgs += '-DGGML_CUDA=ON'
        $backendCmakeArgs += '-DGGML_CUBLAS=ON'
        $backendCmakeArgs += '-DGGML_VULKAN=OFF'
        $backendCmakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON'
        $backendCmakeArgs += "-DCMAKE_CUDA_ARCHITECTURES=$CudaArchArg"
        if ($cudaRootArg) {
            $backendCmakeArgs += $cudaRootArg
        }
        $BuildSignature = "$BuildSignature;cuda=$($env:CUDA_PATH);arch=$CudaArchArg"
    }
    'vulkan' {
        $vulkanArgs = Use-VulkanSdk
        $backendCmakeArgs += '-DGGML_CUDA=OFF'
        $backendCmakeArgs += '-DGGML_VULKAN=ON'
        $backendCmakeArgs += $vulkanArgs
        $BuildSignature = "$BuildSignature;vulkan=$($env:VULKAN_SDK)"
    }
    'cpu' {
        $backendCmakeArgs += '-DGGML_CUDA=OFF'
        $backendCmakeArgs += '-DGGML_VULKAN=OFF'
    }
}

# ---------------------------------------------------------------------------
# Clone & build ggerganov/llama.cpp
# ---------------------------------------------------------------------------

$LlamaRepo   = Join-Path $ScriptRoot 'vendor\llama.cpp'
$LlamaBuild  = Join-Path $LlamaRepo  'build'

if (-not (Test-Path $LlamaRepo)) {
    Write-Host "-> cloning upstream llama.cpp into $LlamaRepo"
    git clone https://github.com/ggerganov/llama.cpp $LlamaRepo
    Assert-LastExitCode "git clone"
} else {
    Write-Host "-> updating existing llama.cpp in $LlamaRepo"
    git -C $LlamaRepo pull --ff-only
    Assert-LastExitCode "git pull"
}

git -C $LlamaRepo submodule update --init --recursive
Assert-LastExitCode "git submodule update"

Refresh-Env
New-Item $LlamaBuild -ItemType Directory -Force | Out-Null
Reset-CMakeCacheIfBuildSignatureChanged -BuildDir $LlamaBuild -Signature $BuildSignature
Import-VSEnv   # make cl.exe etc. available in this session after any env refreshes/install steps
Push-Location $LlamaBuild

try {
    Write-Host '-> generating upstream llama.cpp solution ...'
    $cmakeArgs = @(
        '..', '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DLLAMA_CURL=OFF'
    )
    $cmakeArgs += $backendCmakeArgs

    $hasNativeOpenSSL = $env:OPENSSL_ROOT_DIR -and `
        (Test-Path $env:OPENSSL_ROOT_DIR) -and `
        (Test-Path (Join-Path $env:OPENSSL_ROOT_DIR 'include\openssl\ssl.h'))

    if ($hasNativeOpenSSL) {
        Write-Host ("-> Native OpenSSL detected at {0}; enabling HTTPS support." -f $env:OPENSSL_ROOT_DIR)
        $cmakeArgs += '-DLLAMA_OPENSSL=ON'
        $cmakeArgs += "-DOPENSSL_ROOT_DIR=$env:OPENSSL_ROOT_DIR"
    } else {
        Write-Host "-> Native OpenSSL not detected; disabling HTTPS support for this build."
        $cmakeArgs += '-DLLAMA_OPENSSL=OFF'
    }

    cmake @cmakeArgs
    Assert-LastExitCode "cmake configure"
    Set-BuildSignature -BuildDir $LlamaBuild -Signature $BuildSignature

    Write-Host '-> building upstream llama.cpp tools (Release) ...'
    cmake --build . --config Release --target llama-server llama-batched-bench llama-cli llama-bench llama-fit-params --parallel
    Assert-LastExitCode "cmake build"
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host ("Done!  llama.cpp binaries are in: ""{0}""." -f (Join-Path $LlamaBuild 'bin'))
