# ANIMAL WELL executable analysis

Analyzed input: user-supplied Windows Steam files. Game data is not stored in this repository.

## File hashes

| File | SHA-256 |
| --- | --- |
| `Animal Well.exe` | `48c8044d5ffd8cfc2abc73eeb9d15e9e6f196fbd7a744ea41d965bcc7f237bb1` |
| `steam_api64.dll` | `286f2ed575fb16bba9c451bdf5c8738b5aa6587ec7831830cfae1739c6347edd` |

`steam_appid.txt` contains app id `813230`.

## PE and renderer findings

`Animal Well.exe` is PE32+ x86-64. Direct imports include `d3d12.dll`, `dxgi.dll`, `XAudio2_9.dll`, `XInput9_1_0.dll`, `steam_api64.dll`, USER32/HID/SETUPAPI and standard Win32 libraries.

Disassembly of the renderer bootstrap shows `mov edx, 0xb000` immediately before the imported D3D12 device-creation call, i.e. `D3D_FEATURE_LEVEL_11_0`.

The executable contains 46 structurally valid DXBC containers and no DXIL signatures: 45 pixel shaders and 1 vertex shader, all Shader Model 5.0. Embedded diagnostics show conventional D3D12 usage: `CreateDXGIFactory1`, swapchain creation, direct command queue/list, committed resources, fence, query heap, root signature creation and `D3D_ROOT_SIGNATURE_VERSION_1_0` serialization.

This is a much smaller compatibility target than a modern SM6/DXIL D3D12 title. The main unknown is the actual TSPS Vulkan feature/descriptor surface, so the runtime includes a native ARM64 Vulkan probe and a Windows D3D12 smoke test.

## Host Wine launch probe

The exact supplied game build was also launched with the runtime's Wine 11.18
under an Xvfb display on an x86-64 Linux host. This is deliberately a loader/API
smoke test, not a substitute for the TSPS GPU.

Observed progression:

1. the game executable starts and loads its native `steam_api64.dll`;
2. Wine loads XInput, XAudio2, DXGI and D3D12;
3. ANIMAL WELL calls `D3D12CreateDevice` with minimum feature level
   `0xb000` (FL11_0), matching the static disassembly;
4. DXGI creates a factory and enumerates the only host adapter exposed by this
   container, llvmpipe;
5. device creation stops at Wine VKD3D initialization with
   `0x80004005` because this container has a Vulkan loader but no usable Vulkan
   ICD.

That failure is useful isolation: the supplied PE reaches the real D3D12 device
bootstrap without an earlier Wine/Steam/DLL failure. The next graphics test must
run with a real Vulkan implementation, ideally the TSPS Mali-G57 stack collected
by the on-device diagnostic harness.
