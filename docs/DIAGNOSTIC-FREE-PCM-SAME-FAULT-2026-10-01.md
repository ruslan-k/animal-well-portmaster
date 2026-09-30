## Addendum: the fault is at the same address, so removing EBUSY is necessary but not sufficient

I can answer the question I left open one comment ago: the SIGSEGV in the free-PCM run is at the **same** place.

```
11965|SIGSEGV @0x7fac366ab8 (x64pc=0x7ffe32e9f6/"...x86_64-windows/xaudio2_9.dll + 0xe9f6", ...)
```

`xaudio2_9.dll + 0xe9f6` - the same `mov eax,[rax+0xDC]` in `FAudio_CreateSubmixVoice +0x1a6`. So the mastering voice still did not materialise even with the card free and the game holding the PCM (`pcm=13598`), and the game still ends in the crash dialog (`screen-at-fault2.png`).

What that means precisely:

* the EBUSY line was a real defect in the precondition and removing it changed observable behaviour (0 busy errors, the game takes the audio device, reaches 169 MB / 4 threads);
* but the render collection still ends up empty for some other reason, so `FAudio_PlatformGetDeviceCount` still returns 0 and the chain to `[NULL+0xDC]` is unchanged.

The next measurement is therefore the same free-PCM harness with `WINEDEBUG=+xaudio2,+alsa`, which will show whether `alsa_try_open` succeeds now and what the collection count is. That single run separates "the card was busy" from "winealsa still refuses the device it can open".
