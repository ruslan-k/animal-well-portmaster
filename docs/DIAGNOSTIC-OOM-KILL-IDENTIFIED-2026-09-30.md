## The recurring SIGKILL is the OOM path (Mali GPU notifier), and one protection experiment is unsafe

### The killer is identified: memory pressure, not a crash and not a watchdog

A run with a sidecar watching the game pid caught both the death and the kernel's reason. Timeline:

```
1790799427 game pid=11142 started
1790799452 game pid=11142 GONE          <-- 25 seconds later
```

And in dmesg at that moment:

```
mali 1800000.gpu: OOM notifier: dev mali0  52664 kB
mali 1800000.gpu: OOM notifier: tsk Animal Well.exe  tgid (11142)  pid (11142)  39976 kB
mali 1800000.gpu: OOM notifier: tsk MainUI           tgid (31991)  pid (31991)  12688 kB
```

So the recurring `game_exit_code=137` with no page fault and no box64 SIGSEGV line is the **kernel OOM path, triggered through the Mali GPU notifier**, and the game is the process it picks. That matches the earlier memory-pressure work on this device (963 MB total, single DMA zone, Mali heap ~962 MB).

This also explains why the strlen crash appeared only in some runs: whichever of the two arrives first (the NULL-string fault or the OOM kill) decides how the run ends, and both are on the same short clock.

### A protection experiment that must not be repeated

I tried protecting the game with `oom_score_adj = -1000` while making `MainUI` expendable (`oom_score_adj = 500`). The result: **the device dropped off the network entirely** (`No route to host`), became unreachable for several minutes, then came back with a fresh boot (`uptime` ~180 s) and a new SSH host state.

So the OOM killer, once the game is made unkillable, goes after something else and on this firmware that can take the system down with it. Do not make MainUI (or any system service) an OOM target to save the game. If `oom_score_adj` is used at all, it should be a small negative value for the game only, never paired with raising another process's score.

### Device state after recovery

* `wine=0`, `MainUI=1`, ~712 MB available, dmix ALSA route intact.
* `ntdll.dll` strlen reverted to `80 39 00 74 1b`; the launcher has no `-force-d3d11`.
* SSH needed the key-forwarding helper again after the reboot.

### Where this leaves the port

Two independent, short-clock blockers remain: the `strlen(NULL)` fault in ntdll (caller still unidentified) and the OOM kill about 25 seconds in. Both need to be dealt with for the game to reach a menu; the OOM one is arguably first, since it removes the run before anything else can be observed.
