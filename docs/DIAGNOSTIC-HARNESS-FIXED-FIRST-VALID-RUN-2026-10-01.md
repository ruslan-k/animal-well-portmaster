## Harness fixed: the guard is a pid-liveness check, and the first VALID run shows the XAudio2 fault, not strlen

### Why every earlier run was refused

The launcher's lock is a pid-liveness test, and I had been clearing the directory without killing the pid inside it:

```sh
acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then echo $$ >"$LOCKDIR/pid"; return 0; fi
    oldpid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
        log "ERROR another ANIMAL WELL launcher is active: pid=$oldpid"
        return 1
    fi
    ...
```

`kill -0 "$oldpid"` is the whole check. Removing `/tmp/animalwell-port.lock` while its recorded launcher was still alive just meant the lock got recreated with a live pid, and my new instance was refused every time.

The corrected sequence, which finally produced a clean field:

```
lock pid=<launcher pid> -> kill -9 that pid -> rm -rf the lock
pass 0: game=0 launcher=0 stdlaunch=0 lock=absent
field clean after 1 passes
```

### The first valid run

```
guard_error=0     <-- the guard was silent, so this run measured what was configured
strlen=0
faults=1
xaudio=1
exit=            <-- still running when the window closed
timeline: pid=12779 rss=105428 kB thr=15   (steady for the whole window)
```

So in a run that is finally trustworthy:

* the `strlen(NULL)` fault did **not** occur (`strlen=0`);
* the **XAudio2 fault did occur** (`xaudio=1`, `faults=1`);
* the game sat at 105 MB RSS / 15 threads for the whole observation window.

### Correction to an earlier claim

My previous statement that "dmix removes the XAudio2 fault" came from runs that this same guard had refused, i.e. from instances I had not configured. In the first valid run the audio fault is present, so that claim is withdrawn: **dmix does not by itself remove the XAudio2 fault.** What the earlier monitor did show correctly was that the PCM-free window exists and that the fault's appearance varies with it; the mechanism is still open.

### What is now measurable

* `resolve_addr.py` is in place and the maps watcher captured `/proc/<game>/maps` during this valid run, so the fault address can be resolved against the real map (map line -> file offset -> PE section -> RVA, plus a backwards scan for the call) in the next round. The target this time is the **XAudio2** address, not the strlen one.
* `guard_error` must be 0 for a run to count, and getting it to 0 requires killing the pid inside the lock, not just deleting the lock.
* The remaining plan items are unchanged, and Phase 4 now has a working harness to run them in.
