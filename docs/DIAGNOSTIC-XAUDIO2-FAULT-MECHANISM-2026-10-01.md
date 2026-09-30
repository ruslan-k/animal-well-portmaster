## Mechanism of the XAudio2 fault: a live object whose first field is NULL, and BOX64_DUMP=1 does not deepen the stack

Two results from the valid run with `BOX64_DUMP=1`.

### 1. `BOX64_DUMP=1` adds nothing - the plan's patched-Box64 step is genuinely required

```
guard_error=0  segv=1  strlen=0  faults=1  xaudio=1
x64pc=0x7ffe32e9f6 -> xaudio2_9.dll + 0xe9f6
RSP-0x20:0x7c1850  RSP-0x18:0x0  RSP-0x10:0x7c1850  RSP-0x08:0x0000007ffe32e96e
RSP+0x00:0x0  RSP+0x08:0x0  RSP+0x10:0x0  RSP+0x18:0x0
x64opcode=8B 80 DC 00 00 00
```

The dump is byte-for-byte the same shape as the run without it (heap addresses differ only by ASLR), and the same nine qwords are all that is printed. So there is no lighter existing knob for a deeper guest stack: the raw-stack Box64 variant from the plan is the correct next tool, not a shortcut I can take.

The useful part is that the fault is **deterministic**: the return address `0x7ffe32e96e` appeared again, identical, in this independent run.

### 2. The disassembly explains the NULL

Bytes before the fault (RVA 0xe940..0xe9f6, `.text` where file offset == RVA):

```
48 8b 03              mov rax,[rbx]
8b 94 24 b8 00 00 00  mov edx,[rsp+0xb8]
89 b0 e8 00 00 00     mov [rax+0xe8],esi
48 8b 03              mov rax,[rbx]
44 89 b0 ec 00 00 00  mov [rax+0xec],r14d
48 8b 03              mov rax,[rbx]
89 90 f0 00 00 00     mov [rax+0xf0],edx
48 8b 03              mov rax,[rbx]
83 fe 01              cmp esi,1
...
8b 80 dc 00 00 00     mov eax,[rax+0xDC]     <-- faults
```

Every store in this sequence does `rax = [rbx]` first, so the object pointer used is **`[rbx]`**, not `rbx`. The dump shows `RBX=0x7bb710` (a valid guest heap pointer) while `RAX=0`, which means **`[rbx]` is NULL**: the object at `rbx` exists but its *first field* - the vtable/interface pointer at offset 0 - is zero. The faulting instruction then dereferences that NULL at `+0xDC`.

So the fault is not a wild pointer and not a stack problem: it is an object that is reachable but only partially constructed, with its leading pointer still NULL, being written through.

### 3. The call that produces the return address is identified

Scanning for call instructions in the same window:

```
call rel32 at RVA 0xe94b -> target 0x18bc0
call rel32 at RVA 0xe969 -> target 0x18bc0     <-- returns to 0xe96e, the observed RSP-0x08
```

`0xe969 + 5 = 0xe96e`, exactly the stack value, so the deterministic return address comes from this call to an internal helper at `0x18bc0`. Both the call site and the fault are inside the same internal function of `xaudio2_9.dll` (wine's `xaudio2_7`; nearest export is `CreateFX` at `0x21d0`, more than 0xc000 bytes away, so export proximity says nothing here - as the review warned).

### What this means for the plan

The immediate cause is now concrete: a partially constructed object with a NULL leading pointer is used in wine's XAudio2 voice-creation path. The *producer* of that object - which is what actually needs fixing - still requires a deeper stack capture, because the dump stops at `RSP+0x18` and `RBP` is zero. Options remain the raw-stack Box64 variant, a run with a populated `RBP` chain, or symbols for the module.
