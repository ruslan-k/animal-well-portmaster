## Production precondition achieved: with MainUI gone and the PCM owned only by the game, the XAudio2 fault disappears

This is the run the plan asked for, and it isolates the audio track cleanly.

### How the precondition was reached

`principal.sh` does watch `/tmp/cmd_to_run.sh` and runs it, but it has an auto-resume guard:

```
60:  # When you select a game or app, MainUI writes that command to a temp file and closes itself.
67:  log_message "Auto Resume contract violation prevented: staged command already consumed once in this boot; removing duplicate /tmp/c..."
101: cp /tmp/cmd_to_run.sh "$FLAGS_DIR/lastgame.lock"   # set up autoresume
103: /tmp/cmd_to_run.sh >/dev/null 2>&1
```

That guard is why my earlier staging appeared to do nothing - the command is accepted once per boot, and the first attempt in this session had already consumed it. My attempt to clear it by extracting `FLAGS_DIR` from the script failed (`FLAGS_DIR=` came back empty), so the guard was not actually cleared.

What did work was the ordering: stage the command, then TERM MainUI while the supervisor is inside the command, and the supervisor cannot restart it.

### The monitor shows the window

```
### t=0  epoch=...661  mainui=1  pcm=26526      <- MainUI owns the PCM
### t=20 epoch=...703  mainui=1  pcm=26526
### t=40 epoch=...751  mainui=0  pcm=           <- MainUI gone, PCM free
### t=60 epoch=...806  mainui=0  pcm=19109      <- PCM owned by the game only
### t=80 epoch=...863  mainui=1  pcm=31092      <- supervisor restarted MainUI
```

and the timeline for the game itself:

```
1790802790 game pid=19109 started mainui=0 pcm=
1790802817 game pid=19109 GONE
```

### Result: the audio fault is gone, the strlen fault is the only one left

With MainUI absent and the PCM held only by the game:

* `xaudio2_9.dll` fault occurrences: **0** (was the recurring `0xDC` / thread 0024 fault)
* `page fault` occurrences: **0**
* `ntdll.dll + 0x64200` (`strlen`) occurrences: **51**
* outcome: `game_exit_code=137` after ~27 s

So the review's reasoning is confirmed on the device: **MainUI owning the PCM is what produced the XAudio2 fault**, and once the PCM is free the audio path stops faulting entirely. The blocker that remains in a properly-shaped run is the independent `strlen(NULL)` crash - which is plan Phase 4, not the audio track.

Also worth recording: MainUI comes back (`t=80`) as soon as the supervisor is no longer inside the staged command, so the PCM-free window is exactly the port's lifetime. That is the window `AW_ALSA_ROUTE=auto` should detect rather than assume.

### Errors made in this round

* `FLAGS_DIR` extraction returned empty, so the auto-resume guard was not cleared as intended; the run succeeded by ordering instead.
* My `picked_up` detection reported 0 while the game did in fact start, so that probe is unreliable and should be replaced by watching for `standard_launch` plus the game pid.
* Earlier `cmd_to_run.sh` conclusion ("silently no-ops") was too strong: it is consumed once per boot by design, which is a guard, not a no-op.
