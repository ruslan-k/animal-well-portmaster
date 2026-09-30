## The wrapper's sparse commit budget defaults to 8 GiB on a 963 MB device; capping it alone does not stop the death

### Finding: the default budget is a design mismatch

`mali-wrapper/src/compatibility/device_emulation.cpp`:

```c
VkDeviceSize parse_budget()
{
    constexpr VkDeviceSize fallback = 8ull * 1024ull * 1024ull * 1024ull;
    const char* value = std::getenv("MALI_WRAPPER_SPARSE_COMMIT_BUDGET");
    if (value == nullptr || *value == '\0') return fallback;
    ...
```

So unless the environment says otherwise, the wrapper allows **8 GiB** of sparse GPU commits while the device has **986 MB of RAM in a single DMA zone**. The port's launcher never sets this variable (only the logging ones), so the default is what runs.

### Measured device state at the time of a death

```
Node 0, zone DMA   managed 246516 pages      (the only populated zone)
MemTotal 986064 kB   MemFree 525688 kB   MemAvailable 712980 kB
CmaTotal 131072 kB   CmaFree 130156 kB       SwapFree 2065884 kB
```

Plenty free by every ordinary measure, yet a watched run shows the game dying ~22-25 s after its pid appears, and dmesg at such a moment carries:

```
mali 1800000.gpu: OOM notifier: dev mali0  52664 kB
mali 1800000.gpu: OOM notifier: tsk Animal Well.exe  … 39976 kB
```

### A/B result: capping the budget did not stop the death

Run with `MALI_WRAPPER_SPARSE_COMMIT_BUDGET=268435456` (256 MiB):

* timeline: `game pid started` -> `GONE` 22 s later (same as with the 8 GiB default)
* no new OOM notifier lines appeared in dmesg for that run
* `page fault` count 0, vkd3d activity 121 lines

So the oversized default is a real defect worth fixing, but the cap alone is not sufficient - the run still ends before rendering. The remaining death has no page fault and (in this run) no new OOM line, so its cause still needs the log tail and a dmesg delta captured at the exact moment.

### Open items on this line

1. Capture the log tail and dmesg at the exact death to classify it (crash vs kill vs OOM).
2. Decide a sane default for `MALI_WRAPPER_SPARSE_COMMIT_BUDGET` on this class of device, and whether the launcher should set it.
3. The `strlen(NULL)` fault in ntdll (caller unidentified) is still waiting behind this.
