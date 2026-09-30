## Clean Phase 4 attempt: the guard still fires because my staged commands are replayed by auto-resume

### What happened with the lock actually cleared

This run did everything the previous comment prescribed:

```
lock=absent launcher=0 stdlaunch=0 mainui=1
mainui_after=0
```

and yet:

```
guard_error=1  strlen=0  faults=0  xaudio=0  exit=
```

So clearing `/tmp/animalwell-port.lock` is necessary but **not sufficient**: the launcher still reported another instance active. The reason is the auto-resume mechanism I noticed earlier and did not chase:

```
101: cp /tmp/cmd_to_run.sh "$FLAGS_DIR/lastgame.lock"   # set up autoresume
```

Every command I stage is recorded as the resume target and then **replayed**. That is why a game is always already running when my new instance starts, why the guard fires every time, and why my watchers keep following someone else's game.

### The useful part: the replayed games go much further than anything I measured

```
1790804215 pid=11932 rss=420504 kB thr=52
1790804217 pid=11932 rss=448964 kB thr=52
1790804221 pid=11932 (gone)    thr=2
```

**448 MB RSS and 52 threads** - the furthest state in this whole session, and it ends with `strlen=0`, `xaudio=0`, `faults=0`, i.e. **no fault of either known kind**. So the game does substantial work on the replay path and then ends through the memory/kill path.

That is also a hint worth acting on: the auto-resume path is the closest thing to a real menu launch I have been able to trigger, and it is the configuration where the title does the most work. It deserves to be the measured baseline rather than treated as contamination.

### Harness rule, corrected again

1. `rm -rf /tmp/animalwell-port.lock`
2. remove the auto-resume record (`lastgame.lock` in the launcher's flags dir) so nothing is replayed
3. assert no launcher, no `standard_launch`, no `Animal Well.exe`
4. stage the command, TERM MainUI
5. assert `guard_error=0` in the run log before reading any other number

Step 2 is the one that has been missing in every attempt so far.

### Standing state

`resolve_addr.py` is ready and untouched by this; the `strlen` resolution still needs one run where the guard is genuinely quiet, and this run again produced no fault to resolve (`strlen=0`).
