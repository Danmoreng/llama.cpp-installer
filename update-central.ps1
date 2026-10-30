[CmdletBinding()]
param([ValidateRange(1, 64)][int]$Jobs = 6)
$ErrorActionPreference = 'Stop'
$source = 'C:\llama.cpp'
$build = Join-Path $source 'build'
if (-not (Test-Path (Join-Path $source '.git'))) { throw "Missing central checkout: $source" }
$dirty = @(git -C $source status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) { throw 'Central checkout has tracked changes; refusing to update.' }
git -C $source pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'Unable to fast-forward central checkout.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ Build Tools not found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$environment = cmd /s /c "`"$vcvars`" > nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Could not initialize Visual Studio environment.' }
foreach ($line in $environment) {
    if ($line -match '^(.*?)=(.*)$') { Set-Item -Path "Env:$($matches[1])" -Value $matches[2] }
}
cmake -S $source -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120a-real -DGGML_CUDA_FA_ALL_QUANTS=OFF -DGGML_CUDA_FA_QUANTS=all -DGGML_NATIVE=ON -DGGML_AVX512_VNNI=ON -DGGML_AVX_VNNI=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_CURL=OFF
if ($LASTEXITCODE -ne 0) { throw 'Central build configuration failed.' }
cmake --build $build --target llama-server llama-cli llama-completion llama-bench llama-quantize llama-gguf llama-batched-bench llama-fit-params --parallel $Jobs
if ($LASTEXITCODE -ne 0) { throw 'Central build failed.' }
$adapters = @(
    @{ Source='C:/Development/vibe-inference/scripts/bench/llama-fixed-cpu'; Build='C:/Development/vibe-inference/build-llama-fixed-cpu'; Targets=@('llama-fixed-cpu-bench') },
    @{ Source='C:/Development/qwen35-cpu/tools/llama-comparison'; Build='C:/Development/qwen35-cpu/build-llama'; Targets=@('llama-fixed-cpu-bench') },
    @{ Source='C:/Development/qwen35-cpu/tools/llama-comparison'; Build='C:/Development/qwen35-cpu/build-llama-capture'; Targets=@('llama-fixed-cpu-bench') },
    @{ Source='C:/Development/qwen35-cpu/tools/llama-calibration-cuda'; Build='C:/Development/qwen35-cpu/build-llama-calibration-cuda'; Targets=@('llama-calibration-cuda', 'llama-calibration-resident-cuda') }
)
foreach ($adapter in $adapters) {
    if (-not (Test-Path -LiteralPath (Join-Path $adapter.Source 'central-llama.cmake'))) { continue }
    cmake -S $adapter.Source -B $adapter.Build -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCENTRAL_LLAMA_HOME=$source"
    if ($LASTEXITCODE -ne 0) { throw "Adapter configuration failed: $($adapter.Source)" }
    cmake --build $adapter.Build --target @($adapter.Targets) --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw "Adapter build failed after the upstream update: $($adapter.Source)" }
}
& (Join-Path $build 'bin\llama-server.exe') --version
if ($LASTEXITCODE -ne 0) { throw 'Central server version check failed.' }
