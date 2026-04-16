<#  run_gemma4_26b_a4b_server.ps1  PowerShell 7
    ----------------------------------------------------------
    Dedicated launcher for Gemma 4 26B A4B (MoE) in llama.cpp.
    Tuned for local coding use on a single-GPU Windows machine,
    with ngram-mod enabled by default for iterative code editing.
#>

param(
    [switch]$DisableNgramMod,
    [switch]$NoBrowser,
    [int]$FitContext = 32768,
    [int]$FitTargetMB = 256,
    [int]$BatchSize = 1024,
    [int]$UBatchSize = 512
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'
$ModelDir   = Join-Path $ScriptRoot 'models'

# Prefer an existing local Q4_K_M GGUF to avoid re-downloading ~17 GiB.
$PreferredModelNames = @(
    'gemma-4-26B-A4B-it-Q4_K_M.gguf',
    'gemma-4-26B-A4B-it-UD-Q4_K_M.gguf'
)

$ModelUrl = 'https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_K_M.gguf'
$ModelAlias = 'gemma-4-26b-a4b-code'

function Download-IfNeeded {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (Test-Path $Destination) {
        Write-Host "[OK] Cached -> $Destination"
        return
    }

    New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null
    Write-Host "-> Downloading Gemma 4 GGUF: $Url"

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        & $curl.Source -L --fail --retry 5 --retry-delay 5 --output $Destination $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed from '$Url' (curl exit code $LASTEXITCODE)."
        }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -ErrorAction Stop
    }
}

function Resolve-ModelPath {
    foreach ($name in $PreferredModelNames) {
        $candidate = Join-Path $ModelDir $name
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $existing = Get-ChildItem -Path $ModelDir -Filter '*gemma-4-26B-A4B*Q4*K*M*.gguf' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $existing) {
        return $existing.FullName
    }

    $downloadTarget = Join-Path $ModelDir 'gemma-4-26B-A4B-it-Q4_K_M.gguf'
    Download-IfNeeded -Url $ModelUrl -Destination $downloadTarget
    return $downloadTarget
}

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe'. Run .\install_llama_cpp.ps1 first."
}

$ModelPath = Resolve-ModelPath

# Prefer physical cores when WMI is accessible. Sandbox-restricted sessions can
# fall back to half the logical cores, which is still reasonable for Windows.
$threads = $null
try {
    $physicalCores = (Get-CimInstance Win32_Processor -ErrorAction Stop | Measure-Object -Property NumberOfCores -Sum).Sum
    if ($physicalCores) {
        $threads = [int]$physicalCores
    }
} catch {
}

if (-not $threads) {
    $threads = [Math]::Max(1, [int]([Environment]::ProcessorCount / 2))
}

# Row-major speedup used in your other launchers as well.
$Env:LLAMA_SET_ROWS = '1'

$Args = @(
    '--model',             $ModelPath,
    '--alias',             $ModelAlias,
    '--jinja',
    '--flash-attn',        'on',
    '--no-mmap',
    '--threads',           $threads,
    '--parallel',          '1',
    '--fit',               'on',
    '--fit-target',        $FitTargetMB,
    '--fit-ctx',           $FitContext,
    '-b',                  $BatchSize,
    '-ub',                 $UBatchSize,
    '-ctk',                'q8_0',
    '-ctv',                'q8_0',
    '--temp',              '1.0',
    '--top-p',             '0.95',
    '--top-k',             '40',
    '--min-p',             '0.01',
    '--presence-penalty',  '0.0',
    '--host',              '0.0.0.0'
)

if (-not $DisableNgramMod) {
    $Args += @(
        '--spec-type',         'ngram-mod',
        '--spec-ngram-size-n', '18',
        '--draft-min',         '6',
        '--draft-max',         '48'
    )
}

$SpecDescription = if ($DisableNgramMod) {
    'disabled'
} else {
    'enabled (ngram-mod, n=18, draft 6..48)'
}

Write-Host "-> Model: $ModelPath"
Write-Host "-> Alias: $ModelAlias"
Write-Host "-> Threads: $threads"
Write-Host "-> Fit context floor: $FitContext"
Write-Host "-> Fit target margin: $FitTargetMB MiB"
Write-Host "-> Speculative decoding: $SpecDescription"
Write-Host "-> Gemma 4 sampling: temp=1.0 top_p=0.95 top_k=40 min_p=0.01"

Write-Host "-> Starting Gemma 4 26B A4B server on http://localhost:8080 ..."
Start-Process -FilePath $ServerExe -ArgumentList $Args -NoNewWindow

if (-not $NoBrowser) {
    Start-Sleep -Seconds 5
    Start-Process 'http://localhost:8080'
}
