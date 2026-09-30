## Phase 4 step 1 (SNULL1) done: with `VKD3D_DEBUG=none` the strlen(NULL) fault disappears

This is the cheap A/B the plan put first for Phase 4, run in the production-shaped flow.

### Setup

* production shape: `cmd_to_run.sh` staged, MainUI TERMed while the supervisor was inside the command -> `mainui_after=0`, PCM free at game start (`pcm=` in the timeline)
* `VKD3D_DEBUG=none` exported for the run (the launcher's default at line 842 is `export VKD3D_DEBUG=${VKD3D_DEBUG:-warn}`, so an exported value wins; the seed steps pin `info` for themselves at lines 262/291/601)
* 10 Hz procfs watcher capturing `/proc/<game>/maps` and `smaps_rollup`

### Result

```
1790803125 game pid=21152 started mainui=0 pcm=
1790803152 game pid=21152 GONE
```

```
ntdll.dll + 0x64200 occurrences : 0     (was 51 in the previous run)
page fault occurrences          : 0
vkd3d output lines              : 0
maps captured                   : 116469 bytes
```

So with vkd3d logging off, **the `strlen(NULL)` fault does not happen at all**. That is exactly the branch the plan anticipated: if it disappears with `debug=none`, the NULL string is produced by vkd3d's debug formatting/logging path rather than by the game's own state.

This is a strong pointer, and it also explains why the fault was intermittent across earlier runs: it depends on which vkd3d warning/log path executes, not on a fixed game state.

### Caveats, stated plainly

* The game process still ended about 27 s after it started, with **no fault and no logged exit code** in the port log at that moment, so this run does not yet identify what ended it - that needs the same kernel-evidence treatment as before (the SNULL0 run ended with the strlen fault; this one has no fault at all, so it is a different ending).
* The `VKD3D_DEBUG=none` result means the fault is a *logging-path* defect. It does **not** mean shipping `none` is the fix: vkd3d output is needed for diagnosis, and the underlying NULL string should be found and fixed where it is produced.
* The maps watcher captured the file successfully this time (116 KB), but since no fault occurred there was no stack word to resolve. The watcher is ready for the next SNULL0-shaped run if the resolution is still wanted.

### Recommended next step on this track

Take the same production shape, set `VKD3D_DEBUG=warn` (the default) and keep the 10 Hz watcher, then resolve the `[rsp]` word at the fault against the captured map using the section headers (the file-offset trap called out in the earlier review). With the fault reproducible on demand in that shape, that resolution should finally name the vkd3d call site that passes the NULL string.
