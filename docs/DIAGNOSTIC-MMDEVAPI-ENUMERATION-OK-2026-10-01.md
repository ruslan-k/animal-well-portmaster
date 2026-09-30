## Device enumeration works - so the mastering voice fails inside FAudio, after the device query

Ran the same clean harness with `WINEDEBUG=+xaudio2,+mmdevapi`.

### The backend does enumerate a device

```
0024:trace:mmdevapi:init_driver Loading driver list L"pulse,alsa,oss,coreaudio"
0024:trace:mmdevapi:load_driver Successfully loaded L"winepulse.drv" with priority Unavailable
0024:trace:mmdevapi:load_driver Successfully loaded L"winealsa.drv" with priority Neutral
0024:trace:mmdevapi:init_driver Selecting driver L"alsa" with priority Neutral
...
0024:trace:mmdevapi:MMDevice_SetPropValue Writing L"{F19F064D-082C-4E27-BC73-6882A1BB8E4C},0" returned 0
0024:trace:mmdevapi:MMDevice_SetPropValue Blob 00000000007AFD00 40
```

Pulse is unavailable for a concrete reason - `Failed to symlink .../pulse/<hash>-runtime to /tmp/pulse-...: Operation not permitted` - and wine therefore selects ALSA. But an `MMDevice` **is** created and its properties (including a 40-byte format blob) are written successfully, and the OS side is present (`/dev/snd/`: `controlC0`, `pcmC0D0c`, `pcmC0D0p`).

So "no audio device enumerated" is now ruled out as well. The device query that `FAudio_CreateMasteringVoice` performs cannot be failing for lack of a device.

### What that leaves

The mastering voice is requested (`inputChannels=2, inputSampleRate=0, deviceId=NULL, category=0x6`), the device exists, and yet `faudio->+0x10` - which only `FAudio_CreateMasteringVoice` writes, at `0xd914` - ends up NULL by the time the submix voice is created microseconds later. The failure is therefore **inside FAudio's mastering-voice construction after the device query**, and wine swallows it because `IXAudio2Impl_CreateMasteringVoice` ignores the return value.

Two things make that failure invisible in this trace: the game passes `flags=0x0` to XAudio2Create, so FAudio's own logging is off, and wine's `+xaudio2` channel only traces the entry points.

### The two ways to see it

1. **Force FAudio's own logging**: the debug flags come from `XAudio2Create`/`FAudioCreate`; wine's `xaudio2_initialize` passes them straight through. A build of the port's xaudio2_9.dll with the FAudio debug flag forced on would print the reason. This is a diagnostic build of a module the port already ships, not a change to game behaviour.
2. **Make wine report the failure**: `IXAudio2Impl_CreateMasteringVoice` in wine 10.0 drops the FAudio return value. Patching the port's copy to propagate it would make the game fail loudly instead of walking into the NULL - useful as a diagnostic, and it is also the shape of the actual upstream bug.

Neither has been done; both are one build away, and both are diagnostic rather than fixes.

### Summary of what this track has ruled out

* not the Vulkan loader, not D3D12 support (earlier);
* not the audio driver setting (`Audio=none` -> `alsa`, no change);
* not device enumeration (a device is created and its properties written);
* not "the game never asks for a mastering voice" (the trace shows the request).
