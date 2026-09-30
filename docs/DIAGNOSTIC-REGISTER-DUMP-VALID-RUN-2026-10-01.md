## Register dump from the valid run: the fault is `mov eax,[rax+0xDC]` with RAX=0 inside one internal function, and the stack above it is empty

The dump was present in the log after all (my watcher had been keyed to the strlen line, so it never broke on this fault and I had not looked again).

```
[BOX64] 12779|SIGSEGV @0x7f7a20aab8 (???(0x7f7a20aab8))
        (x64pc=0x7ffe32e9f6/"box64/.../runtime/wine/lib/wine/x86_64-windows/xaudio2_9.dll + 0xe9f6", rsp=0x20faa0, ...)
RAX:0x0000000000000000 RCX:0x00000000007bfcd0 RDX:0x0000000000000000 RBX:0x00000000007bf150
RSP:0x000000000020faa0 RBP:0x0000000000000000 RSI:0x0000000000000002 RDI:0x00000000007bf190
 R8:0x0000000000000000  R9:0x00000000007bfcd0 R10:0x0000000000230000 R11:0x0000000000000030
R12:0x00000000007bbdf0 R13:0x0000000000000000 R14:0x000000000000bb80 R15:0x0000000000000000
RSP-0x20:0x00000000007bbdf0 RSP-0x18:0x0 RSP-0x10:0x0 RSP-0x08:0x0000007ffe32e96e
RSP+0x00:0x0 RSP+0x08:0x0 RSP+0x10:0x0 RSP+0x18:0x0
x64opcode=8B 80 DC 00 00 00 F2 0F
```

### What this establishes

* **Instruction confirmed**: `8B 80 DC 00 00 00` is `mov eax,[rax+0xDC]` with `RAX=0` - the same NULL dereference signature as the original report, now located at `xaudio2_9.dll + 0xe9f6` (the RVA resolved through the section headers in the previous comment).
* **The object is NULL, the surrounding pointers are not**: `RCX=0x7bfcd0`, `RDI=0x7bf190`, `RBX=0x7bf150`, `R9=0x7bfcd0` are all valid guest heap addresses, while `RAX`, `RDX` and `RBP` are zero. So a live object is being used and one of its members is NULL - not a wholly uninitialised context.
* **The return address is inside the same function**: `RSP-0x08 = 0x7ffe32e96e`, i.e. RVA `0xe96e`, only `0x88` bytes before the faulting instruction. Both addresses fall in the same internal function region (nearest export is 0xc826 bytes away).
* **Nothing deeper on the stack**: `RSP+0x00` through `RSP+0x18` are all zero, and `RBP` is zero, so there are no frame pointers to walk and no further return addresses in the dump. Taken at face value the faulting function sits at the bottom of that thread's stack, which is consistent with it being reached through a callback or a tail call - the caveat the review raised about tail calls applies here, so this is a strong candidate rather than a proof.

### What it means for the plan

The fault is not in the game and not in the graphics stack: it is inside wine's `xaudio2_7` implementation (shipped as `xaudio2_9.dll`), in an internal function that reads a member at `+0xDC` from a NULL object while other registers hold valid heap pointers.

To go further I need one of:

* a stack dump deeper than `RSP+0x18` (the raw-stack Box64 variant the plan proposes, which prints 16-32 qwords without any unwinder), or
* a run where the same fault happens with a non-zero `RBP` chain, or
* the same address resolved against the module's symbol information if a build with symbols can be produced.

The current dump simply does not contain the caller, and I am not going to infer it from a nearest-export heuristic again.
