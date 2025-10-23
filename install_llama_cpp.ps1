<#
    install_llama_cpp.ps1
    --------------------
    Installs all prerequisites and builds ggerganov/llama.cpp on Windows.

    • Works on Windows PowerShell 5 and PowerShell 7
    • Uses the Ninja generator (fast, no VS-integration dependency)
    • Re-usable: just run the script; it installs only what is missing
    • Pass -CudaArch <SM> to target a different GPU
      (defaults to 89 = Ada; GTX-1070 = 61, RTX-30-series = 86, etc.)
#>

[CmdletBinding()]
param(
    [int]   $CudaArch = 61,
    [switch]$SkipBuild
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
    $path = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
    -not [string]::IsNullOrWhiteSpace($path)
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

function Test-CUDA {
    $min = [version]'12.4'
    $installs = Get-CudaInstalls
    if (-not $installs) { return $false }
    return ($installs | Where-Object { $_.Version -ge $min } | Select-Object -First 1) -ne $null
}

function Test-CUDAExact {
    param([Parameter(Mandatory=$true)][string]$MajorMinor) # e.g. '12.4'
    $target = [version]("$MajorMinor")
    $hit = Get-CudaInstalls | Where-Object {
        $_.Version.Major -eq $target.Major -and $_.Version.Minor -eq $target.Minor
    } | Select-Object -First 1
    return $null -ne $hit
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
    $env:Path = "$([Environment]::GetEnvironmentVariable('Path','Machine'));$([Environment]::GetEnvironmentVariable('Path','User'))"
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
    Write-Host "-> downloading and installing VS 2022 Build Tools ..."
    $url  = 'https://aka.ms/vs/17/release/vs_BuildTools.exe'
    $exe  = Join-Path $env:TEMP 'vs_BuildTools.exe'
    Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing
    $args = '--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --norestart --wait'
    $p = Start-Process -FilePath $exe -ArgumentList $args -NoNewWindow -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
        throw "VS Build Tools installer failed with exit code $($p.ExitCode)."
    }
    Refresh-Env
}

function Wait-VSToolsReady { Wait-Until { Test-VSTools } 20 'Visual Studio Build Tools' }
function Wait-CUDAReady    { Wait-Until { Test-CUDA    } 30 'CUDA Toolkit' }

