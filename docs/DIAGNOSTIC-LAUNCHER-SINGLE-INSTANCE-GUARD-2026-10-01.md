## Addendum to SNULL1: a launcher single-instance guard fired, and the ending is the OOM path again

Two facts from the tail of that run that change how it should be read.

### 1. The launcher has a single-instance guard, and it fired

```
[2026-09-30 21:17:31 +0000] PortMaster integration: controlfolder=/mnt/SDCARD/Persistent/portmaster/PortMaster cfw=spruce device=unknown arch=aarch64
[2026-09-30 21:17:31 +0000] ERROR another ANIMAL WELL launcher is active: pid=19528
```

So the launcher refuses to run when another instance is alive, and a leftover instance from an earlier run was still present. That means the game observed in the SNULL1 run (pid 21152) may have been started by the older instance rather than by the one my script staged, and `VKD3D_DEBUG=none` may not have been in that older instance's environment.

Consequence: **the `strlen = 0` result must be treated as provisional until it is reproduced with a guaranteed-clean launcher**. The claim "VKD3D_DEBUG=none clears the fault" is still the best-supported reading, but it now needs one confirmation run that first proves no other launcher is alive (for example by grepping the log for `another ANIMAL WELL launcher is active` and aborting the measurement if it appears).

### 2. The ending of that run is the OOM path again

```
[ 3144.689120] mali 1800000.gpu: OOM notifier: dev mali0  56308 kB
[ 3144.690191] mali 1800000.gpu: OOM notifier: tsk Animal Well.exe  tgid (21152)  pid (21152)  51748 kB
[ 3144.690197] mali 1800000.gpu: OOM notifier: tsk display_text.el  tgid (1435)  pid (1435)  4560 kB
```

Same pid as the game in the timeline, so the ~27 s ending in this run is the memory-pressure path rather than a crash - consistent with the earlier classification, and still without the kernel victim line that would make it conclusive. Note also `display_text.el` appearing as a consumer; that is a Spruce UI process, which fits the MainUI-returned observation at the end of the run.

### What this means for the plan

* Phase 4 step 1 needs one clean confirmation run (no other launcher alive) before `VKD3D_DEBUG=none` can be called the fault's exonerator.
* The port's single-instance guard should be part of the harness: every measurement run should assert the log does not contain `another ANIMAL WELL launcher is active`, otherwise the environment is not the one being tested.
* The OOM ending and the strlen fault remain two separate tracks; this run had the OOM ending and no fault.
