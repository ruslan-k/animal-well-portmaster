# Device state v22 (working baseline)

Reproducible snapshot of the state that made Animal Well run on the TSPS
(stable, rendering, audio playing, no crashes). Captured after the session
that fixed the FAudio crash, rebuilt XAudio2, and moved the launch to the
real Spruce flow.

## Stack identities (as measured on the device)

| Component | Version / identity |
|---|---|
| Launcher | `2026-09-29.15` (merged, in `package/Animal Well.sh`, sha256 `9122c21257bd8924d546c2a9eb4cc2c4f39b57687611ae14ef12082fd5b1f73e`) |
| Wine | 11.18 (Kron4ek amd64-wow64 build) |
| Box64 | v0.4.4 (production; `BOX64_WINEDBG=1` set by the launcher) |
| XAudio2 module | `xaudio2_9.dll` rebuilt from Wine 11.18 + FAudio `0d03cb04c3c2bacf5e69d0d7e58b65d7202fc618` (post-26.09). Stripped sha256 `04ae9105375fe9be7724133783eb3fb328e62502bd0a7faf9ec23aba738c3abd`. Runtime proof: `trace:xaudio2` DllMain prints `Using FAudio version 260901`. |
| Old modules kept as backups in the tree | `xaudio2_9.dll.orig-wine1118` (sha `c7632731…`, FAudio 26.09 - the crashing one), `xaudio2_9.dll.totono-fa2410` (sha `fd16b547…`, Wine 10 / FAudio 24.10 - the first working workaround) |
| WSI path | X11 SHM (`WSI_X11_FORCE_SHM=1`); DRI3 is NOT available on the fbdev Xorg (native probe `vk_wsi_xlib_probe` fails with `-3` without the force, passes with it) |
| Xorg | private server on `:1` from the TOTONO runtime (`totono-fb.conf`, fbdev + ShadowFB + TSPSRotateCopy) |

## Crash fixes in this baseline (all verified on device)

1. **SCM bootstrap** - `services.exe` started in the final session (after the
   display seed resets the wineserver). The bundled ntdll runs `wineboot --help`
   instead of `--init`, so the SCM never started by itself and COM/RPC init
   failed (`RPC_S_SERVER_UNAVAILABLE`).
2. **`BOX64_WINEDBG=1`** - box64 refuses to launch `winedbg` by name; wine's
   unhandled-exception handler then waited forever while a crashed thread kept
   holding the process heap lock (the `RtlpWaitForCriticalSection "main process
   heap section"` deadlock). With the flag the crash is reported and the process
   exits cleanly.
3. **FAudio 26.09 OOB mix crash** - `xaudio2_9.dll+0x12c38` (`MOVAPS` store into
   a guard page) on every run, ~45 s in. Root cause: Wine 11.18 bundles FAudio
   26.09, which has the effect-chain out-of-bounds bug (upstream FAudio issue
   #404; Wine bug 60294). Rebuilt the module against FAudio `0d03cb0`
   (`scripts/build-xaudio2-faudio.sh`) - crash gone.

## Launcher behaviours added (all env-gated, reversible)

- `AW_HARDEN=1` - box64 memory-model hardening (STRONGMEM=1, ALIGNED_ATOMICS,
  SAFEFLAGS, BLEEDING_EDGE=0). OFF by default for speed; the FAudio root fix
  made it unnecessary. STRONGMEM=2 / BIGBLOCK=1 / CALLRET=0 were bisected out
  (each made even `wine cmd /c ver` die with SIGKILL at exit).
- `AW_NO_AUDIO=1` - disables XAudio2 DLLs (only useful for diagnostics; the game
  has a static XAudio2_9 import so it exits 53).
- `AW_XA2_NATIVE=1` - prefers a user-supplied `xaudio2_9.dll` in the game dir.
- CPU performance preset (1992 MHz, `performance`) applied before Wine and
  restored in the cleanup trap; swap priorities zram=200 > UDISK=100 > SD=10
  (only re-prioritized when the device holds little data).

## Launch procedure (must be used for every test)

Ports must be launched through the Spruce principal flow - launching the
launcher directly leaves the MainUI alive, which owns the DRM display and the
ALSA device (the game then fights for the window and winealsa falls back to the
glitchy dmix path: 13 XRuns vs 1 in the proper flow).

```sh
# 1. write the command exactly like the menu would
cat > /tmp/cmd_to_run.sh <<'EOF'
chmod a+x "/mnt/SDCARD/Emu/PORTS/../../spruce/scripts/emu/standard_launch.sh";"/mnt/SDCARD/Emu/PORTS/../../spruce/scripts/emu/standard_launch.sh" "/mnt/SDCARD/Roms/PORTS/Animal Well.sh"
EOF
chmod a+x /tmp/cmd_to_run.sh
sh -n /tmp/cmd_to_run.sh

# 2. exit the MainUI (it exits itself in the normal flow)
M=$(ps | grep "[M]ainUI" | awk '{print $1}' | head -1); kill -TERM "$M"

# 3. principal.sh picks up the cmd: set_performance + standard_launch.sh
```

Verify: `ps | grep "[M]ainUI"` empty; `fuser /dev/snd/pcmC0D0p` shows ONLY the
game pid; `ps` shows `standard_launch.sh` and the port launcher.

## Measured results (proper flow)

- game stable, rendering, 24 threads, no crashes;
- ALSA XRuns: 13 (direct launch, dmix) -> 1 (proper flow, hw device);
- SD swap: 0 bytes used (zram + UDISK hold everything);
- CPU at 1992 MHz performance;
- game process CPU: ~80% kernel time, dominated by a ~39k syscalls/s storm
  (`getrusage` ~22k/s + `sched_yield` ~11k/s + futex/read/pselect6), source not
  yet identified;
- `FAudio_AudioCli` threads run at nice 0; `renice -10` applied manually as a
  device-only A/B (no new underruns in the 60 s window).

## Still open / next tracks

1. SHM presenter telemetry (`AW_SHM_STATS`, every 120 frames) + one 30 s
   baseline.
2. `AW_XORG_SHADOWFB=0` A/B (one change at a time).
3. FAudio audio-client thread priority (`THREAD_PRIORITY_HIGHEST`) in the
   rebuilt module, or the device-only renice A/B continued.
4. 30/40 FPS caps (`VKD3D_FRAME_RATE`, `AW_PRESENT_HZ`) correlated with XRuns.
5. D3D12 backend re-benchmark (builtin vkd3d vs proton 2.6/3.0.1, `single_queue`).
6. Current Box64 vs v0.4.4 benchmark.
7. Direct-fbdev presentation (`WSI_X11_DIRECT_FBDEV=1`) if SHM proves dominant.
