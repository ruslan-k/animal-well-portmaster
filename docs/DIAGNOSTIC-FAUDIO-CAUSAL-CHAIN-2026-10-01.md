## The causal chain is now static: `FAudio_CreateSubmixVoice` reads the mastering voice's channel count, and that link is installed only if mastering-voice creation gets past the device query

### What `+0x10` actually is

In `FAudio_CreateMasteringVoice` (0xd7f0) the link is installed at 0xd914, and the object being installed is the newly allocated voice:

```
0xd826: mov  ecx,0x158
0xd82b: call QWORD PTR [r12+0xb8]      ; allocate the voice via faudio->allocator
0xd837: mov  [rbp+0],rax               ; return it through arg 2
0xd86d: mov  [rax],r12                 ; voice->faudio = ctx
0xd874: mov  DWORD PTR [rax+0xc],2     ; type = mastering
0xd8da: mov  [rax+0xd8],ebx            ; voice->+0xd8 = sample rate
0xd8e9: mov  [rax+0xdc],esi            ; voice->+0xdc = channels
...
0xd914: mov  [r12+0x10],rax            ; faudio->+0x10 = the mastering voice
```

So `faudio->+0x10` is the mastering voice, `voice->+0xd8` is its sample rate and `voice->+0xdc` its channel count. (The store at 0xd8f3 that my previous scan highlighted is `[newvoice+0x10]=0`, a different object - the relevant store is 0xd914.)

### What the fault reads

`FAudio_CreateSubmixVoice +0x1a6` is `mov eax,[rax+0xDC]` with `rax = [r12+0x10]` - i.e. it reads **the mastering voice's channel count** to feed the floating-point ratio that follows (`mulsd`/`cvtsi2sd`/`divsd`). With no mastering voice, that read is `[NULL+0xDC]`, which is exactly the fault box64 reports (`si_addr=0xdc`).

### Why the link can be missing - the device query

`FAudio_CreateMasteringVoice` has an early branch when the caller passes zero for sample rate or channels:

```
0xd816: test ebx,ebx ; je 0xda60       ; sample rate == 0
0xd81e: test esi,esi ; je 0xda60       ; channels == 0
...
0xda60: mov  edx,[rsp+0x4c8]           ; device index
0xda67: lea  r8,[rsp+0x40]
0xda6f: call FAudio_GetDeviceDetails   ; <-- device query
0xda74: test eax,eax
0xda76: jne  0xdbb0                    ; query failed -> error path, 0xd914 never runs
0xda7c: test ebx,ebx ; jne 0xda90
0xda80: movzx ebx,[rsp+0x446]          ; sample rate from the device details
0xda90: mov  esi,[rsp+0x448]           ; channels from the device details
0xda97: jmp  0xd826                    ; proceed with construction
```

So: if the game asks for a mastering voice with zero rate/channels (the normal "let the device decide" call), FAudio must query the device; if that query fails, the function takes the error path and **`faudio->+0x10` is never set** - while the game has already asked for a submix voice, which then dereferences it.

### Status of the two remaining candidates

1. **Mastering-voice creation fails at the device query** (`FAudio_GetDeviceDetails`), leaving the link unset. This is device-dependent and is where the audio path differs on this handheld, so it is the leading candidate.
2. **No mastering voice is requested before the submix voice** on this title's init path.

The stack above the fault contains `IXAudio2Impl_CreateMasteringVoice +0xdd` and `XAudio2Create +0xc1`, which is consistent with candidate 1 - mastering-voice creation being in flight or having just returned - but a raw stack cannot establish the ordering, so I am not asserting it. The next step is to observe whether `FAudio_GetDeviceDetails` returns non-zero (or whether `FAudio_CreateMasteringVoice` is entered at all) for this launch, which discriminates cleanly between the two.
