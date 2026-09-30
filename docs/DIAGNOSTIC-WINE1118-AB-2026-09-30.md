## Small delta: the parked wine 11.18 tree is not a usable A/B for the audio question

I swapped the runtime to the parked `wine-11.18-keep` tree (its `xaudio2_9.dll` is 318860 bytes, FAudio 260901) and ran the port in T1V.

Result: no crash (`Unhandled` count 0, no `Assertion failed`), but the game does not start either - the process sits at 1-3 threads with ~17 MB RSS and the X server shows its empty root, and no XAudio2 line ever appears in the log.

Interpretation: the 10.0 tree is pinned for a reason - the port's `win32u` geometry patch is applied to 10.0, so 11.18 fails earlier for an unrelated reason and never reaches audio initialisation. So this swap does not isolate the FAudio question; a clean test would need the port's patch applied to the newer tree.

Runtime restored to the 10.0 tree (`xaudio2_9.dll` sha prefix `f000337eb1b1`) and the device left clean.
