## The module carries symbols - the whole chain is now named, and the writer of `+0x10` is `FAudio_CreateMasteringVoice`

I had been treating this DLL as a stripped blob. It is not: it is FAudio, and `objdump -d` resolves every frame.

### The chain, named

```
0xe9f6   FAudio_CreateSubmixVoice +0x1a6        <-- fault (mov eax,[rax+0xDC])
0xe850   FAudio_CreateSubmixVoice +0x0          (entry; the call target from the chain)
0xe96e   FAudio_CreateSubmixVoice +0x11e        (the return address seen at RSP-0x08)
0x18bc0  FAudio_PlatformCreateMutex +0x0        (the helper called four times: +0x90/+0x98/+0xa0/+0xc0)
0x16ed0  FAudio_Initialize +0x0
0x1b56d  IXAudio2Impl_CreateSubmixVoice +0xfd   (calls FAudio_CreateSubmixVoice)
0x1b06d  IXAudio2Impl_CreateMasteringVoice +0xdd
0x20261  XAudio2Create +0xc1
```

So the crash is: `XAudio2Create` -> `IXAudio2Impl_CreateMasteringVoice` -> `IXAudio2Impl_CreateSubmixVoice` -> `FAudio_CreateSubmixVoice`, faulting at `+0x1a6` on `*(r12+0x10)` being NULL. The frame at `0x10158` is in the game's own image (base 0x140000000) and is not part of this symbol map - the name my script printed for it came from looking up a game address in FAudio's table and is meaningless; the correct label remains `Animal Well.exe +0x10158`.

### The writer of the NULL member is `FAudio_CreateMasteringVoice`

Scanning every function that stores to `[reg+0x10]` and also touches `+0xb8`/`+0xe0` gives one direct match for this object class:

```
FAudio_CreateMasteringVoice @0x18000d7f0
    18000d8f3: mov QWORD PTR [rax+0x10],0x0     ; clears it
    18000d914: mov QWORD PTR [r12+0x10],rax     ; installs the mastering-voice/output link
```

That is exactly the member `FAudio_CreateSubmixVoice` reads at `+0x1a6`. So `+0x10` is the link that mastering-voice creation is supposed to install, and `FAudio_CreateSubmixVoice` assumes it is present.

**Mechanism (stated as a hypothesis, but now a narrow one):** the mastering voice is either not created before the submix voice, or its creation does not reach the store at `0xd914` on this device - the audio-device path is the one that varies here, and the same code path is where the earlier `hw:0,0` vs `dmix` behaviour showed up. The stack above the fault even contains `IXAudio2Impl_CreateMasteringVoice` and `XAudio2Create`, which is consistent with mastering-voice creation being in flight or having just returned without installing the link; a raw stack cannot prove the ordering, so I am not claiming it.

### What this changes

* The fault is no longer anonymous: it is `FAudio_CreateSubmixVoice +0x1a6` reading the mastering-voice link that `FAudio_CreateMasteringVoice` is responsible for installing.
* The next check is concrete and local: run to the fault under a breakpoint-free trace of `FAudio_CreateMasteringVoice` (or check whether its store at `0xd914` is reached), i.e. determine whether the mastering voice is skipped or fails, rather than whether the submix path is wrong.
* Two of my earlier attributions are already retracted in this thread (`[rbx]` instead of `*(r12+0x10)`, and the RVA conversion); this comment supersedes both with the symbol-level facts.
