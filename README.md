# ANIMAL WELL PortMaster runtime experiment

Experimental PortMaster runtime for running the Windows x86-64 build of **ANIMAL WELL** on ARM64 handhelds, initially targeting TrimUI Smart Pro S / SpruceOS.

The repository intentionally does **not** contain game files. Put a legally obtained Windows build in `package/animalwell/game/` before testing on-device.

## Runtime strategy

The project tests three D3D12 paths:

1. Wine built-in VKD3D (`backend=wine`) — preferred compatibility baseline.
2. vkd3d-proton 2.6 (`backend=vkd3d-2.6`) — older Vulkan 1.1-era compatibility fallback.
3. vkd3d-proton 3.0.1 (`backend=vkd3d-3.0.1`) — current strict reference implementation.

The Windows x86-64 executable and Wine are run through Box64 on the ARM64 host. Vulkan is provided by the device's native ARM64 driver.

## Known game binary characteristics

The supplied 2024 Steam executable was inspected without redistributing it. See [`docs/GAME_ANALYSIS.md`](docs/GAME_ANALYSIS.md).

Key findings:

- PE32+ x86-64 Windows GUI executable.
- Requests `D3D_FEATURE_LEVEL_11_0` (`0xb000`) when creating the D3D12 device.
- 46 valid embedded DXBC containers: 45 pixel shaders + 1 vertex shader.
- All detected shaders are Shader Model 5.0; no DXIL containers were found.
- Direct imports include `d3d12.dll`, `dxgi.dll`, `XAudio2_9.dll`, `XInput9_1_0.dll`, and `steam_api64.dll`.

These properties make the game substantially more plausible on a limited D3D12/Vulkan stack than a typical modern SM6/DXIL title.

## Build and testing

GitHub Actions builds a self-contained runtime artifact. ARM64 tools are cross-built against a Debian Bullseye sysroot to keep glibc requirements compatible with glibc 2.33-class systems. The artifact includes a Vulkan capability probe and a Windows D3D12/DXGI smoke test that mirrors the game's FL11_0 bootstrap.

Final GPU validation still has to run on the actual Mali-G57 device because CI/QEMU cannot reproduce the TSPS vendor Vulkan stack.
