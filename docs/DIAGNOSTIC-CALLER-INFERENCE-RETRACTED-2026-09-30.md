## Correction: the caller of `strlen(NULL)` is NOT identified - two inferences retracted

I have to retract the caller attribution from the previous comment.

### What was claimed and why it fails

I paired module names with guest bases by parsing the `WINEDEBUG=+module` log (the pairing looked plausible: `kernelbase 0x7fffc10000`, `combase 0x7fff8f0000`, `rpcrt4 0x7fff5c0000`, ... `ntdll 0x7ffff30000`) and read the stack word `RSP+0x00 = 0x7fffc4a946` as a return address. That placed the caller in `kernelbase.dll` at `+0x3a946`, and the nearest export looked like `GetNamedPipeHandleStateW`.

Both steps fail on inspection:

1. **The stack word is not a code address.** Disassembling kernelbase around `ImageBase + 0x3a946` (`ImageBase = 0x174000000`):

```
17403a93d:  e9 71 fe ff ff   jmp  17403a7b3 <GetNamedPipeHandleStateW+0x33>
17403a942:  90               nop
17403a943:  90               nop
17403a944:  90               nop
17403a945:  90               nop
17403a946:  90               nop          <-- the stack value points here
```

So `0x3a946` lands in NOP padding, not in executable code. Reading `[RSP]` as the caller's return address was an assumption, and it does not hold here.

2. **The nearest-export heuristic is unsound anyway.** The wine 11.18 source of `GetNamedPipeHandleStateW` (`dlls/kernelbase/sync.c`) contains no `strlen` at all - it calls `GetEnvironmentVariableW` under `if (user && size ...)`. So even if the address were valid, the name would have been wrong: static helpers are not in the export table, and a return address can sit in the middle of an internal function.

### What stands, with evidence

* **The fault itself:** `strlen(NULL)` in `ntdll.dll + 0x64200` - opcode `80 39 00 74 1b 48 89 c8` (`cmp byte ptr [rcx],0 ; jz ; mov rax,rcx`), with `RCX = 0`, export-confirmed (`strlen @ 0x64200`, next `strncat @ 0x64230`). This is solid and does not depend on the retracted inference.
* **The audio fix:** dmix route, `page fault` count 0, the game reaches `vkd3d_init_feature_level` and shader compilation.
* **D3D12:** `PASS_DXGI_FACTORY` and `PASS_D3D12_DEVICE` under the frozen T1V environment.
* The crash context: the last log lines before the fault are vkd3d shader-compiler warnings, so the NULL string plausibly comes from the rendering path - hypothesis only.

### What would actually identify the caller

Something that does not rely on guessing from a stack word: a guest-level backtrace from a debugger that reports real frames (`winedbg` with output captured through a pty or wineconsole), or a relay/`+module`-free instrumentation of the `strlen` entry, or a crash dump the debugger can unwind. The three heavy logging channels tried so far each changed the behaviour under observation, so this needs a route that does not perturb the run.
