<#  run_llama_cpp_server.ps1  PowerShell 7
    ----------------------------------------------------------
    • Stores GGUF under .\models\ next to this script
    • Resumable download via BITS, fallback = Invoke-WebRequest
    • Launches llama-server.exe from llama.cpp with Qwen-3 4B
#>

param([int]$Threads = 8)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe' – check the path."
}

$ModelDir       = Join-Path $ScriptRoot 'models'
# Qwen3 4B Q8 gguf
$ModelUrl       = 'https://huggingface.co/ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF/resolve/main/qwen3-4b-instruct-2507-q8_0.gguf'
$ModelFile      = Join-Path $ModelDir (Split-Path $ModelUrl -Leaf)

function Download-IfNeeded {
    param([string]$Url, [Alias('Dest')][string]$Destination)
    if (Test-Path $Destination) {
        Write-Host "[OK] Cached → $Destination"
        return
    }
    New-Item -ItemType Directory -Path (Split-Path $Destination) -Force | Out-Null
    Write-Host "→ downloading: $Url"
    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        Start-BitsTransfer -Source $Url -Destination $Destination
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination
    }
    Write-Host "[OK] Download complete."
}

Download-IfNeeded -Url $ModelUrl      -Destination $ModelFile

# Row-major speedup
$Env:LLAMA_SET_ROWS = '1'

$Args = @(
    '--jinja',
    '--model',             $ModelFile,
    '--threads',           $Threads,
    '-ngl',                '999',
    '--ctx-size',          '32768', # Recommended starting context size
    '--temp',              '0.7',   # Recommended temperature
    '--top-p',             '0.8',   # Recommended top-p
    '--top-k',             '20',    # Recommended top-k
    '--min-p',             '0.0',   # Recommended min-p
    '--presence-penalty',  '1.5'
)

Write-Host "→ Starting llama-server on http://localhost:8080 ..."
Start-Process -FilePath $ServerExe -ArgumentList $Args -NoNewWindow

# Wait a moment for the server to initialize, then open the browser
Start-Sleep -Seconds 5
Start-Process 'http://localhost:8080'
