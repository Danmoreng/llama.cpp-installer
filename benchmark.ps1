# benchmark-fit.ps1
# Bench Qwen3-Next-80B using llama.cpp's automatic parameter fitting
# (llama-fit-params + llama-bench).

$ErrorActionPreference = "Stop"

# --- BASE DIR -----------------------------------------------------------------

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$llamaFitExe   = Join-Path $scriptDir "vendor\llama.cpp\build\bin\llama-fit-params.exe"
$llamaBenchExe = Join-Path $scriptDir "vendor\llama.cpp\build\bin\llama-bench.exe"
$modelPath     = Join-Path $scriptDir "models\Qwen3-Next-80B-A3B-Instruct-Q4_K_M.gguf"

# --- CONFIG -------------------------------------------------------------------

# Minimum context size the fitter is allowed to drop to.
# You can add 4096, 8192, 131072, ... as you like.
$fitCtxMinList = @(32768)

# Target free VRAM per GPU (MiB). 1024 is roughly "keep ~1 GiB free".
$fitMarginMBs  = @(256, 512, 1024)

# llama-bench parameters
$batchTokens   = 4096   # -b
$ubatchTokens  = 4096   # -ub
$tgTokens      = 256    # -n (generation length to benchmark)
$repetitions   = 2      # -r (number of benchmark runs)

# Use physical cores instead of logical threads for better Ryzen performance
$physicalCores = (Get-CimInstance Win32_Processor).NumberOfCores
$threads       = if ($physicalCores) { $physicalCores } else { [Environment]::ProcessorCount / 2 }

# Output CSV
$resultCsv = Join-Path $scriptDir "qwen3_next80b_fit_results.csv"

# --- SANITY CHECKS ------------------------------------------------------------

if (-not (Test-Path $llamaFitExe)) {
    Write-Error "llama-fit-params not found at '$llamaFitExe'."
    exit 1
}

if (-not (Test-Path $llamaBenchExe)) {
    Write-Error "llama-bench not found at '$llamaBenchExe'."
    exit 1
}

if (-not (Test-Path $modelPath)) {
    Write-Error "Model file not found at '$modelPath'."
    exit 1
}

# Initialise CSV
if (-not (Test-Path $resultCsv)) {
    "Status,FitCtxMin,FitMarginMB,Batch,UBatch,TgTokens,Threads,TokensPerSec,Backend,FitArgs" |
        Out-File -FilePath $resultCsv -Encoding utf8
}

# --- HELPER: run llama-fit-params and return the fitted CLI args as a string ---

