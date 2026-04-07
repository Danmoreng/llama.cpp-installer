# llama.cpp Installer for Windows

This project provides a PowerShell script to automate the setup of the `llama.cpp` development environment on Windows. It installs all required prerequisites **silently**, selects an appropriate **CUDA Toolkit** version, and builds `llama.cpp` from source.

## Prerequisites

* Windows 10/11 x64
* PowerShell 7
* Recent **NVIDIA driver** (no CUDA toolkit required)
* ~20 GB free disk space
* **App Installer / winget** available (to install dependencies)
* **Administrator** rights (elevated PowerShell)

> The GPU SM auto-detect uses `nvml.dll` from the NVIDIA driver. If NVML isn’t available, the script falls back to a WMI-based heuristic and then to `CMAKE_CUDA_ARCHITECTURES=native`.

## What the installer does

1. **Admin check** (must be elevated).
2. **Installs prerequisites** if missing:

   * Git
   * CMake
   * **Visual Studio 2022 Build Tools** with the C++ toolchain and Windows SDK
   * Ninja (and a portable fallback if needed)
3. **Chooses CUDA Toolkit**:

   * Detects your GPU’s **SM** via NVML.
   * **SM < 70 (pre-Turing)** → installs/uses **CUDA 12.4**.
   * **SM ≥ 70** or unknown → uses the newest compatible installed CUDA (≥ 12.4).
   * If `winget` reports a newer compatible CUDA toolkit, the script prompts whether to upgrade or keep the current install.
4. **Clones and builds `llama.cpp`** under `vendor\llama.cpp`.

## Installation

Run from an **elevated** PowerShell prompt:

```powershell
# Allow script execution for this session
Set-ExecutionPolicy Bypass -Scope Process

# Run the installer (auto-detects GPU SM; falls back to native)
./install_llama_cpp.ps1
```

Optional: skip the build step (installs prerequisites + CUDA only):

```powershell
./install_llama_cpp.ps1 -SkipBuild
```

The built binaries will be in:

```
vendor\llama.cpp\build\bin
```

## Uninstallation

Run from an **elevated** PowerShell prompt:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
./uninstall_llama_cpp.ps1
```

This removes the winget-installed prerequisites and the `vendor` directory (and portable Ninja if it was created).

## Running the Server

The `run_llama_cpp_server.ps1` script starts `llama-server.exe` in router mode with a single default model configured in the script.

1.  **Downloads the model**: It automatically downloads the configured GGUF file into the `models` directory if it is not already present.
2.  **Starts the server**: It launches `llama-server.exe` in router mode and lets `llama.cpp` auto-fit GPU layers and context.
3.  **Opens Web UI**: After starting the server, it automatically opens `http://localhost:8080` in your default web browser.

The current default model is:

* `gemma-4-e4b-it-Q4_K_M`

To run the server, use the following command in PowerShell:

```powershell
./run_llama_cpp_server.ps1
```

## Troubleshooting

* **winget not found**: Install “App Installer” from the Microsoft Store, then re-run.
* **Pending reboot**: Some installs require a reboot (Windows Update/VS Installer). Reboot and re-run.
* **CUDA side-by-side**: Multiple CUDA toolkits can co-exist; the uninstaller can remove them via winget.
* **NVML missing**: The script falls back to a heuristic and then `CMAKE_CUDA_ARCHITECTURES=native`.
* **Locked files**: Stop `llama-server`/`llama-cli` before uninstalling.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgements

This project is a simplified version of the [local-qwen3-coder-env](https://github.com/Danmoreng/local-qwen3-coder-env) repository, focusing solely on the installation of `llama.cpp`.
