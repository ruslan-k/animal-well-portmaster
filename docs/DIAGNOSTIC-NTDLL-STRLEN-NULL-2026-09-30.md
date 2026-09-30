## With audio fixed, the next crash is `strlen(NULL)` inside ntdll - and it is not a watchdog

Follow-up to the ALSA routing fix.

### The killer is a real crash, not a bound

The launcher log around the failure:

```
[BOX64] 12466|SIGSEGV @0x7f96830df0 (???(0x7f96830df0))
        (x64pc=0x7ffff94200/"...runtime/wine/lib/wine/x86_64-windows/ntdll.dll + 0x64200",
         rsp=0x20f5a8, stack=0x7f980b0000:0x7f988b0000 own=(nil) fp=0x119bfde0),
        for accessing (nil) (code=1/prot=0)
[BOX64] Signal 11: si_addr=(nil), TRAPNO=14, ERR=4, RIP=0x7ffff94200
/mnt/SDCARD/Roms/PORTS/Animal Well.sh: line 982: 12466 Killed  "$BOX64" "$WINE" "$EXE"
game_exit_code=137
```

So `game_exit_code=137` is the aftermath of a genuine SIGSEGV (the shell reports the killed child), not a watchdog. `run_watchdog` is only used for the smoke (line 262) and the display seed (line 283); the game itself is a plain invocation at line 982.

### The faulting function is identified exactly

`ntdll.dll` was pulled and the RVA resolved with a PE parser:

```
RVA 0x64200 -> file offset 0x64200
target bytes : 80 39 00 74 1b 48 89 c8      ; cmp byte ptr [rcx], 0 ; jz +0x1b ; mov rax, rcx
nearest export <= target : strlen  @ 0x64200
next export > target     : strncat @ 0x64230
```

So the game (or wine) calls **`strlen(NULL)`**: `RCX = 0`, and wine's ntdll `strlen` reads the first byte. The registers agree (`RDI=0`, `RBP=0`, `RAX=0x20f5d0`), and the vkd3d lines immediately before the fault are shader-compiler warnings, so the NULL string arrives from the rendering path, not from audio.

### State of the port now

* Audio: fixed by restoring dmix (see the previous comment) - `page fault` count 0, the game reaches vkd3d feature-level init and shader compilation.
* Graphics: `PASS_DXGI_FACTORY` and `PASS_D3D12_DEVICE` hold under the frozen T1V environment.
* Remaining blocker: this `strlen(NULL)`.

### Next step

Get the caller: re-run with a live maps capture (so the guest module bases are known at fault time) plus `BOX64_SHOWBT=1`, then resolve the guest return address already visible on the stack (`RSP+0x00 = 0x0000007fffc4a946`) against those maps. Also worth doing for durability: ship dmix as the port default instead of the direct `hw:0,0` route, since the current default breaks the game whenever the UI holds the sound card.
