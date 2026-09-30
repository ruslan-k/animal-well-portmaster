## The guard is a lock directory: `/tmp/animalwell-port.lock` - harness rule now exact

Found the mechanism, so the harness rule can be stated precisely instead of as a guess.

```
25:  LOCKDIR="/tmp/animalwell-port.lock"
80:  acquire_lock() {
88:      log "ERROR another ANIMAL WELL launcher is active: pid=$oldpid"
```

The lock is a **directory** containing a `pid` file, and it survived every one of my process-level cleanups - which is exactly why `pkill -f "Animal Well.sh"` never cleared it and why both Phase 4 runs were refused. On the device it held a stale pid:

```
drwxr-xr-x 2 root root 60 /tmp/animalwell-port.lock
-rw-r--r-- 1 root root  6 /tmp/animalwell-port.lock/pid
32555
```

I removed it (`rm -rf /tmp/animalwell-port.lock`) and verified it is absent, with no launcher and no `standard_launch` process alive.

### Harness rule, exact

Before any measurement run:

```
rm -rf /tmp/animalwell-port.lock            # clear the launcher's own lock
ps | grep -c "[A]nimal Well.sh"   -> 0      # no launcher
ps | grep -c "[s]tandard_launch"  -> 0      # no staged entry
grep -c 'another ANIMAL WELL launcher is active' <run log>  -> 0   # guard did not fire
```

If the last check is non-zero, the run measured somebody else's instance and must be discarded - which is what happened to both runs in this round, and why the earlier `VKD3D_DEBUG=none` reading is still unconfirmed.

### Where the port stands after this round

* The single furthest state observed in this session belongs to the leftover instance running with `VKD3D_DEBUG=none`: **330 MB RSS, 44 threads** (against 15 threads / 105 MB in every measured run), so with the audio path quiet and vkd3d logging off the title does substantial work.
* `resolve_addr.py` is in place (map line -> file offset -> PE section -> RVA, plus a backwards scan for the call instruction), so the `strlen` caller resolution is one clean SNULL0 run away.
* Everything else from the plan remains as listed in the previous comments.
