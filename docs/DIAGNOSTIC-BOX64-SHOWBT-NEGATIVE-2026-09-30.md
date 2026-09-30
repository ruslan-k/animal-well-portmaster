## Negative result: `BOX64_SHOWBT=1` / `BOX64_SHOWSEGV=1` stall the game on this device

Tried the reviewer's item 3 route to get the caller of `strlen(NULL)`: launched with `BOX64_SHOWBT=1 BOX64_SHOWSEGV=1 BOX64_ROLLING_LOG=64` plus a watcher refreshing the live `/proc/<pid>/maps`.

Outcome: the game does not progress. It sits at 3 threads with the empty X root and never reaches the shader work, whereas the identical configuration without those variables reaches 15 threads and vkd3d shader compilation before it dies. The log fills with box64's own handler noise instead:

```
[BOX64] 7431|SIGSEGV @0x34b67920 (???(.../box64+0x367920))
        (x64pc=0x60020c60/"box64/waitpid", rsp=(nil), stack=0x7fb46af000:0x7fb4eaf000 ...)
```

So on this device the backtrace/rolling-log variables are counterproductive for a live game run, and the maps of the box64 host process do not expose the guest module bases anyway (guest DLLs are host-mapped files with different addresses).

### Better route for the caller

The guest base of the crashing module is derivable from the crash line itself: `x64pc=0x7ffff94200` with `ntdll.dll + 0x64200` gives base `0x7ffff30000`. The same trick needs the other modules' guest bases, which a single `WINEDEBUG=+module` run prints at load time. Then the return address already visible on the stack (`RSP+0x00 = 0x0000007fffc4a946`) can be resolved without any of the stalling variables.

### Current verified state of the port

* dmix audio route: `page fault` count 0; the game reaches `vkd3d_init_feature_level` and shader compilation.
* `PASS_DXGI_FACTORY` + `PASS_D3D12_DEVICE` under the frozen T1V environment.
* Remaining blocker: `strlen(NULL)` at `ntdll.dll + 0x64200`, reached during rendering work.
