## The free-card precondition is not reliably achievable, so the decisive run is still missing

Two things happened, both worth recording.

### The first attempt was lost to a device reboot

The free-PCM run with `+xaudio2,+alsa` never finished: the device rebooted while it was running (`uptime` came back at 166 s, `/tmp` wiped, no output). Nothing from that run exists, and I am not going to pretend otherwise. The device came back clean (MainUI up, no port processes).

### The re-run launched with the card still busy

```
PCM before stopping MainUI: state: RUNNING owner_pid 4883
TERM MainUI <pid>
  t=50s state=RUNNING owner=4883
  t=60s state=RUNNING owner=4883
  t=70s state=RUNNING owner=4883
  t=80s state=RUNNING owner=4883
PCM free after 90s: state=RUNNING owner=4883
```

The poll timed out with the card still held by pid 4883, so the launch happened with the device busy after all - and the whole chain reproduced exactly:

```
IXAudio2Impl_CreateMasteringVoice (..., 2, 0, 0x0, 0)
IXAudio2Impl_CreateMasteringVoice device id (null), category 0x6
MMDevCol_GetCount (0x7BBF20)->(0x20F4F4)
IXAudio2Impl_CreateSubmixVoice  (..., 2, 48000, 0, 0, 0, 0)
alsa_try_open default, flow: 0 -> failed: -16 (Device or resource busy)
alsa_try_open plughw:0,0, flow: 0 -> failed: -16 (Device or resource busy)
alsa_try_open default, flow: 1 -> Enumerated device: L"In: default"
```

`guard_error=0`, `segv=1`, EBUSY count 2.

### What this means for the measurement

The two facts I need have still never been observed together:

* the run with a **free card** (the previous round) had no `+alsa`, so it is unknown whether the render device opened and what the collection count was;
* the run with **`+alsa`** (this one) had a **busy card**, so it reproduced the EBUSY chain.

Also, the precondition itself is now suspect: in the earlier round the card freed 4 s after MainUI was terminated, in this one it never freed over 90 s, and the holder (pid 4883) is not MainUI as far as the poll shows. So "terminate MainUI and wait" is not a sufficient recipe - something else takes or keeps the card, and it needs to be named before the free-card run can be trusted.

### Next step

Identify what holds the PCM (pid 4883 and whatever replaces it) and only then repeat the free-card run with `+alsa` enabled. Until both hold at once, the question "does winealsa refuse a device it can open" stays unanswered.
