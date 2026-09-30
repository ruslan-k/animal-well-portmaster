## Phase 1+2 executed: the production-shaped run survives and reaches rendering; several corrections and two method findings

I ran the plan from 5919545690. Below: what was done, what it showed, what went wrong, and what remains.

### 0. Launch mode: the documented `cmd_to_run.sh` handoff does NOT start the game here

The review's procedure (write `/tmp/cmd_to_run.sh`, let `principal.sh` pick it up) was tried first, with a 30 s wait. Result:

```
launch_mode=spruce(principal pickup attempted)
mainui_before=6486  mainui_after_term=1  principal running: 1
-> the game never appeared: game_pid=none for all 78 monitor rows (~200 s)
```

So on this firmware the `cmd_to_run.sh` handoff silently does nothing, which is why earlier direct launches were used. **What does work** is the Emu path form of the documented entry:

```
/mnt/SDCARD/Emu/PORTS/../../spruce/scripts/emu/standard_launch.sh "/mnt/SDCARD/Roms/PORTS/Animal Well.sh"
```

That produced a real run (`launch_mode=spruce-standard_launch-emu-path`), with `standard_launch_pid=25495` and `principal_pid=2155` both present.

### 1. MainUI is NOT gone even in that flow, and it owns the PCM

```
game_pid=22182
mainui_count=1
pcm_owners=26526            <-- MainUI
parent_chain=22182:Animal Well.exe <- R: <-
standard_launch_pid=25495   principal_pid=2155
```

Two facts worth keeping:

* `MainUI` survives the `kill -TERM` because the supervisor restarts it (`mainui_after_term=1`), so it cannot be kept dead outside the principal flow.
* In this flow MainUI still owns `/dev/snd/pcmC0D0p`, so **dmix is not an optional robustness choice here - it is required**. The direct `hw:0,0` route can only be correct if PCM ownership is actually free, which this flow does not give.

### 2. The run itself: first configuration in this session that survives the 22-25 s window

With the Emu path, dmix, T1V graphics, no heavy debug channels and the light 1 Hz procfs monitor:

```
MemFree 450216 kB   MemAvailable 572280 kB   Cached 171408 kB
Slab 162120 kB      SReclaimable 56432 kB    SUnreclaim 105688 kB
CmaFree ~64 MB (from ~130 MB at start)
Xorg pid=14125 rss=24132 swap=10652 thr=14
Animal Well.exe pid=22182 rss=105608 swap=114256 thr=15
wineserver pid=22338 rss=21240 swap=11716
MainUI pid=26526 rss=25484 swap=38876
```

The game stayed alive with 15 threads and 105 MB RSS for the whole observation window, where every earlier direct-launch run died at ~22 s. No death, no SIGKILL, no OOM block in the dmesg delta.

### 3. Corrections to my earlier claims

* **The Mali "OOM notifier" lines do not prove Mali triggered the kill.** Accepted. Those lines are the driver reporting GPU-associated allocations during an OOM episode; the kernel victim line (`Out of memory: Killed process ...`) is what classifies a death, and my earlier phrasing overreached. The 735 notifier lines in dmesg are evidence of repeated OOM episodes on this device, nothing more.
* **A monitor bug of mine**: my first sidecar printed misaligned fields (`Slab 4645280 kB`, `SwapFree 2516`), which was a parsing bug, not device state. The numbers above come from the corrected raw-dump monitor.
* **The `oom_score_adj` experiment** (game -1000, MainUI 500) took the device off the network until it rebooted; recorded as unsafe and not to be repeated.

### 4. Where the run stands

The game process lives, `vkd3d` is active (10 lines) and shader work happened, but the panel shows wine's crash dialog and the log carries one page fault that is **not** the ntdll `strlen` one (`ntdll.dll + 0x64200` count 0, `page fault` count 1). So the production-shaped run converted the problem from "dies in 22 s" into "survives but faults during rendering" - a different, and now observable, failure.

### 5. Plan items not yet done

* The `AW_ALSA_ROUTE=auto|dmix|direct` interface with PCM-ownership detection (I shipped dmix as the config default instead, see the repo change below).
* `AW_SEED_D3D_RENDERER` / `AW_GAME_D3D_RENDERER` split so the T1V game renderer is reproducible from source rather than from an exported variable.
* `AW_LIGHT_MONITOR=1`, `AW_MINIMAL_PRODUCTION=1`, `AW_VM_TUNE` save/restore, zram-before-Wine ordering, the reclaim-delay A/B, sparse/Vulkan allocation telemetry, the M0-M4 matrix, the VKD3D_DEBUG=none A/B, the maps watcher and the raw-stack Box64 variant.
* `strlen(NULL)`: no patch shipped, caller still unidentified.

### 6. Repo change made now (plan item "repository cleanup needed now")

The three configs that forced `hw:0,0` + `S32_LE` + `96000` are no longer the source of truth:

```
package/animalwell/asound.conf
package/animalwell/audio-home/.asoundrc
package/animalwell/asoundrc-HOME-applied.conf
```

Each now ships the dmix default with the measurement recorded in a comment, and the previous contents are kept as `*.direct-hw.bak` so the direct route stays available as an explicit experiment rather than as the default.
