## Phase 4 step 4 started: the raw-stack Box64 variant is patched and building

The deeper guest stack cannot be obtained from any existing knob (`BOX64_DUMP=1` was tried and adds nothing), so the plan's patched Box64 is required. That work is now underway.

### The patch

The dump loop in `src/libtools/signals.c` prints only nine qwords, four below and four above `RSP`:

```c
if(rsp!=addr && getProtection((uintptr_t)rsp-4*8) && getProtection((uintptr_t)rsp+4*8))
    for (int i=-4; i<4; ++i) {
        printf_log_prefix(0, log_minimum, "%sRSP%c0x%02x:0x%016lx", (i%4)?" ":"\n", i<0?'-':'+', abs(i)*8, *(uintptr_t*)(rsp+i*8));
    }
```

Changed to a 48-qword window with a per-word protection check, so a deeper stack is printed without ever reading an unmapped address:

```c
if(rsp!=addr && getProtection((uintptr_t)rsp-8*8) && getProtection((uintptr_t)rsp+40*8))
    for (int i=-8; i<40; ++i) {
        if(!getProtection((uintptr_t)rsp+i*8)) { printf_log_prefix(0, log_minimum, "\nRSP+0x%02x:<unmapped>", (i<0?-i:i)*8); continue; }
        printf_log_prefix(0, log_minimum, "%sRSP%c0x%02x:0x%016lx", (i%4)?" ":"\n", i<0?'-':'+', abs(i)*8, *(uintptr_t*)(rsp+i*8));
    }
```

Confirmed in the tree: `1321: for (int i=-8; i<40; ++i) {`. This is a pure diagnostic change to a test build; nothing in the port's runtime is touched, and the stock box64 stays in place on the device.

### The build

Cross-built for the device with the same recipe the earlier device builds used (`aarch64-linux-gnu-gcc`, in an Ubuntu 20.04 container), source tree at `c61543e`:

```
aarch64-linux-gnu-gcc (Ubuntu 9.4.0-1ubuntu1~20.04.2) 9.4.0
cmake -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DARM64=ON
```

It is running in the background; the binary lands in `/mnt/external/Hermes/box64-stackdump-build/box64`. When it completes, the next run is: install it beside the stock binary, run the same valid harness (`guard_error=0`), and the dump should then contain the return addresses above `RSP+0x18` - which is what is needed to name the caller of the function that faults at `xaudio2_9.dll + 0xe9f6`.

### Why this is the right next step

The fault itself is fully characterised now: `mov eax,[rax+0xDC]` where `rax = [rbx]` is NULL while `rbx` is a valid heap pointer, i.e. a live object whose leading pointer was never set, used in wine's XAudio2 voice-creation path. What is missing is the *producer* of that object, and the current dump stops at `RSP+0x18` with `RBP` zero, so no unwinder and no frame chain is available - only a wider raw-stack window can supply the next return address.
