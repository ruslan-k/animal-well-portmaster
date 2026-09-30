## Answer: the render collection is empty - and that also explains why the driver A/B was a no-op

The trace around the mastering-voice request, in order:

```
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice (0x79FA40)->(0x1420CFA60, 2, 0, 0x0, 0)
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice device id (null), category 0x6
0024:trace:mmdevapi:MMDevEnum_EnumAudioEndpoints (0x7FFDF071A0)->(0,1,0x20F4F8)   ; eRender, ACTIVE
0024:trace:mmdevapi:MMDevCol_GetCount (0x7BD3E0)->(0x20F4F4)                       ; succeeds
0024:trace:mmdevapi:MMDevCol_Release Refcount now 0
0024:trace:mmdevapi:MMDevEnum_Release Refcount now 3
0024:trace:xaudio2:IXAudio2Impl_CreateSubmixVoice (0x79FA40)->(0x1420CFA68, 2, 48000, 0x0, 0, 0, 0)
[BOX64] SIGSEGV ... si_addr=0xdc ... x64pc=0x7ffe32e9f6
```

`GetCount` is **called and returns** (the collection object is created, the call is made, then released) - so it is not a failing HRESULT, it is a count of **zero**. wine's `EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE)` produces an empty collection for this prefix.

That closes the last unknown of the chain:

1. game asks for a mastering voice at the default rate (`inputSampleRate = 0`);
2. FAudio must query the device (`FAUDIO_DEFAULT_SAMPLERATE`);
3. `FAudio_PlatformGetDeviceDetails` -> `index (0) >= count (0)` -> `FAUDIO_E_INVALID_CALL` (the `OpenDevice` assert did not fire, so it is the count check);
4. `FAudio_CreateMasteringVoice` returns before `audio->master = *ppMasteringVoice`, so `faudio+0x10` stays NULL;
5. wine 10.0's `IXAudio2Impl_CreateMasteringVoice` ignores the return value;
6. the game's next call - submix voice, NULL send list - dereferences `[NULL+0xDC]`.

### Correction to my own earlier A/B

The `Audio=none` -> `Audio=alsa` test was **a no-op**, and I should say so: the mmdevapi trace shows `winealsa.drv` was already selected (pulse is `Unavailable`), so setting the registry to `alsa` changed nothing about which backend ran. The negative result was therefore not evidence about the driver setting at all - it was evidence that the ALSA backend, which was already in use, enumerates no render endpoint here.

### Why pulse is unavailable, and what is left

```
Failed to symlink /mnt/SDCARD/Saves/flip/home/.config/pulse/<hash>-runtime to /tmp/pulse-...: Operation not permitted
```

wine's pulse driver cannot set up its runtime directory, is reported `Unavailable`, and the fallback ALSA driver - which does load and is selected - exposes no active render device for this prefix. The OS side is fine (`/dev/snd`: `controlC0`, `pcmC0D0c`, `pcmC0D0p`), so this is wine's backend enumeration, not missing hardware.

Next step, now narrow: make one of wine's audio backends expose an active render endpoint for this prefix - either repair the pulse runtime-dir symlink so the pulse driver becomes available, or find why winealsa reports none (its enumeration opens devices to test them, so the port's ALSA configuration and the card's busy state are the places to look).

This is the first time in this track that the entire chain - from the game's API call to the exact line of FAudio that returns - is closed with source, disassembly and runtime trace agreeing at every step.
