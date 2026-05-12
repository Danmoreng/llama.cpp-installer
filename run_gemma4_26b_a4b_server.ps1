<#  run_gemma4_26b_a4b_server.ps1  PowerShell 7
    ----------------------------------------------------------
    Dedicated launcher for Gemma 4 26B A4B (MoE) in llama.cpp.
    Tuned for local coding use on a single-GPU Windows machine,
    with ngram-map-k speculative decoding enabled by default for
    iterative code editing.
#>

param(
    [switch]$NoBrowser,
    [int]$FitContext = 32768,
    [int]$FitTargetMB = 256,
    [int]$BatchSize = 1024,
    [int]$UBatchSize = 512
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'
$ModelPath  = Join-Path $ScriptRoot 'models\gemma-4-26B-A4B-it-MXFP4_MOE.gguf'
$ModelAlias = 'gemma-4-26b-a4b-mxfp4-moe-code'

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe'. Run .\install_llama_cpp.ps1 first."
}

if (-not (Test-Path $ModelPath)) {
    throw "Gemma MXFP4 model not found at '$ModelPath'. Place gemma-4-26B-A4B-it-MXFP4_MOE.gguf in .\models first."
}

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
    '--temp',              '0.2',
    '--top-p',             '0.9',
    '--top-k',             '40',
    '--min-p',             '0.01',
    '--presence-penalty',  '0.0',
    '--reasoning',         'off',
    '--host',              '0.0.0.0',
    '--spec-type',                  'ngram-map-k',
    '--spec-ngram-map-k-size-n',    '16',
    '--spec-draft-n-min',           '12',
    '--spec-draft-n-max',           '48'
)

Write-Host "-> Model: $ModelPath"
Write-Host "-> Alias: $ModelAlias"
Write-Host "-> Threads: $threads"
Write-Host "-> Fit context floor: $FitContext"
Write-Host "-> Fit target margin: $FitTargetMB MiB"
Write-Host "-> Speculative decoding: enabled (ngram-map-k, n=16, draft 12..48)"
Write-Host "-> Gemma 4 sampling: temp=0.2 top_p=0.9 top_k=40 min_p=0.01"
Write-Host "-> Gemma 4 reasoning: off"

Write-Host "-> Starting Gemma 4 26B A4B server on http://localhost:8080 ..."
Start-Process -FilePath $ServerExe -ArgumentList $Args -NoNewWindow

if (-not $NoBrowser) {
    Start-Sleep -Seconds 5
    Start-Process 'http://localhost:8080'
}
