## Root cause found: the XAudio2 fault was an ALSA routing regression I had introduced, not a wine bug

The audio route was the cause, and it was self-inflicted.

### What was wrong

Both ALSA configs in play routed the default PCM straight to `hw:0,0` through a plug layer at 96000 Hz S32_LE:

```
# /mnt/SDCARD/.asoundrc  and  <port>/asound.conf  (both created by my fix-alsa-direct.py patch)
pcm.!default { type plug  slave { pcm "hw:0,0"  format S32_LE  rate 96000 } }
```

The card is held by `MainUI` (`/dev/snd/pcmC0D0p`, state RUNNING), so a direct `hw:0,0` open cannot succeed for a second client. Wine's XAudio2 then proceeds with a NULL device and faults in FAudio voice creation at `xaudio2_9.dll +0xd9f6`.

### The A/B that proves it

Restoring the dmix route (the system `.asoundrc` from `.asoundrc.bak-20260930-130953`, `pcm.!default { type plug slave.pcm "dmix" }`) and moving the port-local direct-hw config aside, with **everything else identical** (launcher defaults, audio on):

| configuration | result |
|---|---|
| direct `hw:0,0` (my patch) | page fault `read 0xDC` at `xaudio2_9.dll +0xd9f6`, thread 0024, deterministic |
| **dmix** (restored) | **`page fault` count 0** |

And with dmix the game now gets properly into rendering: vkd3d initialises the feature level (`vkd3d_init_feature_level` warnings for `shaderClipDistance`/`shaderCullDistance`, which are the Mali feature set, not errors) and compiles shaders. This is the first configuration in this session where the game reaches D3D12 work at all.

### Consequence

* The earlier conclusion "crash in wine's XAudio2/FAudio" is still true as an observation, but its cause is the ALSA route, not the FAudio build. The FAudio substitution A/B moved the failure because it changed which object was NULL, not because of the version.
* `AW_NO_AUDIO=1` removing the crash was consistent with this: no audio module, no NULL device.
* The port-local `asound.conf` and the `hw:0,0` system `.asoundrc` should not ship: they break the game whenever the UI holds the card. The dmix route is the correct one on this device.

### New blocker, next step

With audio fixed the game is killed early: the launcher logs `game_exit_code=137` (SIGKILL) roughly one to two minutes in, before the menu appears, and the panel stays on the empty X root. The launcher's `run_watchdog` (lines 234-245) is only used for the smoke and display seed, so the killer is not yet identified - candidates are the Spruce principal supervisor and the launcher's own exit path. Raising/identifying that bound is the next step, and it is now the only thing between the port and a rendered menu.
