# llama.cpp Installer for Windows

This project provides a PowerShell script to automate the setup of the `llama.cpp` development environment on Windows. It installs all the necessary prerequisites, including the CUDA Toolkit, and builds `llama.cpp` from the source.

## Prerequisites

*   Windows 10/11 x64
*   PowerShell 5 (or 7)
*   NVIDIA GPU with CUDA 12.4+ support
*   ~20 GB of free disk space

## Installation

The installation process is handled by a single PowerShell script. It will perform the following steps:

1.  **Check for Administrator Privileges**: The script requires elevated permissions to install software.
2.  **Install Prerequisites**: It uses `winget` to install the following tools if they are not already present:
    *   Git
    *   CMake
    *   Visual Studio 2022 Build Tools
    *   Ninja Build System
3.  **Install CUDA Toolkit**: It checks for a compatible CUDA installation (version 12.4 or newer). If not found, it will be installed.
4.  **Clone and Build `llama.cpp`**: The script clones the official `llama.cpp` repository from GitHub into a `vendor` subdirectory, and then it compiles the source code.

To start the installation, run the `install_llama_cpp.ps1` script from an **elevated** PowerShell prompt.

```powershell
# Allow script execution for this session
Set-ExecutionPolicy Bypass -Scope Process

# Run the installer (it will auto-detect the CUDA architecture for your GPU)
./install_llama_cpp.ps1
```

You can also specify the CUDA architecture for your GPU with the `-CudaArch` parameter. This is useful if the auto-detection fails or if you want to build for a different GPU.

| Architecture  | Cards (examples)   | Flag         |
| ------------- | ------------------ | ------------ |
| **Pascal**    | GTX 10×0, Quadro P | 60 / 61 / 62 |
| **Turing**    | RTX 20×0 / 16×0    | 75           |
| **Ampere**    | RTX 30×0           | 80 / 86 / 87 |
| **Ada**       | RTX 40×0           | 89           |
| **Blackwell** | RTX 50×0           | 90           |

For example, to build for an RTX 30-series GPU, you would run:

```powershell
./install_llama_cpp.ps1 -CudaArch 86
```

## Uninstallation

To remove the installed software and the cloned `llama.cpp` repository, you can run the `uninstall_llama_cpp.ps1` script from an **elevated** PowerShell prompt.

```powershell
# Allow script execution for this session
Set-ExecutionPolicy Bypass -Scope Process

# Run the uninstaller
./uninstall_llama_cpp.ps1
```

This will uninstall the prerequisites (Git, CMake, VS Build Tools, Ninja, and CUDA) and remove the `vendor` directory.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Acknowledgements

This project is a simplified version of the [local-qwen3-coder-env](https://github.com/Danmoreng/local-qwen3-coder-env) repository, focusing solely on the installation of `llama.cpp`.
