<#  run_llama_cpp_server.ps1  PowerShell 7
    ----------------------------------------------------------
    • Stores GGUF under .\models\ next to this script
    • Downloads multiple models
    • Starts llama-server in router mode (no --model)
    • Lets llama.cpp auto-fit GPU layers / tensor split / ctx
#>

param()

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe' – check the path."
}

$ModelDir = Join-Path $ScriptRoot 'models'

# === Models you want available in router mode ===================
# Add/remove URLs here; they will be auto-discovered by llama-server
$ModelUrls = @(
    # Qwen3 4B Instruct Q8_0
    'https://huggingface.co/ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF/resolve/main/qwen3-4b-instruct-2507-q8_0.gguf',

    # Granite 4.0 micro Q8_0
    'https://huggingface.co/ibm-granite/granite-4.0-micro-GGUF/resolve/main/granite-4.0-micro-Q8_0.gguf'

    # Uncomment / add more:
    # 'https://huggingface.co/ggml-org/Qwen3-Coder-30B-A3B-Instruct-Q8_0-GGUF/resolve/main/qwen3-coder-30b-a3b-instruct-q8_0.gguf',
    # 'https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-UD-Q3_K_XL.gguf',
    # 'https://huggingface.co/unsloth/granite-4.0-350m-GGUF/resolve/main/granite-4.0-350m-Q8_0.gguf'
)

function Download-IfNeeded {
    param(
        [string]$Url,
        [Alias('Dest')][string]$Destination
    )
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

# Download all configured models into .\models
foreach ($url in $ModelUrls) {
    $file = Join-Path $ModelDir (Split-Path $url -Leaf)
    Download-IfNeeded -Url $url -Destination $file
}

# Row-major speedup
$Env:LLAMA_SET_ROWS = '1'

# === llama-server router mode with auto-fit =====================
$Args = @(
    '--jinja',

    # Router mode: do NOT pass --model
    '--models-dir',   $ModelDir,   # discover GGUFs from .\models

    # Automatic parameter fitting (on by default in recent llama.cpp)
    # These tune GPU layers / tensor split / tensor overrides, and
    # can shrink context until it fits in VRAM.
    '--fit-target',   '128',      # MiB of free VRAM to leave per GPU (tweak if you like)
    '--fit-ctx',      '32768'      # minimum context size auto-fit is allowed to shrink to
)

Write-Host "→ Starting llama-server (router mode) on http://localhost:8080 ..."
Start-Process -FilePath $ServerExe -ArgumentList $Args -NoNewWindow

Start-Sleep -Seconds 5
Start-Process 'http://localhost:8080'