# Bring MSVC variables (cl, link, lib paths, etc.) into this PowerShell session
function Import-VSEnv {
    $vswhere = Join-Path ${Env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsroot  = & $vswhere -latest -products * `
               -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
               -property installationPath 2>$null
    if (-not $vsroot) { throw "VS Build Tools not found." }

    $vcvars = Join-Path $vsroot 'VC\Auxiliary\Build\vcvars64.bat'
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

# Select newest CUDA (>=12.4), export env, return CMake arg
function Use-LatestCuda {
    param([version]$Min=[version]'12.4',[version]$Prefer=$null)

    $installs = Get-CudaInstalls | Sort-Object Version -Descending

    if ($Prefer) {
        $pick = $installs | Where-Object {
            $_.Version.Major -eq $Prefer.Major -and $_.Version.Minor -eq $Prefer.Minor
        } | Select-Object -First 1
        if (-not $pick) {
            $have = ($installs.Version | ForEach-Object { $_.ToString(2) }) -join ', '
            throw "Requested CUDA $($Prefer.ToString(2)) not found. Installed versions: $have"
        }
    } else {
        $pick = $installs | Where-Object { $_.Version -ge $Min } | Select-Object -First 1
        if (-not $pick) { throw "No CUDA installation >= $Min found." }
    }

    $env:CUDA_PATH = $pick.Path
    $envName = "CUDA_PATH_V{0}_{1}" -f $pick.Major, $pick.Minor
    Set-Item -Path ("Env:$envName") -Value $pick.Path
    $cudaBin = Join-Path $pick.Path 'bin'
    if (-not ($env:Path -split ';' | Where-Object { $_ -ieq $cudaBin })) { $env:Path = "$cudaBin;$env:Path" }

    Write-Host "  Using CUDA toolkit $($pick.Version) at $($pick.Path)"
    "-DCUDAToolkit_ROOT=$($pick.Path)"
}

# Auto-detect CUDA architecture from nvidia-smi
function Get-GpuCudaArch {
    # Check common locations for nvidia-smi.exe
    $nvsmi_paths = @(
        (Join-Path ${Env:ProgramFiles} 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'),
        ($env:CUDA_PATH ? (Join-Path $env:CUDA_PATH 'bin\nvidia-smi.exe') : ''),
        (Get-Command nvidia-smi -ErrorAction SilentlyContinue)
    )

    $nvsmi = $nvsmi_paths | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $nvsmi) { return $null } # can't detect

    try {
        # Get compute capability for the first GPU, e.g., "8.6"
        $computeCap = & $nvsmi --query-gpu=compute_cap --format=csv,noheader | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($computeCap)) { return $null }

        # Convert to integer format, e.g., 86
        $arch = $computeCap.Trim() -replace '\.', ''
        return [int]$arch
    }
    catch {
        Write-Warning "Failed to run nvidia-smi to detect CUDA arch: $($_.Exception.Message)"
        return $null
    }
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

# --- Detect GPU and select appropriate CUDA toolkit version ---
if (-not $PSBoundParameters.ContainsKey('CudaArch')) {
    $detectedArch = Get-GpuCudaArch
    if ($detectedArch) {
        $CudaArch = $detectedArch
    }
}

$cudaReq = @{
    Name = 'CUDA Toolkit'
    Test = { Test-CUDA }  # default; may be overwritten below
    Id   = 'Nvidia.CUDA'
    Version = ''
}

$PreferCudaVersion = $null
if ($CudaArch -lt 70) {
    Write-Host "-> detected older GPU (sm_$CudaArch), selecting CUDA 12.4 for compatibility."
    $cudaReq.Name    = 'CUDA Toolkit 12.4'
    $cudaReq.Version = '12.4.1'
    $cudaReq.Test    = { Test-CUDAExact -MajorMinor '12.4' }   # <<< change here
    $PreferCudaVersion = [version]'12.4'
} else {
    Write-Host "-> detected modern GPU (sm_$CudaArch) or no GPU, selecting latest CUDA."
    $cudaReq.Name = 'CUDA Toolkit >=12.4'
    $cudaReq.Test = { Test-CUDA }                              # keep generic for latest
}
$reqs += $cudaReq

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
            default {
                $installerArgs = $r.ContainsKey('InstallerArgs') ? $r['InstallerArgs'] : ''
                $version = $r.ContainsKey('Version')       ? $r['Version']       : ''
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

Import-VSEnv   # make cl.exe etc. available in this session

if ($SkipBuild) { Write-Host 'SkipBuild set – done.'; return }

if ($PreferCudaVersion) {
    $hasExact = Get-CudaInstalls | Where-Object {
        $_.Version.Major -eq $PreferCudaVersion.Major -and $_.Version.Minor -eq $PreferCudaVersion.Minor
    } | Select-Object -First 1
    if (-not $hasExact) {
        $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
        throw "CUDA $($PreferCudaVersion.ToString(2)) did not get installed. Installed versions: $have"
    }
}

# --- Select CUDA toolkit and auto-detect architecture ---
$cudaRootArg = Use-LatestCuda -Prefer $PreferCudaVersion

if (-not $PSBoundParameters.ContainsKey('CudaArch')) {
    Write-Host "-> auto-detecting CUDA architecture ..."
    $detectedArch = Get-GpuCudaArch
    if ($detectedArch) {
        $CudaArch = $detectedArch
        Write-Host ("  detected sm_{0} for your GPU" -f $CudaArch)
    } else {
        Write-Host ("  auto-detection failed, using default sm_{0} (GTX 10-series)." -f $CudaArch)
        Write-Host "  (pass -CudaArch <SM> to override; e.g., 86 for RTX 30-series)"
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
} else {
    Write-Host "-> updating existing llama.cpp in $LlamaRepo"
    git -C $LlamaRepo pull --ff-only
}

git -C $LlamaRepo submodule update --init --recursive

# --- configure & build ------------------------------------------------------

New-Item $LlamaBuild -ItemType Directory -Force | Out-Null
Push-Location $LlamaBuild

Write-Host '-> generating upstream llama.cpp solution ...'
cmake .. -G Ninja `
    -DGGML_CUDA=ON -DGGML_CUBLAS=ON `
    -DCMAKE_BUILD_TYPE=Release `
    -DLLAMA_CURL=OFF `
    -DGGML_CUDA_FA_ALL_QUANTS=ON `
    "-DCMAKE_CUDA_ARCHITECTURES=$CudaArch" `
    $cudaRootArg

Write-Host '-> building upstream llama.cpp tools (Release) ...'
cmake --build . --config Release --target llama-server llama-batched-bench llama-cli llama-bench --parallel
Pop-Location

Write-Host ''
Write-Host ("Done!  llama.cpp binaries are in: ""{0}""." -f (Join-Path $LlamaBuild 'bin'))
