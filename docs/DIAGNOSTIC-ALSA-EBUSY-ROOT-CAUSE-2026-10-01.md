## Root cause measured: wine's ALSA driver cannot open the render device - EBUSY

The `+alsa` channel answers the question this track has been narrowing toward:

```
0024:trace:alsa:alsa_try_open devnode: default, flow: 0
0024:warn:alsa:alsa_try_open The device "default" failed to open: -16 (Device or resource busy).
0024:trace:alsa:alsa_try_open devnode: plughw:0,0, flow: 0
0024:warn:alsa:alsa_try_open The device "plughw:0,0" failed to open: -16 (Device or resource busy).
0024:trace:alsa:alsa_try_open devnode: default, flow: 1
0024:trace:alsa:construct_device_id Enumerated device: L"In: default"
```

`flow: 0` is render, `flow: 1` is capture. **Both render devices fail to open with `-16` (EBUSY)**, while the capture device opens fine and is enumerated. That is why the render collection is empty, why `FAudio_PlatformGetDeviceCount` returns 0, why the mastering voice is never built, and why the game's submix call dereferences `[NULL+0xDC]`.

Note what this also explains: `default` is the dmix device, and it is busy too - so whatever holds the card is holding the *hardware*, not just one PCM stream.

### The screenshots

The user pointed out that the crash window is on screen, so the run now grabs the panel at fault time:

* `screen-at-fault.png` (3184 bytes) - first grab, 2 s after the SIGSEGV;
* `screen-at-fault2.png` (12104 bytes) - the wine crash dialog, read verbatim:

```
The program (unidentified) has encountered a serious problem and needs to close.
We are sorry for the inconvenience.
This can be caused by a problem in the program or a deficiency in Wine.
You may want to check the Application Database for tips about running this application.
[Show Details] [Close]
```

Screen grabs are now part of the harness for every run, not a one-off.

### `ShowCrashDialog=0` works, but does not give the backtrace on stderr

Set as a DWORD (`"ShowCrashDialog"=dword:00000000`) it takes effect: the dialog is gone, the screen stays blank, and the process exits with code 5 instead of sitting in the dialog. wine does **not** print a backtrace to stderr in that mode - `backtrace=0` in the log, and the only line is the usual `starting debugger...`. So the backtrace really does live only behind the dialog's **Show Details** button, which means getting it requires a click on that button.

I had first written the value as a string (`"ShowCrashDialog"="0"`), which wine ignores - the dialog still appeared. The DWORD form is the one that works, and the setting has been reverted afterwards (backups kept).

### Where the chain now stands

Everything is measured except the identity of the process holding the card: the render device is busy at enumeration time, which happens a few seconds into the game's start, after MainUI has been terminated by the harness. `/proc/asound/card0/pcm0p/sub0/status` reports `RUNNING` with an `owner_pid` throughout, so the next step is to name that pid and find out whether it is a port leftover, the Spruce audio path, or something that starts with the game.
