## The discriminator answers it: the game asks for a mastering voice with sample rate 0, which is exactly the device-query path, and wine ignores the failure

One run with `WINEDEBUG=+xaudio2` on a clean field (`guard_error=0`) produced the whole sequence:

```
0024:trace:xaudio2:DllMain Using FAudio version 241000
0024:warn:xaudio2:xaudio2_initialize Processor affinity not implemented in FAudio
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice (000000000079FC00)->(00000001420CFA60, 2, 0, 0x0, 0000000000000000)
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice device id (null), category 0x6
0024:trace:xaudio2:IXAudio2Impl_CreateSubmixVoice  (000000000079FC00)->(00000001420CFA68, 2, 48000, 0x0, 0, 0000000000000000, 0000000000000000)
```

Three facts, all previously hypotheses:

1. **A mastering voice *is* requested** - so it is not the "never asked for" candidate. The call is `inputChannels=2, inputSampleRate=0`.
2. **Sample rate 0 is precisely the branch I found in the disassembly** (`0xd816: test ebx,ebx ; je 0xda60`), the one that forces `FAudio_GetDeviceDetails` before the voice can be constructed and before the link at `0xd914` can be installed.
3. **The submix voice is requested immediately afterwards** with `inputChannels=2, inputSampleRate=48000`, and the send list is NULL - which in wine's code is wrapped and handed to `FAudio_CreateSubmixVoice`, whose default target is the mastering voice. That is the read that faults at `[faudio+0x10]->+0xDC`.

So the order is: mastering voice with rate 0 -> device query path -> (fails here, link never installed) -> submix voice with NULL send list -> dereference of the missing mastering voice. The game never gets an error in between.

### Why the game sees no error - wine drops it

From wine 10.0's `dlls/xaudio2_7/xaudio_dll.c`, `IXAudio2Impl_CreateMasteringVoice`:

```c
FAudio_CreateMasteringVoice8(This->faudio, &This->mst.faudio_voice, inputChannels,
        inputSampleRate, flags, NULL /* TODO: (uint16_t*)deviceId */,
        This->mst.effect_chain, (FAudioStreamCategory)streamCategory);
...
This->mst.in_use = TRUE;
```

The FAudio return value is **not checked** and `in_use` is set unconditionally. So a failed mastering-voice creation is silently swallowed, and the very next API call the game makes (a submix voice) walks into the NULL link. That is the bug shape: wine 10.0's xaudio2_7 does not propagate the failure.

### What this rules in and out

* Ruled out: "the game never requests a mastering voice".
* Confirmed: the request happens with `inputSampleRate = 0`, i.e. the device-query path, and the submix call follows immediately with a NULL send list.
* Still open: **why** the device query fails here. FAudio's own diagnostics are off because the game passes `flags=0x0` to `FAudioCreate`, so the failure is silent in this trace; the `Audio=none` -> `alsa` A/B I ran earlier did not change it either.

### Next step

The remaining question is now a single, well-posed one: does wine's audio backend enumerate any device for this prefix? That is one more run with `WINEDEBUG=+xaudio2,+mmdevapi` (or `+winealsa`) on the same clean harness, which will show the enumeration and the reason the device details come back unusable. That is the last unknown between this trace and a working mastering voice.
