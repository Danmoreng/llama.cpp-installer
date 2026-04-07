<#  run_llama_cpp_server.ps1  PowerShell 7
    ----------------------------------------------------------
    • Stores GGUF under .\models\ next to this script
    • Downloads one default model
    • Starts llama-server in router mode
    • Lets llama.cpp auto-fit GPU layers / tensor split / ctx
#>

param()

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe' – check the path."
}

$ModelDir = Join-Path $ScriptRoot 'models'

# Default model to serve
$ModelUrls = @(
    'https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-e4b-it-Q4_K_M.gguf'
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

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        & $curl.Source -L --fail --retry 5 --retry-delay 5 --output $Destination $Url
        if ($LASTEXITCODE -ne 0) {
            throw "Download failed from '$Url' (curl exit code $LASTEXITCODE)."
        }
    } else {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -ErrorAction Stop
    }

    if (-not (Test-Path $Destination)) {
        throw "Download failed. File was not created at '$Destination'."
    }

    Write-Host "[OK] Download complete."
}

# Download the configured model into .\models
foreach ($url in $ModelUrls) {
    $file = Join-Path $ModelDir (Split-Path $url -Leaf)
    Download-IfNeeded -Url $url -Destination $file
}

# Row-major speedup
$Env:LLAMA_SET_ROWS = '1'

# Use physical cores for threads
$physicalCores = (Get-CimInstance Win32_Processor).NumberOfCores
$threads       = if ($physicalCores) { $physicalCores } else { [Environment]::ProcessorCount / 2 }

# === llama-server router mode with auto-fit =====================
$Args = @(
    '--jinja',
    '--flash-attn', 'on',
    '--no-mmap',
    '--threads', $threads,

    # Router mode: do NOT pass --model
    '--models-dir',   $ModelDir,   # discover GGUFs from .\models

    # Automatic parameter fitting (on by default in recent llama.cpp)
    # These tune GPU layers / tensor split / tensor overrides, and
    # can shrink context until it fits in VRAM.
    '--fit-target',   '512',      # MiB of free VRAM to leave per GPU (tweak if you like)
    '--fit-ctx',      '32768'      # minimum context size auto-fit is allowed to shrink to
)

Write-Host "→ Starting llama-server (router mode) on http://localhost:8080 ..."
Start-Process -FilePath $ServerExe -ArgumentList $Args -NoNewWindow

Start-Sleep -Seconds 5
Start-Process 'http://localhost:8080'
