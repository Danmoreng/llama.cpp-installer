<#
  rebuild_llama_cpp.ps1

  Build helper for vendor\llama.cpp without requiring the full elevated installer.
  It imports the Visual Studio C++ environment into the current PowerShell session
  and then runs CMake configure/build from the vendored llama.cpp tree.
#>

[CmdletBinding()]
param(
    [string[]]$Targets = @('llama-server'),
    [int]$Parallel = 1,
    [switch]$Reconfigure,
    [switch]$Clean,
    [ValidateSet('auto', 'cuda', 'vulkan', 'cpu')]
    [string]$Backend = 'auto',
    [version]$PinnedCudaVersion,
    [version]$MaxCudaVersion = [version]'13.1'
)

$ErrorActionPreference = 'Stop'

function Get-GraphicsAdapters {
    try {
        @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop)
    } catch {
        @()
    }
}

function Get-GraphicsSummary {
    $gpus = Get-GraphicsAdapters

    [pscustomobject]@{
        Names     = @($gpus | ForEach-Object { $_.Name } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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

function Get-CudaInstalls {
    $root = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    foreach ($d in Get-ChildItem $root -Directory) {
        $nvcc = Join-Path $d.FullName 'bin\nvcc.exe'
        if (($d.Name -match '^v(\d+)\.(\d+)$') -and (Test-Path $nvcc)) {
            $maj = [int]$Matches[1]
            $min = [int]$Matches[2]
            $out += [pscustomobject]@{
                Version = [version]::new($maj, $min)
                Major   = $maj
                Minor   = $min
                Path    = $d.FullName
            }
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

    if ($key -lt (Get-CudaVersionKey -Version $Min)) { return $false }
    if ($Max -and $key -gt (Get-CudaVersionKey -Version $Max)) { return $false }
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

function Use-LatestCuda {
    param(
        [version]$Min = [version]'12.4',
        [version]$Max = $null,
        [version]$Pinned = $null
    )

    $pick = Get-CompatibleCudaInstalls -Min $Min -Max $Max -Pinned $Pinned | Select-Object -First 1
    if (-not $pick) {
        $have = ((Get-CudaInstalls).Version | ForEach-Object { $_.ToString(2) }) -join ', '
        if ($Pinned) {
            throw "No installed CUDA version matches $($Pinned.ToString(2)). Installed versions: $have"
        }
        if ($Max) {
            throw "No installed CUDA version between $($Min.ToString(2)) and $($Max.ToString(2)) was found. Installed versions: $have"
        }
        throw "No installed CUDA version >= $($Min.ToString(2)) was found. Installed versions: $have"
    }

    $env:CUDA_PATH = $pick.Path
    $envName = "CUDA_PATH_V{0}_{1}" -f $pick.Major, $pick.Minor
    Set-Item -Path ("Env:{0}" -f $envName) -Value $pick.Path
    $cudaBin = Join-Path $pick.Path 'bin'
    if (-not ($env:Path -split ';' | Where-Object { $_ -ieq $cudaBin })) {
        $env:Path = "$cudaBin;$env:Path"
    }

    Write-Host ("-> Using CUDA toolkit {0} at {1}" -f $pick.Version.ToString(2), $pick.Path)
    "-DCUDAToolkit_ROOT=$($pick.Path)"
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

function Use-VulkanSdk {
    $sdk = Get-VulkanSdkInstalls | Select-Object -First 1
    if (-not $sdk) {
        throw "No Vulkan SDK installation was found. Install the LunarG Vulkan SDK or rerun the main installer with -Backend vulkan."
    }

    $env:VULKAN_SDK = $sdk.Root
    if (-not ($env:Path -split ';' | Where-Object { $_ -ieq $sdk.Bin })) {
        $env:Path = "$($sdk.Bin);$env:Path"
    }

    Write-Host ("-> Using Vulkan SDK at {0}" -f $sdk.Root)
    @(
        "-DVulkan_INCLUDE_DIR=$($sdk.Include)"
        "-DVulkan_LIBRARY=$($sdk.Lib)"
        "-DVulkan_GLSLC_EXECUTABLE=$($sdk.Glslc)"
    )
}

function Import-VSEnv {
    $vswhere = Join-Path ${Env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found at '$vswhere'. Install Visual Studio Build Tools first."
    }

    $vsRoot = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath 2>$null

    if ([string]::IsNullOrWhiteSpace($vsRoot)) {
        throw 'Visual Studio Build Tools with the C++ workload were not found.'
    }

    $vcvars = Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) {
        throw "vcvars64.bat not found at '$vcvars'."
    }

    Write-Host "-> Importing MSVC environment from $vcvars"
    $envDump = cmd /s /c "`"$vcvars`" && set"
    foreach ($line in $envDump -split "`r?`n") {
        if ($line -match '^(.*?)=(.*)$') {
            Set-Item -Path ("Env:{0}" -f $Matches[1]) -Value $Matches[2]
        }
    }
}

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
    $resolvedRepoRoot = (Resolve-Path -LiteralPath $LlamaRepo).Path
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

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$LlamaRepo  = Join-Path $ScriptRoot 'vendor\llama.cpp'
$BuildDir   = Join-Path $LlamaRepo  'build'

if (-not (Test-Path $LlamaRepo)) {
    throw "llama.cpp repo not found at '$LlamaRepo'. Run .\install_llama_cpp.ps1 first."
}

if ($MaxCudaVersion -and (Get-CudaVersionKey -Version $MaxCudaVersion) -lt [version]'12.4') {
    throw "Configured MaxCudaVersion $($MaxCudaVersion.ToString(2)) is below the required CUDA version 12.4."
}

if ($PinnedCudaVersion -and (Get-CudaVersionKey -Version $PinnedCudaVersion) -lt [version]'12.4') {
    throw "Configured PinnedCudaVersion $($PinnedCudaVersion.ToString(2)) is below the required CUDA version 12.4."
}

$SelectedBackend = Resolve-Backend -Requested $Backend
$GraphicsSummary = Get-GraphicsSummary
$backendCmakeArgs = @()
$BuildSignature = "backend=$SelectedBackend"

if ($GraphicsSummary.Names.Count -gt 0) {
    Write-Host ("-> Detected display adapters: {0}" -f ($GraphicsSummary.Names -join '; '))
}
Write-Host ("-> Selected backend: {0}" -f $SelectedBackend) -ForegroundColor Cyan

switch ($SelectedBackend) {
    'cuda' {
        $cudaRootArg = Use-LatestCuda -Min ([version]'12.4') -Max $MaxCudaVersion -Pinned $PinnedCudaVersion
        $backendCmakeArgs += '-DGGML_CUDA=ON'
        $backendCmakeArgs += '-DGGML_CUBLAS=ON'
        $backendCmakeArgs += '-DGGML_VULKAN=OFF'
        $backendCmakeArgs += '-DGGML_CUDA_FA_ALL_QUANTS=ON'
        if ($cudaRootArg) {
            $backendCmakeArgs += $cudaRootArg
        }
        $BuildSignature = "$BuildSignature;cuda=$($env:CUDA_PATH)"
    }
    'vulkan' {
        $backendCmakeArgs += '-DGGML_CUDA=OFF'
        $backendCmakeArgs += '-DGGML_VULKAN=ON'
        $backendCmakeArgs += Use-VulkanSdk
        $BuildSignature = "$BuildSignature;vulkan=$($env:VULKAN_SDK)"
    }
    'cpu' {
        $backendCmakeArgs += '-DGGML_CUDA=OFF'
        $backendCmakeArgs += '-DGGML_VULKAN=OFF'
    }
}

Import-VSEnv

if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host "-> Removing existing build directory $BuildDir"
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
Reset-CMakeCacheIfBuildSignatureChanged -BuildDir $BuildDir -Signature $BuildSignature
Push-Location $BuildDir

try {
    if ($Reconfigure -or -not (Test-Path (Join-Path $BuildDir 'CMakeCache.txt'))) {
        Write-Host '-> Configuring llama.cpp with CMake'
        $cmakeArgs = @(
            '..', '-G', 'Ninja',
            '-DCMAKE_BUILD_TYPE=Release',
            '-DLLAMA_CURL=OFF'
        )
        $cmakeArgs += $backendCmakeArgs
        cmake @cmakeArgs
        Set-BuildSignature -BuildDir $BuildDir -Signature $BuildSignature
    }

    Write-Host ("-> Building targets: {0}" -f ($Targets -join ', '))
    cmake --build . --config Release --target @Targets --parallel $Parallel
}
finally {
    Pop-Location
}
