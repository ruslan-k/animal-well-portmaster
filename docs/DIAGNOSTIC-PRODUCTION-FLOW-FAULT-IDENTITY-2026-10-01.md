## Addendum: the single fault in the production-shaped run is the XAudio2 one again

The previous comment said "one page fault that is not the ntdll strlen one". Here is what it actually is:

```
[BOX64] 22182|SIGSEGV @0x7f97a13ab8
        (x64pc=0x7ffe32e9f6/"box64/.../runtime/wine/lib/wine/x86_64-windows/xaudio2_9.dll + 0xe9f6",
         rsp=0x20faa0, ...)
wine: Unhandled page fault on read access to 00000000000000DC at address 0000007FFE32E9F6
      (thread 0024), starting debugger...
```

So it is the **same XAudio2/FAudio NULL fault** seen earlier: same `0xDC` read, same thread 0024. The offset is printed as `+0xe9f6` here against `+0xd9f6` before, and that difference is exactly the trap called out in the review - the mapping in the maps output starts at a non-zero file offset, so `address - map_start` is not the PE RVA. The correct RVA has to be computed through the section headers, and the earlier `0xd9f6` figure should be treated as approximate until it is recomputed that way.

Consequences for the plan:

* dmix does not remove the XAudio2 fault in the production-shaped flow. In this run the fault no longer kills the process immediately - the game stays alive with 15 threads and wine's crash dialog on the panel - which is a different, and better, failure mode than the earlier 22 s death, but it is still the audio path.
* MainUI being alive and owning the PCM in that flow is therefore still the prime suspect for the audio fault, which is what `AW_ALSA_ROUTE=auto` with real PCM-ownership detection is meant to make explicit. That interface is still outstanding from the plan.
* The `strlen(NULL)` fault did not appear in this run at all (`ntdll.dll + 0x64200` count 0), so it remains an independent, still-unexplained track.
