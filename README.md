# ANIMAL WELL PortMaster runtime experiment

Experimental PortMaster work for **ANIMAL WELL** on ARM64 handhelds, initially
targeting TrimUI Smart Pro S / SpruceOS.

The repository intentionally does **not** contain game files.

## Two runtime tracks

### 1. Windows x86-64 build

The existing prototype runs the Windows build through Box64 + Wine and tests
three D3D12 paths:

1. Wine built-in VKD3D (`backend=wine`) — compatibility baseline.
2. vkd3d-proton 2.6 (`backend=vkd3d-2.6`).
3. vkd3d-proton 3.0.1 (`backend=vkd3d-3.0.1`) — stricter reference path.

Vulkan is supplied by the handheld's native ARM64 driver.

The supplied Windows executable was inspected without redistribution:

- PE32+ x86-64.
- Requests `D3D_FEATURE_LEVEL_11_0` (`0xb000`).
- 46 valid embedded DXBC containers: 45 pixel + 1 vertex.
- All detected shaders are Shader Model 5.0; no DXIL was found.
- Direct imports include `d3d12.dll`, `dxgi.dll`, `XAudio2_9.dll`,
  `XInput9_1_0.dll` and `steam_api64.dll`.

A host-side Wine launch of the supplied build reaches the normal window/display
creation boundary after loading the game, Steam API, XInput, XAudio, DXGI and
D3D12 DLLs. Final D3D12 rendering still requires the real TSPS Mali Vulkan stack.

See [GAME_ANALYSIS.md](docs/GAME_ANALYSIS.md).

### 2. Native Switch build research

The user-supplied merged Switch build was also inspected. It contains
`rtld + main + sdk` NSO modules. A supplied Bloodstained: Curse of the Moon
port demonstrates a different architecture: a custom native AArch64 guest
loader with NVN-to-GLES2 translation rather than Wine or full Switch emulation.

Static comparison is encouraging: 475 of 536 NVN entry-point names visible in
ANIMAL WELL's `main` have wrapper-name analogues in the Bloodstained shim.
This is an upper-bound name comparison, not proof that every name is executed.

The public NextOS framework provides reusable pieces such as `nxloader`,
`nxgl`, `nxinput`, `nxaudio`, `nxextract` and a reproducible
Vulkan/SPIR-V -> GLES2 shader-translation laboratory. ANIMAL WELL still needs a
game-specific Switch NSO mapper/relocator plus explicit `nn::*`, NVN and GLSLC
adapters; the Bloodstained binary is not a drop-in loader.

See [SWITCH_ANALYSIS.md](docs/SWITCH_ANALYSIS.md) and
`scripts/analyze_switch.py`.

## SpruceOS / glibc compatibility policy

All Linux ELF files shipped in the runtime are checked, not just the main
launcher. The build job uses **Ubuntu 20.04 / glibc 2.31**, matching the
compatibility strategy used by SpruceOS' 64-bit ScummVM build.

CI rejects a runtime if any bundled ELF requires:

- `GLIBC > 2.31`
- `GLIBCXX > 3.4.28`

This includes Box64, native probes, Wine ELF files and bundled x86-64 helper
libraries. The device's Vulkan loader/ICD remains device-provided.

Box64's upstream `x64lib/` directory is deliberately **not** bundled wholesale:
it contains convenience binaries produced on mixed/newer distributions. The
runtime copies only the guest helper libraries needed by the Wine path
(`libgcc_s.so.1`, `libstdc++.so.6`, `libunwind.so.8`) from the same
Ubuntu 20.04 build root, and then subjects them to the same ABI scan.

## Reproducible build

GitHub Actions uses an Ubuntu 20.04 job container. A matching local build root is
provided as `Dockerfile.64`:

```sh
docker build -f Dockerfile.64 -t animalwell-runtime:focal .
mkdir -p dist
docker run --rm \
  -e OUT=/out \
  -v "$PWD/dist:/out" \
  animalwell-runtime:focal
```

## Build and testing

GitHub Actions:

1. runs Python and shell tests;
2. builds the ARM64 host pieces on the focal/glibc-2.31 baseline;
3. scans **every shipped ELF** with `readelf --version-info`;
4. fails the workflow if any ELF exceeds either ABI ceiling;
5. verifies ARM64/PE file formats and that bundled helper ELFs are x86-64;
6. starts Box64 under QEMU as a host-loader smoke test;
7. verifies the artifact contains no proprietary game/Switch binaries;
8. uploads the runtime, hashes, QEMU log and complete ABI report.

The runtime also includes:

- a native ARM64 Vulkan capability/descriptor probe;
- an x86-64 Windows D3D12/DXGI smoke test that mirrors the game's FL11_0
  bootstrap;
- on-device diagnostic collection for the real Mali-G57 Vulkan stack.

A green CI result proves build/ABI integrity, not final GPU compatibility. Real
D3D12/NVN rendering still needs the TSPS hardware stack.
