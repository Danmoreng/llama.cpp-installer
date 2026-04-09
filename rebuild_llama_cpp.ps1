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
    [version]$PinnedCudaVersion,
    [version]$MaxCudaVersion = [version]'13.1'
)

$ErrorActionPreference = 'Stop'

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

function Reset-CMakeCacheIfCudaChanged {
    param(
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$CudaRoot
    )

    $cachePath = Join-Path $BuildDir 'CMakeCache.txt'
    if (-not (Test-Path $cachePath)) { return }

    $cacheText = Get-Content $cachePath -Raw
    $expectedRoot = $CudaRoot.Replace('\', '/')
    $expectedNvcc = (Join-Path $CudaRoot 'bin\nvcc.exe').Replace('\', '/')
    if ($cacheText -match [regex]::Escape($expectedRoot) -and $cacheText -match [regex]::Escape($expectedNvcc)) {
        return
    }

    $resolvedBuildDir = (Resolve-Path -LiteralPath $BuildDir).Path
    $resolvedRepoRoot = (Resolve-Path -LiteralPath $LlamaRepo).Path
    if (-not $resolvedBuildDir.StartsWith($resolvedRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to reset CMake cache outside the vendored llama.cpp tree: $resolvedBuildDir"
    }

    Write-Host "-> CUDA toolkit changed; clearing cached CMake configuration in $resolvedBuildDir" -ForegroundColor Yellow
    Remove-Item -LiteralPath $cachePath -Force -ErrorAction SilentlyContinue

    $cacheDir = Join-Path $BuildDir 'CMakeFiles'
    if (Test-Path $cacheDir) {
        Remove-Item -LiteralPath $cacheDir -Recurse -Force
    }
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

$cudaRootArg = Use-LatestCuda -Min ([version]'12.4') -Max $MaxCudaVersion -Pinned $PinnedCudaVersion

Import-VSEnv

if ($Clean -and (Test-Path $BuildDir)) {
    Write-Host "-> Removing existing build directory $BuildDir"
    Remove-Item -LiteralPath $BuildDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
Reset-CMakeCacheIfCudaChanged -BuildDir $BuildDir -CudaRoot $env:CUDA_PATH
Push-Location $BuildDir

try {
    if ($Reconfigure -or -not (Test-Path (Join-Path $BuildDir 'CMakeCache.txt'))) {
        Write-Host '-> Configuring llama.cpp with CMake'
        cmake .. -G Ninja `
            -DGGML_CUDA=ON -DGGML_CUBLAS=ON `
            -DCMAKE_BUILD_TYPE=Release `
            -DLLAMA_CURL=OFF `
            -DGGML_CUDA_FA_ALL_QUANTS=ON `
            $cudaRootArg
    }

    Write-Host ("-> Building targets: {0}" -f ($Targets -join ', '))
    cmake --build . --config Release --target @Targets --parallel $Parallel
}
finally {
    Pop-Location
}
