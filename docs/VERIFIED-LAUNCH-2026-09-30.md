> **SUPERSEDED by docs/WINE-10-AND-MEMORY-2026-09-30.md.** This note records
> the wine 11.18 state: the virtual desktop was required *because* wine 11.x's
> client-surface model produced garbage client rects on this fbdev X.  The port
> now runs on wine 10.0 with a plain window, so the virtual desktop, its caption
> and the ALSA_CONFIG_PATH candidate below are historical.

# Animal Well on TSPS (Longan / SpruceOS) — verified launch, 2026-09-30

Status: **the port reaches the game's title screen on the device.** Verified with
raw DRM scanout captures (`kmsgrab`) plus window-geometry probes; see the evidence
list at the bottom.

## What actually fixed it

### 1. Run the game inside wine's virtual desktop (root cause of the black screen)

Wine 11.18 computes garbage window rectangles on this fbdev X server: its
`client_surface_update_locked` traced `virtual_rect` x values of `-6029390`,
`-1565379458`, `-1561321442` while the window had `toplevel (nil)`. The game's
*client* X window — the surface the Mali wrapper presents into with
`xcb_shm_put_image` — was therefore placed far outside its visible parent, so the
frames were rendered but never seen (black panel, game stuck at the splash with
`vkd3d … command queue … which is flushing` warnings).

Launching the game inside wine's virtual desktop gives wine a sane window
hierarchy:

```sh
"$BOX64" "$WINE" explorer /desktop=aw,1280x720 "$EXE"
```

Measured after the change: `virtual_rect (4,30)-(1284,728)`, **0 of 2 garbage
position requests**, game window `ANIMAL WELL` 1288x732 at (10,10) with the
wrapper's presentation window 1280x700-ish at (4,23) inside it, and `kmsgrab`
showing the game instead of the black-plus-cursor frame.

### 2. Port-owned X config with a real video mode (`package/animalwell/xorg-aw.conf`)

The shared fbdev config reports the fbdev "current" mode with **dotClock = 0 and
refresh = 0.000 Hz**. Wine derives pacing/monitor data from it. The port's own
config declares an explicit Modeline for the same 1280x720 geometry:

    RandR A/B:  dotClock 0 / refresh 0.000 Hz  ->  dotClock 55296000 / refresh 60.000 Hz

The launcher prefers `$ROOT/xorg-aw.conf` when `XORG_CONFIG` is unset.

### 3. Memory hygiene and swap headroom (the OOM killer)

Measured on the 1 GB device: wine leftovers of *killed* sessions (notably
`start.exe`) survive and pin **400-560 MB of SWAP** with ~300 kB RSS. Once swap is
exhausted, an innocent kernel allocation (`kworker/power_supply_uevent ->
get_zeroed_page`) invokes the OOM killer, which takes the biggest task — the game:

    Out of memory: Killed process (Animal Well.exe) total-vm:9289204kB
      anon-rss:344252kB …       (preceded by "mali … OOM notifier")

The launcher now kills such leftovers before the game starts and ensures the
extra 2 GB swap file on UDISK is active. With both in place the game loads and
runs: app RSS ~280 MB + ~930 MB in swap (box64 JIT + wine structures — the game's
own data is only ~35 MB), swap stays ~2 GB free, no OOM.

### 4. The SCM bootstrap is *not* required (opt-in now)

`services.exe` was added for the game's COM/RPC init. Measured: the game reaches
the title screen with it disabled, while it costs a whole extra wine session
(`start.exe` + `services.exe` + `svchost.exe` + `rpcss.exe`, 400-500 MB of live
memory, mostly swapped). It is now behind `AW_SCM=1` (default off).

## Rejected approaches (do not retry these)

| Approach | Result |
|---|---|
| `HKCU\Software\Wine\X11 Driver` `"Decorated"="N"` | window becomes override-redirect, wine's rects go bad again, game hangs at the splash; the caption is still drawn |
| Launching without the virtual desktop (`"$BOX64" "$WINE" "$EXE"`) | game window at (-32,-32), client at garbage coordinates, black panel, splash stall (twice) |
| moving the wine **desktop** window to hide the caption | a single move can give a perfect borderless full-screen picture, but wine recomputes geometry: early move -> splash stall; later move -> menu without items |
| moving the **client** window to compensate | wine oscillates that window's absolute position by thousands of pixels; the window visibly jumps |
| `AW_XORG_SHADOWFB=0` | black screen: on TSPS the fbdev shadow copy performs the panel rotation |
| Mali timeline semaphores as the suspect | refuted: a headless probe reports `TIMELINE_SUPPORTED_AND_FUNCTIONAL` |

## Window caption

Wine's virtual desktop draws a themed caption inside the game window, so the
game image was 1280x698 inside the 1280x720 panel. Static wine window metrics
(negative values = pixels) shrink it from 30 px to 23 px and grow the client to
1280x705 — with no window movement, so the game keeps progressing:

    [Control Panel\Desktop\WindowMetrics]
    "CaptionHeight"="-12"  "CaptionWidth"="-12"
    "SmCaptionHeight"="-12" "SmCaptionWidth"="-12"
    "BorderWidth"="-4"     "PaddedBorderWidth"="0"

A truly borderless window would need the application (it asks for a captioned
window) or wine's decoration code to change — out of scope for this port.

## Known remaining work

* audio: the ALSA device runs at 96 kHz and the audio thread starves while the
  game is swapped in and out; candidates are an ALSA buffer config via
  `ALSA_CONFIG_PATH` and a box64 JIT-memory A/B (`BOX64_DYNAREC_BIGBLOCK` /
  `FORWARD`) to cut the ~1.2 GB emulation footprint.
* the caption above.

## How to launch / how to verify

Launch through the Spruce principal flow (write `/tmp/cmd_to_run.sh` with the Emu
path form, then exit the MainUI) — never the port launcher directly over SSH, or
the MainUI keeps the display and the ALSA device (winealsa then falls back to
dmix and audio glitches). Verify with `kmsgrab` (the only truthful capture on
TSPS: `fb0` is not the scanout) and `xwinprobe` (window tree/geometry). Both live
in `supervisor-audit/` in the working tree:

* `kmsgrab panel.png` -> the game's title scene (two rabbit silhouettes with
  glowing eyes) with the window caption;
* the geometry probes above.
