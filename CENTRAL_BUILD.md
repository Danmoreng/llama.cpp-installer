# Shared Windows llama.cpp build

The local upstream checkout and CUDA build are at `C:\llama.cpp`. The update script is also versioned in this repository. Run:

```powershell
& 'C:\llama.cpp\update-central.ps1' -Jobs 12
```

The update fast-forwards upstream, builds the CUDA tools, then rebuilds the
Vibe Inference and qwen35-cpu adapters when their shared-build integration is
present. An upstream API break stops the update with an adapter build error.
The adapter sources must then be updated before using them with the new build.

The standard Windows server launchers in this repository and in
`local-qwen3-coder-env` use the shared server. `LLAMA_CPP_HOME` can be set to
change the launcher or adapter source path; the updater itself manages
`C:\llama.cpp`. The central build targets this machine's CUDA SM120a GPU and
native CPU features. It is not a portable release build.

The Prism fork is a separate experimental implementation. Product dependencies
such as BetterSearch's own llama.cpp submodule remain project-local. Some older reference checkouts remain for further review; obsolete Windows
benchmark builds were removed.
