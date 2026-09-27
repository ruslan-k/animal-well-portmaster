# ANIMAL WELL PortMaster — experimental TSPS runtime

This repository builds an experimental **aarch64 host runtime** for running the x86-64 Windows build of ANIMAL WELL on TrimUI Smart Pro S / SpruceOS.

The runtime is deliberately built in **Ubuntu 20.04 (glibc 2.31)**, following the same compatibility idea used by Spruce projects: shipped Linux ELF files are rejected by CI if they require a newer `GLIBC` symbol than 2.31 (or `GLIBCXX` newer than 3.4.28).

## Runtime layout

- **Box64**: aarch64 host binary, built with `SAVE_MEM=ON` for the TSPS memory budget.
- **Wine 11.0 x86-64**: runs through Box64 and provides Win32/X11/audio/input integration.
- **Wine/upstream D3D12 path**: selectable as `ANIMALWELL_BACKEND=wine`.
- **vkd3d-proton 2.14.1 + DXVK 2.3.1 DXGI**: default compatibility experiment (`proton214`).
- **vkd3d-proton 3.0.1 + DXVK 2.6.2 DXGI**: newer experimental path (`proton301`).
- Native ARM64 `libFAudio.so.0` is bundled; the Vulkan loader/ICD is intentionally taken from the device so the runtime can use the TSPS Mali vendor stack.

Game files are never committed or published by this project.

## Known game build

The supplied test copy was inspected locally and represented only by metadata in `tests/known-builds/steam-1.0.0.19.json`:

- ANIMAL WELL `1.0.0.19`
- Steam AppID `813230`
- `Animal Well.exe`: x86-64 PE32+, 34,535,424 bytes
- SHA-256: `48c8044d5ffd8cfc2abc73eeb9d15e9e6f196fbd7a744ea41d965bcc7f237bb1`
- Direct graphics imports: `d3d12.dll`, `dxgi.dll`
- Direct audio/input imports: `XAudio2_9.dll`, `XINPUT9_1_0.dll`, HID/SetupAPI

The executable contains diagnostic strings for root signature serialization, D3D12 device/resource creation and DXGI swap-chain creation, which makes early-startup failures easier to localize.

## CI tests

Every push/PR builds and packages the runtime, then checks:

1. Box64 is really an aarch64 ELF and Wine is x86-64 ELF.
2. All shipped ELF files stay at or below the glibc 2.31 / GLIBCXX 3.4.28 ceiling.
3. Both vkd3d-proton payloads contain x64 `d3d12.dll` and both DXVK payloads contain x64 `dxgi.dll`.
4. Box64 at least starts as an ARM64 binary under QEMU user emulation.
5. The final PortMaster payload is hashed and uploaded as a GitHub Actions artifact.

CI cannot emulate the TSPS Mali-G57 vendor Vulkan implementation. `diagnose.sh` therefore performs the hardware-dependent stage on the handheld.

## Device test

Extract the workflow artifact so `animalwell.sh` and the `animalwell/` directory are next to each other. Copy your legally-owned game files into:

```text
animalwell/game/
  Animal Well.exe
  steam_api64.dll
  steam_appid.txt
```

For a normal launch:

```bash
./animalwell.sh
```

For the full three-backend startup matrix and diagnostics:

```bash
cd animalwell
./diagnose.sh
```

It records libc/memory/zram/display state, Vulkan information when `vulkaninfo` exists, the game hash, Box64/Wine/VKD3D/DXVK logs, attempts `wine`, `proton214`, and `proton301`, and produces `diagnostics-*.tar.gz` for analysis.

### Backend override

```bash
ANIMALWELL_BACKEND=wine ./animalwell.sh
ANIMALWELL_BACKEND=proton214 ./animalwell.sh
ANIMALWELL_BACKEND=proton301 ./animalwell.sh
```

`proton214` is the initial default because older VKD3D/DXVK combinations are more useful when probing a constrained/older Vulkan driver. The newer backend is retained to distinguish missing old-version fixes from Vulkan-capability failures.

## What a CI pass means

A green workflow proves the runtime is reproducibly built and ABI-compatible with the chosen glibc ceiling. It **does not** prove D3D12 rendering on Mali-G57. The first real-device run is expected to tell us whether the next work belongs in Box64/Wine integration, DXGI, vkd3d capability checks, descriptor handling, shader translation, or the vendor Vulkan driver.
