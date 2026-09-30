## Final fact of this round: with audio disabled the game does not crash - it exits with code 53

* Audio enabled (T1V, FAudio 241000): deterministic page fault `read 0xDC` at `0x7FFE32E9F6` -> `xaudio2_9.dll +0xd9f6`, thread 0024.
* Audio disabled via the port's `AW_NO_AUDIO=1`: `Unhandled` count 0, and the launcher records `game_exit_code=53`. The game neither crashes nor hangs - it quits.
* Freeing the audio device first (the PCM was held by `MainUI`, `/dev/snd/pcmC0D0p`) did not change anything: with audio enabled the fault is identical.

So audio is not optional for this title: with wine's XAudio2 present it faults inside FAudio voice creation, and with the module removed it exits instead of rendering. The fix therefore has to make FAudio work, not remove it.

Still unexecuted from the reviewer's plan: the smoke ladder S2-S6 and the feature-level sweep. They bound D3D12 above device creation, but the crash we actually have is in the audio path, and `PASS_DXGI_FACTORY` + `PASS_D3D12_DEVICE` already hold under the frozen T1V environment.
