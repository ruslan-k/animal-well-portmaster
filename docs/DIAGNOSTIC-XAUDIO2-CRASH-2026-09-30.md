## Diagnostic report: the startup crash is in wine's XAudio2 (FAudio), not in D3D12

Full evidence from device runs on 2026-09-30 (TSPS / Longan, Allwinner sun55iw3 A523, Mali-G57, wine 10.0 Kron4ek archive, box64 0.4.4).

### 1. Review item 3 resolved: the faulting instruction is inside xaudio2_9.dll

```
wine: Unhandled page fault on read access to 00000000000000DC at address 0000007FFE32E9F6 (thread 0024)
opcode at the fault: 8B 80 DC 00 00 00   ->  mov eax, [rax+0xDC]   with RAX = 0
```

Resolved `0x7FFE32E9F6` against the live game process maps:

```
7ffe321000-7ffe343000 r-xp 00001000 b3:09 3286434
    /mnt/sdcard/mmcblk1p1/Roms/ports/animalwell/runtime/wine/lib/wine/x86_64-windows/xaudio2_9.dll
offset_in_mapping = 0xd9f6
```

So the graphics hypothesis is wrong: **the crash is in wine's XAudio2 implementation**, at RVA `0xd9f6`. The module (735754 bytes) is wine's `dlls/xaudio2_7` built as `xaudio2_9.dll`; its strings include `Using FAudio version %d`, `device id %s, category %#x`, and the assert-lock strings `IXAudio2Impl.lock`, `XA2MasteringVoice.lock`, `XA2VoiceImpl.lock`. The offset is below every export (`CreateAudioReverb 0x1d70`, `CreateFX 0x21d0`, `X3DAudioInitialize 0x1c3b0`, `XAudio2Create 0x201a0`), i.e. an internal helper in the FAudio glue path.

Corroborating: `Animal Well.exe` imports `XAudio2_9.dll` (and `XINPUT9_1_0.dll`), and the sound was reported glitchy in the sessions where the game did reach its menu.

### 2. Review item 1 (U0) done: the winevulkan assert patch is removed and was NOT the crash cause

* Original `winevulkan.dll` restored from the device backup; SHA-256 prefix `cf8260f13144062c`.
* With the corrected live-X / working-D3D12 environment the line-668 assert **does not fire**: `Assertion failed` count = **0** with the untouched module.
* Therefore the patch is unnecessary and unsafe (it masks a failed `UNIX_CALL` transport status, exactly as you noted) - **patch dropped**.
* However, the `0xDC` crash **still reproduces with the original module**, so the patch was not what produced the NULL object; the NULL comes from the XAudio2 path above.

### 3. Review item 2: frozen environment of the passing smoke (call it T1V)

```
DISPLAY=:1                       (live port X server, the launcher's own)
WINE_D3D_CONFIG=renderer=vulkan  (not "unset"; hence T1V, not T1)
VKD3D_CONFIG=virtual_heaps
WINEDLLOVERRIDES=mscoree=;mshtml=;winemenubuilder.exe=disabled;d3d12=b;d3d12core=b
VK_ICD_FILENAMES=/tmp/aw-icd.json  -> runtime/test14/lib/libmali_wrapper.so, advertised api_version 1.3.276
loader path: runtime/test14/deps/libvulkan.so.1 (loader_api 1.2.131)
wrapper sha256 prefix: 499564a0810daa75
winevulkan.dll  cf8260f13144062c
d3d12.dll       2943e6d8a4ec2670
dxgi.dll        348f78328d8911f1
```

Smoke results under exactly this environment:

```
factory: CreateDXGIFactory1 hr=0x00000000 ptr=0x33EFA0   SMOKE_RESULT=PASS_DXGI_FACTORY
device:  D3D12CreateDevice(NULL, FL11_0) hr=0x00000000 ptr=0x96C0E0  SMOKE_RESULT=PASS_D3D12_DEVICE
```

The wrapper exposes `VK_KHR_surface`, `VK_KHR_xlib_surface`, `VK_KHR_xcb_surface`, `VK_KHR_wayland_surface`, `VK_EXT_headless_surface`, `VK_KHR_get_surface_capabilities2`, `VK_EXT_surface_maintenance1` at instance level.

Earlier `DXGI_ERROR_UNSUPPORTED` results were my methodology error: standalone smoke runs were executed with `DISPLAY=:1` while the port's X server was not running. With a live X the same smoke passes. That invalidates the "D3D12 impossible on this Mali" conclusion - D3D12 device creation works.

### 4. Review item 8: winedevice.exe presence

```
runtime/wine/lib/wine/x86_64-windows/winedevice.exe   1032 bytes   (present)
advapi32.dll 523699, ntoskrnl.exe 823810, winebus.sys 107048, winexinput.sys 94297, hidparse.sys 135151
prefix: drive_c/windows/system32/winedevice.exe -> resolves to the runtime file (1032 bytes)
```

The file is not missing, but 1032 bytes is suspiciously small for that EXE; its import chain was not yet verified. The repeated `failed to open "...winedevice.exe": c0000135` therefore still needs the `+loaddll,+module,+service` trace you described.

### 5. Not yet executed

Items 4 (feature-level sweep), 5 (game-side `+d3d12` trace of its own `D3D12CreateDevice`), 6 (smoke ladder S2-S6), 7 (WSI timeout correlation) are pending - and given item 1 above they are currently deprioritised, because the faulting module is the audio stack, not the graphics stack. The `+d3d12/+dxgi/VKD3D_DEBUG=trace` run confirmed your warning: full tracing makes the game crawl on this device (3 threads, no progress) and must stay out of normal runs.

### 6. Proposed next steps

1. Trace the XAudio2 path: `WINEDEBUG=+xaudio2,+faudio` (or wine's `+xaudio2_7`) around `XAudio2Create`/`CreateMasteringVoice`, and check which FAudio version string appears - the module reports `Using FAudio version %d`.
2. A/B the audio device route, since the game's XAudio2 must open a device: the device currently uses `$HOME/.asoundrc` through `dmix`; the port's own `AW_ALSA_DIRECT` (private HOME + ALSA_CONFIG_PATH list keeping the system `alsa.conf`) exists but defaults to 0.
3. Only if the audio path proves unrelated to the NULL, run the smoke ladder S2-S6 to bound D3D12 above device creation.
