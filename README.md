# ANIMAL WELL PortMaster

Experimental ARM64/PortMaster runtime work for ANIMAL WELL. Game files are intentionally not stored in this repository.

## Runtime paths

Two independent approaches are tracked:

1. **Windows build:** x86-64 ANIMAL WELL through Box64 + Wine64 + vkd3d-proton/DXVK.
2. **Switch build:** experimental native ARM64 Switch NSO route inspired by the NextOS Bloodstained shim layout.

The Windows route is the primary first-frame target.

## ABI baseline

Native Linux components are built in **Ubuntu 20.04 / glibc 2.31**, matching the conservative 64-bit SpruceOS baseline used by projects such as ScummVM-spruce.

CI runs `scripts/check-glibc.sh` across every ELF in the produced runtime and fails if any object requires a `GLIBC_*` version newer than 2.31.

## Current pinned components

- Box64 v0.4.4
- Wine 11.0
- vkd3d-proton v3.0.1
- DXVK v2.6.2 (chosen instead of DXVK 3.x because 3.x raises the Vulkan baseline to 1.4)

## Build

```bash
docker build -f Dockerfile.64 -t animal-well-runtime:focal .
mkdir -p dist
docker run --rm -e OUT=/out -v "$PWD/dist:/out" animal-well-runtime:focal
```

CI publishes `animal-well-runtime-aarch64.tar.xz` plus glibc and smoke-test reports.

## Static game inspection

Windows:

```bash
./scripts/analyze-game.sh "/path/to/Animal Well.exe"
```

Switch ExeFS:

```bash
./scripts/analyze-game.sh "/path/to/exefs"
```

The supplied Windows executable imports D3D12 and DXGI and contains direct markers for root signatures, swap-chain creation and committed resources.

See [docs/switch-feasibility.md](docs/switch-feasibility.md) for the Switch-native findings.
