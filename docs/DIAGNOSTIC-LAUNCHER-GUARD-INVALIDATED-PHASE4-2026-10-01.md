## Phase 4 attempted: the launcher's single-instance guard invalidated both runs, but the leftover instance reached 44 threads / 330 MB

### What the guard actually is

The launcher refuses to start when it believes another instance is alive, and the check is pid-based:

```
ERROR another ANIMAL WELL launcher is active: pid=19528
```

Both of this round's staged runs logged that error (`guard_error=1` in each summary), so **neither SNULL1 nor SNULL0 measured the environment I set**: a leftover instance from the previous round was still alive and my staged instances were rejected. The game observed in both sub-runs was the *same* pid (8122) in both timelines, which confirms both watchers were looking at the leftover instance's game.

So the previous round's provisional result stands unchanged: `VKD3D_DEBUG=none` remains *the best-supported reading* but is still **not confirmed** by a clean run.

### The valuable part: the leftover instance got much further than anything measured

That leftover instance ran with `VKD3D_DEBUG=none` (from the earlier attempt) and its game progressed to:

```
1790803692 pid=8122 rss=282392 kB thr=33
1790803698 pid=8122 rss=324788 kB thr=43
1790803710 pid=8122 rss= (gone)  thr=2
```

**330 MB RSS and 44 threads** - against 15 threads / 105 MB in every run I had measured before. That is the furthest this title has come in this session, and it happened with vkd3d logging off, which is consistent with the SNULL1 hypothesis rather than contradicting it.

It also means the port is closer to working than the measured runs suggested: with the audio path quiet (PCM free, MainUI gone) and vkd3d logging off, the game does substantial work before it ends.

### Method failure to fix before any further measurement

* Every run must assert `guard_error=0`; if the launcher refuses, the measurement is about the other instance and must be discarded, not reinterpreted.
* The leftover instance has to be found and stopped explicitly. My `pkill -f "Animal Well.sh"` did not stop it, so the guard's own pid source is the thing to clear (the check is in the launcher, the pid it reports is the evidence).
* The watcher also needs to key on the *instance* it started, not on "any Animal Well.exe", otherwise it silently follows someone else's game.

### What was captured

* `snull1/game.maps.last`: 118523 bytes captured, but no fault occurred in that run, so there was no stack word to resolve.
* `snull0/game.maps.last`: 0 bytes, no fault, `strlen=0`, `faults=0` - the SNULL0 shape was never actually exercised because of the guard.
* `resolve_addr.py` is written and ready (map line -> file offset -> PE section -> RVA, plus a backwards scan for the call instruction), so the resolution is one clean SNULL0 run away.
