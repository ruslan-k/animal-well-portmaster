# wine 10.0 on TSPS + memory measures, 2026-09-30

Follow-up to `VERIFIED-LAUNCH-2026-09-30.md`. The port now runs on **wine 10.0**
instead of 11.18, and the session itself was made much cheaper. Everything below
was measured on the device.

## Why another wine version (source-verified)

Wine 11.x introduced the *client surface* window model. Its
`client_surface_update_locked()` in `dlls/win32u/window.c`:

```c
surface->toplevel = NtUserGetAncestor( surface->hwnd, GA_ROOT );
surface->virtual_rect = get_client_surface_rects( surface->toplevel, surface->hwnd, &surface->monitor_rect );
```

computes the client rects that came out as garbage on this fbdev X server
(observed `virtual_rect` x values in the millions, `toplevel (nil)`), which put
the wrapper's SHM presents outside the visible window: rendered frames, black
panel. **That function does not exist in wine 10.0 at all** (diffed
`dlls/win32u/window.c` between `wine-10.0` and `wine-11.18`: the whole function
is added in 11.18). So 10.0 does not have the bug, and the port no longer needs
the virtual desktop workaround that 11.18 required.

## Getting wine 10.0 to run under box64 (the trap that cost hours)

`wine-10.0/bin/wine --version` failed with

    [BOX64] Error loading needed lib libgcc_s.so.1
    wine: could not load ntdll.so: Cannot dlopen(...)

for **both** 10.0 and 11.18 when the environment was incomplete. The launcher
exports

    BOX64_LD_LIBRARY_PATH="$RT/box64/x64lib:$RT/wine/lib:$RT/wine/lib64"

and `runtime/box64/x64lib/` is where the **x86-64** `libgcc_s.so.1` (a dependency
of the emulated x86-64 `ntdll.so`) lives. Any hand-run of wine on this device
must export the same variable. Note: both wine trees are x86-64 — the earlier
"box64 cannot load ntdll" conclusion was an environment mistake, not an
architecture or version incompatibility.

## The Wine Mono Installer dialog

`wineboot` pops the **"Wine Mono Installer"** modal dialog on a prefix that was
created by another wine version. The port's `WINEDLLOVERRIDES` used
`mscoree=d;mshtml=d`, which disables *loading* Mono but does not stop `wineboot`
from *offering to install* it — and the port exported the variable **after** the
first `wineboot --init`, so it never applied. Fixed twice over:

* the prefix template registry carries the no-install form
  (`[Software\Wine\DllOverrides] "mscoree"="" "mshtml"="" "winemenubuilder.exe"="disabled"`),
* the launcher exports `WINEDLLOVERRIDES=mscoree=;mshtml=;winemenubuilder.exe=disabled`
  early, next to `WINEPREFIX`.

With both, `wineboot --init` completes in ~80 s with no dialog.

## The session no longer needs the virtual desktop

With wine 10.0 the game runs **without** `explorer /desktop=...`: the picture is
correct and dynamic (verified with `kmsgrab`, and by the maintainer on the
device). `explorer /desktop` remains available as a fallback
(`aw-vdesktop.py add/remove`), but it is no longer the default. As a side effect
the Windows caption that 11.18 always drew inside the game window is gone.

## Memory: what the session actually costs and how it was cut

Measured before the measures (game running, wine 10.0):

* `Animal Well.exe`: 460–477 MB RSS + 266–292 MB swap
* `services.exe` + `plugplay.exe` + `svchost.exe` + `rpcss.exe` + `explorer.exe`:
  ~350 MB of **swap** between them with tiny RSS
* `MemAvailable` ~110 MB, `MemFree` ~76 MB, Slab 150 MB, zram full (492/493 MB)

Measures, both reversible and gated:

* **Reclaim** (`AW_KILL_WINE_SERVICES=0` off): a launcher step stops
  `services.exe`, `plugplay.exe`, `svchost.exe`, `rpcss.exe` ~25 s after the game
  process appears. Measured effect: `MemAvailable` 111 MB -> **268 MB**,
  `MemFree` 76 MB -> 242 MB, and the menu, which had been freezing into a static
  picture, **keeps animating**. These four are not required by the game: it
  reached the title screen with the port's own SCM bootstrap disabled too, and
  its RPC calls fail harmlessly. **`explorer.exe` is never touched** — it is the
  desktop the presentation path needs.
* **Page-cache drop** (`AW_DROP_CACHES=0` off): `sync; echo 3 > /proc/sys/vm/drop_caches`
  immediately before the game starts, so the pages the game needs can come back
  into RAM instead of being paged from swap.

### Page-cache drop: measured, and now off by default

`AW_DROP_CACHES` was added on the theory that giving the pages back before the
game starts would help.  Measured on the device: with it enabled the game
**stalls on its splash screen** (static picture, no menu) because the asset
loading then reads from cold storage; with `AW_DROP_CACHES=0` the same launcher
reaches the menu and the picture animates (8 distinct `kmsgrab` frames, app
alive, MainUI down).  The default is therefore **0** — exactly the trap the PR
review warned about ("it can also make the first post-launch accesses colder").

## Audio (still open)

* The card runs at 96 kHz with `period_size 960` (10 ms) / `buffer_size 3840`
  (40 ms), and `winealsa` chooses those values itself (the ALSA `defaults.pcm.*`
  hints are ignored).
* The device's `$HOME/.asoundrc` (`HOME=/mnt/SDCARD`) routes `pcm.!default`
  through **dmix**; the port's session was therefore dmix-backed.
* The applied forward fix: `$HOME/.asoundrc` now maps `default` straight to
  `hw:0,0` through a `plug` (format/rate conversion kept, dmix removed).
  See `package/animalwell/asoundrc-HOME-applied.conf` and
  `package/animalwell/asound.conf`.
* **Do not use `ALSA_CONFIG_PATH` for this.** It *replaces* the system
  `alsa.conf`, so the plugin definitions disappear (`Unknown PCM hw:0,0`) and
  `winealsa` cannot open the device — the game goes completely silent (measured).
* Remaining glitches are CPU/swap-bound (only 1–3 ALSA underruns per session, and
  `fuser /dev/snd/pcmC0D0p` shows the game as the sole holder, i.e. the launch is
  correct). The next levers are box64 JIT knobs and more real RAM, not the ALSA
  layer.

## Input (next)

The device exposes `/dev/input/event4` "TRIMUI Player1" (+ `js0`), but wine
cannot see it: wine drives gamepads through **SDL2**, and the port ships no
SDL2 for the emulated x86-64 side (`runtime/box64/x64lib/` has only
`libgcc_s.so.1`, `libstdc++.so.6`, `libunwind.so.8`). The device has a native
aarch64 `libSDL2-2.0.so.0` (2.32) which box64 may be able to wrap — that is the
next thing to verify, plus `WineBus: Enable SDL` and a proper
`SDL_GAMECONTROLLERCONFIG` mapping so the pad is presented as an Xbox-type
(XInput) controller. `gptokeyb` (pad -> keyboard) is the fallback.

## Build pipeline

`scripts/build_runtime.sh` no longer hard-codes the 11.18 hashes for the
`win32u.so` D3DKMT (`d3dkmt_init_vulkan`) patch: the pinned SHA/address/prologue
are only asserted for `WINE_VER=11.18`, and any other version is patched
dynamically (`nm` lookup + prologue sanity + `0xc3`); the observed
address/hashes are recorded in the generated
`wine-patches/D3DKMT-NOVULKAN.txt`. `WINE_VER`/`WINE_SHA` are already
environment-overridable, so a runtime for another wine version can be built
without editing the script.
