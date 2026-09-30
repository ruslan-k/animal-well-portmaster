## Fault address resolved against the real map: RVA 0xe9f6 in xaudio2_9.dll, and the file-offset trap demonstrated

Using the maps captured during the first valid run (`guard_error=0`), and `resolve_addr.py` which follows the procedure from the review:

```
target address: 0x7ffe32e9f6
map   : 7ffe321000-7ffe343000 r-xp 00001000 b3:09 4190396
        /mnt/sdcard/mmcblk1p1/Roms/ports/animalwell/runtime/wine/lib/wine/x86_64-windows/xaudio2_9.dll
perms : r-xp   file_off=0x1000   delta_in_map=0xd9f6
file offset corresponding to the address: 0xe9f6
section ..text  raw=0x1000 va=0x1000 -> RVA 0xe9f6
hint: nearest export <= RVA is @ 0x21d0 (+0xc826)   <- internal region, far from any export
```

Three things this settles:

1. **The file-offset trap is real and now measured.** `address - map_start` is `0xd9f6`, which is *not* the RVA, because the mapping starts at file offset `0x1000`. Going through the section headers gives **RVA 0xe9f6** - which is exactly the offset box64 itself printed (`xaudio2_9.dll + 0xe9f6`). So box64's number was right all along and my earlier `0xd9f6` was the map-relative delta. All future references should use `0xe9f6`.
2. **The guest address is present in the host maps**, as the review expected: `0x7ffe32e9f6` falls inside a file-backed mapping of `xaudio2_9.dll`, so module identification from `/proc/<game>/maps` works without any Wine-side tooling.
3. **The faulting code is internal to the module**: the nearest export is 0xc826 bytes away, so this is an internal function of wine's `xaudio2_7` implementation (the module is built as `xaudio2_9.dll`), consistent with the FAudio voice-creation path established earlier.

### What remains for the caller question

The stack word (`RSP+0x00`) was not captured in this run - the log did not contain the register dump line - so the *caller* of the faulting instruction is still not resolved. The tooling now handles that case too: with a captured `RSP+0x00` the same script computes its RVA and scans backwards for the `call` instruction, which is what will name the call site.

### Summary of the measurement track

* Harness: valid runs now require killing the pid inside `/tmp/animalwell-port.lock`; `guard_error` must be 0.
* First valid run: `strlen=0`, `xaudio=1`, `faults=1`, game steady at 105 MB / 15 threads.
* Fault: `xaudio2_9.dll` **RVA 0xe9f6**, internal function, guest address visible in the host maps.
* Withdrawn: the earlier claim that dmix alone removes the XAudio2 fault.
