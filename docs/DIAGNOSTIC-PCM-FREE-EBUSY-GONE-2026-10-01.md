## With the PCM actually free, EBUSY disappears and the game takes the audio device

Following the EBUSY measurement, I changed the harness precondition: terminate MainUI and then **poll until `/proc/asound/card0/pcm0p/sub0/status` really reports the PCM free** before launching, instead of sleeping a fixed six seconds.

```
PCM before stopping MainUI: state: RUNNING owner_pid 26366      (MainUI)
TERM MainUI 26301
  t=0s state=RUNNING owner=26366
PCM free after 4s: state= owner=
pcm at launch: state= owner=
EBUSY count in the run: 0
```

and during the run:

```
1790810884 START pid=11965
1790810885 pid=11965 rss=138384 thr=1 pcm=13598
1790810887 pid=11965 rss=169404 thr=4 pcm=13598
```

Three things changed at once:

* **`Device or resource busy` is gone entirely** (0 occurrences, against 2 in the previous run) - wine's ALSA driver could open the render device this time;
* **the game itself now holds the PCM** (`pcm=13598` in the timeline, i.e. the game opened the audio device - it never got that far before);
* the game progressed to 169 MB RSS and 4 threads.

So the empty render collection was **not** a wine or hardware defect: it was the card being held when wine enumerated. The precondition, not the driver setting, was the variable.

### What still happens

A SIGSEGV is still recorded and the crash dialog reappears on the panel (`screen-at-fault2.png`, 12104 bytes). I do not yet know whether it is the same `[NULL+0xDC]` fault or a different one further along - the run did not have `+xaudio2` enabled, so the trace that would say whether `CreateMasteringVoice` and `CreateSubmixVoice` completed is not in this log. That is the immediate next measurement, and it is cheap: the same free-PCM harness with `WINEDEBUG=+xaudio2`.

### Note on the screenshots

The panel grab at fault time is now part of the harness (`screen-at-fault.png` at 2 s, `screen-at-fault2.png` at 5 s), which is how the dialog text was read verbatim in the previous comment. The second grab is the dialog again in this run, so the game is still ending in wine's crash dialog rather than exiting cleanly.

### Correction to the record

Earlier comments attributed the failure to the audio driver setting and then to device enumeration. The driver setting was a no-op (alsa was already selected), and enumeration works - what actually blocked it was the card being busy at enumeration time. The EBUSY line in the `+alsa` trace is what finally made that visible.
