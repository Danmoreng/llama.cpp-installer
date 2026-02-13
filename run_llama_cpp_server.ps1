<#  run_llama_cpp_server.ps1  PowerShell 7
    ----------------------------------------------------------
    • Stores GGUF under .\models\ next to this script
    • Downloads multiple models
    • Starts llama-server in router mode (no --model)
    • Lets llama.cpp auto-fit GPU layers / tensor split / ctx
#>

param(
    [switch]$UseWSL
)

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

if ($UseWSL) {
    Write-Host "-> Running llama-server via WSL..." -ForegroundColor Cyan
    $WslModelDir = "/mnt/c" + ($ScriptRoot.Replace("C:", "").Replace("\", "/")) + "/models"
    $WslServerExe = "~/llama.cpp-build/llama.cpp/build/bin/llama-server"
    
    # Check if build exists in WSL
    $check = wsl -d Ubuntu -e bash -c "if [ -f $WslServerExe ]; then echo 'found'; fi"
    if ($check -ne "found") {
        throw "llama-server not found in WSL. Run .\install_llama_cpp.ps1 -UseWSL first."
    }

    $physicalCores = (wsl -d Ubuntu -e nproc)
    
    $Args = @(
        '--jinja',
        '--flash-attn', 'on',
        '--no-mmap',
        '--threads', $physicalCores,
        '--models-dir', $WslModelDir,
        '--fit-target', '512',
        '--fit-ctx', '32768',
        '--host', '0.0.0.0'
    )
    
    Write-Host "-> Starting llama-server in WSL on http://localhost:8080 ..."
    wsl -d Ubuntu -e bash -c "$WslServerExe $($Args -join ' ')"
    exit
}

$ServerExe  = Join-Path $ScriptRoot 'vendor\llama.cpp\build\bin\llama-server.exe'

if (-not (Test-Path $ServerExe)) {
    throw "llama-server.exe not found at '$ServerExe' – check the path."
}

$ModelDir = Join-Path $ScriptRoot 'models'

# === Models you want available in router mode ===================
# Add/remove URLs here; they will be auto-discovered by llama-server
$ModelUrls = @(
    # GLM-4.7-Flash Q8_0 (30B-A3B MoE)
    'https://huggingface.co/unsloth/GLM-4.7-Flash-GGUF/resolve/main/GLM-4.7-Flash-Q8_0.gguf',

    # Qwen3 4B Instruct Q8_0
    'https://huggingface.co/ggml-org/Qwen3-4B-Instruct-2507-Q8_0-GGUF/resolve/main/qwen3-4b-instruct-2507-q8_0.gguf'
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
