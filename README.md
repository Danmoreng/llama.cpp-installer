# llama.cpp Installer for Windows

This project provides PowerShell scripts to automate the setup of the `llama.cpp` development environment on Windows. It installs the required prerequisites **silently**, selects an appropriate compute backend, and builds `llama.cpp` from source.

The repo is still **Windows-only** today. What changed is backend support: it is no longer implicitly NVIDIA-only.

* `auto` chooses `cuda` on NVIDIA GPUs, `vulkan` on AMD or Intel GPUs, and `cpu` if no supported GPU is detected.
* `cuda` keeps the existing NVIDIA-focused flow.
* `vulkan` is the recommended Windows path for AMD and Intel GPUs.
* `cpu` builds a plain CPU-only binary.

Temporary CUDA policy for this repo: CUDA `13.2` is excluded due to corrupt `llama.cpp` builds. The scripts currently cap automatic selection at CUDA `13.1` unless you explicitly pin another compatible version.

## Prerequisites

* Windows 10/11 x64
* PowerShell 7
* Recent GPU driver for your selected backend
* ~20 GB free disk space
* **App Installer / winget** available (to install dependencies)
* **Administrator** rights (elevated PowerShell)

> The CUDA path still uses `nvml.dll` from the NVIDIA driver for SM auto-detect. If NVML isn’t available, the script falls back to a WMI-based heuristic and then to `CMAKE_CUDA_ARCHITECTURES=native`.

## What the installer does

1. **Admin check** (must be elevated).
2. **Installs prerequisites** if missing:

   * Git
   * CMake
   * **Visual Studio 2022 Build Tools** with the C++ toolchain and Windows SDK
   * Ninja (and a portable fallback if needed)
3. **Chooses a backend**:

   * `auto` picks `cuda`, `vulkan`, or `cpu` from the detected adapter vendor.
   * `cuda` detects your GPU’s **SM** via NVML and installs or selects a compatible CUDA toolkit.
   * `vulkan` installs or uses the **Vulkan SDK**.
   * `cpu` skips GPU SDK installation entirely.
4. **Clones and builds `llama.cpp`** under `vendor\llama.cpp`.

## Installation

Run from an **elevated** PowerShell prompt:

```powershell
# Allow script execution for this session
Set-ExecutionPolicy Bypass -Scope Process

# Run the installer (auto-selects backend from the detected GPU)
./install_llama_cpp.ps1
```

Explicit backend controls:

```powershell
# AMD / Intel on Windows
./install_llama_cpp.ps1 -Backend vulkan

# Force a CPU-only build
./install_llama_cpp.ps1 -Backend cpu

# Force the NVIDIA path
./install_llama_cpp.ps1 -Backend cuda
```

Explicit CUDA version controls:

```powershell
# Keep the repo on CUDA 13.1 for now
./install_llama_cpp.ps1 -PinnedCudaVersion 13.1

# Or force CUDA 13.0 specifically
./install_llama_cpp.ps1 -PinnedCudaVersion 13.0

# Or allow any compatible version up to 13.0
./install_llama_cpp.ps1 -MaxCudaVersion 13.0
```

Optional: skip the build step (installs prerequisites + CUDA only):

```powershell
./install_llama_cpp.ps1 -SkipBuild
```

The built binaries will be in:

```
vendor\llama.cpp\build\bin
```

To verify which runtime devices the built binary can see:

```powershell
.\vendor\llama.cpp\build\bin\llama-server.exe --list-devices
```

On an AMD or Intel Vulkan build, you should see a Vulkan device in that list. On a CPU-only build, use `--device none` at runtime to force CPU execution.

If you already have `llama.cpp` installed and just want to rebuild against a safe toolkit:

```powershell
./rebuild_llama_cpp.ps1

# Rebuild for an AMD or Intel machine
./rebuild_llama_cpp.ps1 -Backend vulkan

# Or pin the rebuild to a specific installed toolkit
./rebuild_llama_cpp.ps1 -Backend cuda -PinnedCudaVersion 13.1
./rebuild_llama_cpp.ps1 -Backend cuda -PinnedCudaVersion 13.0
```

## Uninstallation

Run from an **elevated** PowerShell prompt:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
./uninstall_llama_cpp.ps1
```

This removes the winget-installed prerequisites and the `vendor` directory (and portable Ninja if it was created).

## Running the Server

The `run_llama_cpp_server.ps1` script starts `llama-server.exe` in generic router mode over the `models` directory.

1.  **Downloads one default model**: It automatically downloads the configured GGUF file into the `models` directory if it is not already present.
2.  **Starts the router**: It launches `llama-server.exe` with `--models-dir` so every GGUF in `.\models` is available through the router.
3.  **Auto-fits runtime parameters**: It lets `llama.cpp` auto-fit GPU layers and context, and opens `http://localhost:8080` in your default web browser.

The current default model is:

* `gemma-4-e4b-it-Q4_K_M`

To run the server, use the following command in PowerShell:

```powershell
./run_llama_cpp_server.ps1
```

### Gemma Code Editing Preset

For a dedicated single-model launcher, `run_gemma4_26b_a4b_server.ps1` starts the `gemma-4-26B-A4B-it-Q4_K_M` variant directly instead of using router mode. It is tuned for local code editing with `ngram-mod` enabled by default using a more conservative profile (`--spec-ngram-size-n 24 --draft-min 4 --draft-max 24`), a lower-temperature sampling profile (`temp=0.2`, `top_p=0.9`, `top_k=40`, `min_p=0.01`), reasoning disabled, a larger micro-batch (`-ub 512`), KV cache quantization (`-ctk q8_0 -ctv q8_0`), and the same auto-fit behavior used elsewhere in the repo. Use it when you specifically want the Gemma 4 26B Q4 coding setup rather than the generic multi-model router.

## Troubleshooting

* **winget not found**: Install “App Installer” from the Microsoft Store, then re-run.
* **Pending reboot**: Some installs require a reboot (Windows Update/VS Installer). Reboot and re-run.
* **CUDA side-by-side**: Multiple CUDA toolkits can co-exist. You do not need to uninstall CUDA 13.2 if CUDA 13.1 or 13.0 is also installed; the scripts will select the pinned/capped version.
* **AMD / Intel on Windows**: Prefer `-Backend vulkan`. ROCm/HIP exists in `llama.cpp`, but it is not the primary path this repo automates on Windows.
* **Vulkan SDK missing**: The script installs the Vulkan SDK when `-Backend vulkan` is selected. If detection still fails, reinstall the LunarG Vulkan SDK and re-run.
* **NVML missing**: The script falls back to a heuristic and then `CMAKE_CUDA_ARCHITECTURES=native`.
* **Locked files**: Stop `llama-server`/`llama-cli` before uninstalling.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgements

This project is a simplified version of the [local-qwen3-coder-env](https://github.com/Danmoreng/local-qwen3-coder-env) repository, focusing solely on the installation of `llama.cpp`.
