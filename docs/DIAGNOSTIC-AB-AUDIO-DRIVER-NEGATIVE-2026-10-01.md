## A/B: `Audio=none` -> `Audio=alsa` does not change the fault

I found a concrete configuration fact and tested it as a single reversible change.

### What I found

```
/tmp/animalwell-wineprefix/user.reg:  "Audio"="none"
prefix-template/user.reg:             "Audio"="none"
```

Wine's audio driver was set to `none`, while the driver libraries are present (`winealsa.so`, `winepulse.so`). That fits the mechanism I had just established: with no audio device enumerated, `FAudio_CreateMasteringVoice8` would take its error path after `FAudio_PlatformGetDeviceCount`, `FAudio_CreateMasteringVoice` would never reach its store at `0xd914`, `faudio->+0x10` would stay NULL, and `FAudio_CreateSubmixVoice +0x1a6` would dereference `[NULL+0xDC]` - exactly the reported `si_addr=0xdc`.

### The test

Backed up both `user.reg` files, flipped `"Audio"="none"` to `"Audio"="alsa"`, cleaned the field (lock pid killed, no launcher, no `standard_launch`, no game), and ran the valid harness.

```
guard_error=0  segv=1  xaudio=1  si_dc=1
[BOX64] 26266|SIGSEGV @0x7fb5e2bab8 (x64pc=0x7ffe32e9f6/"...xaudio2_9.dll + 0xe9f6", ...)
Signal 11: si_addr=0xdc, TRAPNO=14, ERR=4, RIP=0x7ffe32e9f6, prot=0, mmapped:0
```

The fault is byte-for-byte the same, and the log confirms the audio drivers were actually loaded:

```
[BOX64] Using emulated .../x86_64-unix/winepulse.so
[BOX64] Using emulated .../x86_64-unix/winealsa.so
```

### Conclusion

**Negative.** Setting the audio driver to `alsa` alone does not remove the crash, so "no audio device enumerated" is not sufficient to explain it - either enumeration still yields no usable device inside wine's unixlib on this handheld, or the mastering voice is created and the submix path is at fault for another reason. I am not going to claim the configuration finding was the cause; it is recorded as tested and rejected.

The change is reverted (both files restored from the `.ab-audio` backups, which are kept), the stock box64 is in place, and the field is left clean.

### Where the discrimination stands

The remaining question is unchanged and now sharper: does `FAudio_CreateMasteringVoice` get entered at all, and does it reach `0xd914`? The device-side way to answer it is a trace at those two addresses; the configuration-side shortcut has now been tried and did not help.
