## The holder is MainUI - restarted after TERM, which is why the poll never succeeds

Named the pid from the last run: `4883` is

```
comm=MainUI  cmd=/mnt/SDCARD/spruce/flip/bin/MainUI /mnt/SDCARD/App/PyUI/main-ui/mainui.py -device ...
```

So the card is not held by a mysterious process: it is MainUI. The reason the free-card poll timed out over 90 s is that terminating MainUI does not keep it down - the Spruce supervisor brings it back, and the new instance takes the PCM again. In the earlier round it happened to stay down for the 4 s the poll needed; in the last one it came back inside that window and held the card for the whole timeout.

That also explains why the two required facts have never coincided: the free-card run raced the restart and won once, the `+alsa` run raced it and lost.

**Corrected recipe for the free-card run:** defeat the restart rather than race it - keep killing MainUI in a loop until the launch has happened (or suspend the supervisor for the duration), and assert `owner_pid` is empty immediately before `setsid` starts the game. Only then does a run with `+alsa` measure whether winealsa refuses a device it can open.

Everything else from the previous comments stands unchanged: the chain is
`CreateMasteringVoice(2, 0)` -> `EnumAudioEndpoints(eRender, ACTIVE)` -> `MMDevCol_GetCount` = 0 -> `FAUDIO_E_INVALID_CALL` -> no `audio->master` -> wine ignores it -> `CreateSubmixVoice` reads `[NULL+0xDC]`.
