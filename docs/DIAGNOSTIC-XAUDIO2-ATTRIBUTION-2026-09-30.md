## Attribution: the crash is caused by wine's XAudio2 (FAudio), and the port already has the knobs

Delta after the follow-up above.

### Decisive A/B

| run | result |
|---|---|
| T1V, audio enabled (FAudio 241000 in the 10.0 tree) | crash: `0x7FFE32E9F6` -> `xaudio2_9.dll +0xd9f6` |
| T1V, audio enabled, 11.18 tree's `xaudio2_9.dll` swapped in (FAudio 260901) | crash moves: `read access to 0x0 at 0x14001029F` (anonymous r-xp at the guest image base, i.e. translated code) |
| T1V, **`AW_NO_AUDIO=1`** (the port's own knob) | **no crash at all: `Unhandled` count = 0**, game process stays alive |

So the fault is attributable to wine's XAudio2/FAudio voice-creation path: substituting a different FAudio build moves the failure, and removing the module removes the crash.

### Why my earlier `xaudio2_9=d` export did nothing

The launcher builds `WINEDLLOVERRIDES` itself from `base_overrides` (line 531) and exports it (line 561), so an environment value is overwritten. The port already provides the proper knobs:

```
AW_NO_AUDIO=1   -> base_overrides="$base_overrides;xaudio2_9=d;xaudio2_8=d"
AW_XA2_NATIVE=1 -> base_overrides="xaudio2_9=n,b;$base_overrides"
```

### Current state after the attribution

With the audio disabled the crash is gone but the game does not render yet: it sits at 3 threads with the X server showing its empty root. Two plausible reasons to separate: the game waiting on an audio object it never gets, or the normal slow start on this device. Not yet distinguished.

### Next step I intend to take

The FAudio build is the suspect, and the port already supports a native module: fetch a current FAudio (x64) build, install it as a native `xaudio2_9.dll` and run with `AW_XA2_NATIVE=1`. The linked versions seen so far are 241000 (wine 10.0 tree) and 260901 (wine 11.18 tree), and the failure mode changed between them, which is consistent with the FAudio voice-creation bug rather than with anything Mali- or D3D12-specific.
