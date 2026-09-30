## The guard fires even with the lock cleared and the resume record removed - and the replayed instance reaches 473 MB

Ran the corrected harness exactly as prescribed:

```
lock=absent launcher=0 stdlaunch=0 mainui=1      (after rm -rf /tmp/animalwell-port.lock and removing lastgame.lock)
mainui_after=0
```

Result:

```
guard_error=1  strlen=0  faults=0  xaudio=0  exit=
```

So clearing the lock and the resume record is **still not sufficient**, and I have to be plain that the guard's trigger is not yet identified. The most consistent explanation left is that the check sees *any* port process, not only a launcher: my cleanup kills the game at the start of a script, but the replay can put a new game back within the few seconds before the command is staged, and a live `Animal Well.exe` is then enough to refuse the new instance. That would also explain why my watchers keep following a game they did not start.

### The replayed instance keeps getting further

```
1790804572 pid=22797 rss=427656 kB thr=52
1790804575 pid=22797 rss=435168 kB thr=45
1790804578 pid=22797 rss=473368 kB thr=35
1790804581 pid=22797 (gone)   thr=2
```

**473 MB RSS** - the highest yet - with the thread count falling 52 -> 45 -> 35 before it ends, and again with `strlen=0`, `xaudio=0`, `faults=0`: no fault of either known kind, so the ending is the memory/kill path. The falling thread count in the last seconds looks like shutdown rather than a crash.

I checked the panel immediately after this instance ended: game absent, launcher absent, screen showing the empty X root (`2759` bytes, one md5). So the replayed instance dies before its screen can be inspected, which is why no picture has been observed from it yet.

### Harness rule, third revision

1. clear `/tmp/animalwell-port.lock` and remove `lastgame.lock`
2. kill port processes in a **tight loop** and assert **no `Animal Well.exe`** (not just no launcher) immediately before staging
3. stage the command, TERM MainUI
4. assert `guard_error=0` before reading any number

Step 2 has to include the game process, and the assertion has to be made at the instant of staging - that is the part every attempt so far got wrong.

### Net state of this track

* The `strlen` resolution is still unexecuted for the same reason: no valid run, no fault captured.
* The best observed state remains the replayed instance (473 MB / 52 threads), and it dies through the memory/kill path before it can be seen on screen.
* Nothing was shipped to the port for this; the repo change from the earlier round (dmix as the ALSA default) stands.
