## Two experiments: a NULL-safe strlen removes that crash, and -force-d3d11 does not switch the renderer

### 1. Making ntdll's strlen NULL-safe removes the fault (and proves the diagnosis)

Five-byte patch at the `strlen` export (RVA 0x64200), reversible, backup kept:

```
original : 80 39 00 74 1B   cmp byte ptr [rcx],0 ; jz +0x1b
patched  : 48 85 C9 74 1B   test rcx,rcx        ; jz +0x1b
```

Same branch target, so a NULL pointer takes the empty-string path instead of reading through it.

Result with the patch, dmix audio, launcher defaults:

* `ntdll.dll + 0x64200` occurrences: **0**
* `page fault` occurrences: **0**
* but the run still ends badly: `game_exit_code=139` (SIGSEGV), and the last log lines before it are `vkd3d_init_feature_level` warnings (`Depth clip enable is not supported`, `Vertex attribute instance rate divisor is not supported` - Mali feature set, benign).

So the NULL string is not the whole story: whatever calls `strlen(NULL)` then uses the result, and faults later. That also confirms the fault site attribution independently of any stack guesswork.

The patch was reverted afterwards (ntdll is back to `80 39 00 74 1b`).

### 2. `-force-d3d11` is passed but the game still uses vkd3d/D3D12

Unity ships renderer-switching flags, so I added `-force-d3d11` to the launcher's game command (launcher backed up) and ran with `WINE_D3D_CONFIG=renderer=vulkan` + `VKD3D_CONFIG=virtual_heaps`:

* box64 confirms the argument reaches the game: `[BOX64] argv[2]="-force-d3d11"`.
* Yet vkd3d is still active in the log (21 vkd3d lines) and wined3d/d3d11 appears only 3 times.

So this build appears to include only the D3D12 renderer and ignores the flag - the vkd3d path cannot be bypassed from the command line. The launcher change was reverted.

### 3. Open question: a recurring SIGKILL

Several runs end with `game_exit_code=137` **without** any page fault or box64 SIGSEGV line in the log, roughly a minute in. 137 is SIGKILL, i.e. an external kill rather than a crash, and it is not the launcher's `run_watchdog` (that only wraps the smoke and the display seed). It shortens runs and should be identified - candidates on this firmware are the Spruce supervisor chain and the system watchdogs (`thermal-watchdog`, `power_button_watchdog_v2.sh`, `buttons_watchdog.sh`).