function Get-FittedArgs {
    param(
        [int]$FitCtxMin,
        [int]$FitMarginMB
    )

    Write-Host "  Fitting params (fit-ctx >= $FitCtxMin, margin = $FitMarginMB MiB)..." -ForegroundColor Cyan

    $args = @(
        "-m", "`"$modelPath`""
        "--fit-ctx", $FitCtxMin
        "-fitt", $FitMarginMB
        "-b", $batchTokens
        "-ub", $ubatchTokens
        "-fa", "on"
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $llamaFitExe
    $psi.Arguments              = ($args -join " ")
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $scriptDir

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()

    $stdout   = $proc.StandardOutput.ReadToEnd()
    $stderr   = $proc.StandardError.ReadToEnd()
    $exitCode = $proc.ExitCode

    if ($exitCode -ne 0) {
        Write-Warning "llama-fit-params FAILED (exit $exitCode)."
        if ($stderr) {
            Write-Warning "stderr:"
            $stderr.Split("`r`n")[0..([Math]::Min(5, $stderr.Split("`r`n").Length-1))] | ForEach-Object {
                Write-Warning "  $_"
            }
        }
        return $null
    }

    # The fitted CLI arguments are printed on the last line starting with "-"
    $argLine = $stdout -split "`r?`n" |
        Where-Object { $_ -match '^\s*-' } |
        Select-Object -Last 1

    if (-not $argLine) {
        Write-Warning "Could not find fitted CLI argument line in llama-fit-params output."
        return $null
    }

    # Remove -m/--model (we pass our own), AND -c/--ctx-size (llama-bench doesn't support them)
    $clean = $argLine `
        -replace '(?<!\S)-m\s+(".*?"|\S+)', '' `
        -replace '(?<!\S)--model\s+(".*?"|\S+)', '' `
        -replace '(?<!\S)-c\s+\d+', '' `
        -replace '(?<!\S)--ctx-size\s+\d+', ''

    # Normalise whitespace
    $clean = $clean.Trim()
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '\s+', ' ')

    return $clean
}

# --- HELPER: run one benchmark run with fitted args ---------------------------

function Run-OneBench {
    param(
        [int]$FitCtxMin,
        [int]$FitMarginMB
    )

    $fitArgs = Get-FittedArgs -FitCtxMin $FitCtxMin -FitMarginMB $FitMarginMB

    if (-not $fitArgs) {
        $csvLine = "FitError,$FitCtxMin,$FitMarginMB,$batchTokens,$ubatchTokens,$tgTokens,$threads,0,,"
        Add-Content -Path $resultCsv -Value $csvLine
        return
    }

    Write-Host "  Running llama-bench with fitted args:" -ForegroundColor Yellow
    Write-Host "    $fitArgs"

    $benchArgs = @(
        "-m", "`"$modelPath`""
        "-r", $repetitions
        "-n", $tgTokens
        "-p", 0
        "-fa", "on"
        "--no-mmap"
        $fitArgs
    ) -join " "

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $llamaBenchExe
    $psi.Arguments              = $benchArgs
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true
    $psi.WorkingDirectory       = $scriptDir

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()

    $stdout   = $proc.StandardOutput.ReadToEnd()
    $stderr   = $proc.StandardError.ReadToEnd()
    $exitCode = $proc.ExitCode

    $status  = "OK"
    $tps     = 0.0
    $backend = ""

    if ($exitCode -ne 0) {
        $status = "BenchError"
        Write-Warning "llama-bench FAILED (exit $exitCode) for fit-ctx=$FitCtxMin, margin=$FitMarginMB."
        if ($stderr) {
            Write-Warning "stderr:"
            $stderr.Split("`r`n")[0..([Math]::Min(5, $stderr.Split("`r`n").Length-1))] | ForEach-Object {
                Write-Warning "  $_"
            }
        }
    }
    else {
        # llama-bench default output is a markdown table; we grab the tg row
        $line = $stdout -split "`r?`n" |
            Where-Object { $_ -match "\btg\s+$tgTokens\b" } |
            Select-Object -First 1

        if ($line -and $line -match '([0-9]+(?:\.[0-9]+)?)\s+±') {
            $tps = [double]$matches[1]
        } else {
            $status = "ParseError"
            Write-Warning "Could not parse tokens/s from llama-bench output (fit-ctx=$FitCtxMin, margin=$FitMarginMB)."
        }

        if ($line -match '\b(CUDA|CPU|Vulkan|OpenCL|Metal)\b') {
            $backend = $matches[1]
        }
    }

    $csvLine = "$status,$FitCtxMin,$FitMarginMB,$batchTokens,$ubatchTokens,$tgTokens,$threads,$tps,$backend,""`"$fitArgs`""""
    Add-Content -Path $resultCsv -Value $csvLine

    $backendDisplay = if ($backend) { $backend } else { "?" }
    Write-Host ("    => status={0}, t/s={1}, backend={2}" -f $status, $tps, $backendDisplay)
}

# --- MAIN LOOP ----------------------------------------------------------------

foreach ($ctx in $fitCtxMinList) {
    foreach ($margin in $fitMarginMBs) {
        Write-Host ""
        Write-Host "=== Benchmark: fit-ctx >= $ctx, fit-margin = $margin MiB ===" -ForegroundColor Green
        Run-OneBench -FitCtxMin $ctx -FitMarginMB $margin
    }
}

Write-Host ""
Write-Host "Benchmark complete. Results appended to:"
Write-Host "  $resultCsv"
