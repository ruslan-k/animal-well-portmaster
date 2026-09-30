## Follow-up: the XAudio2 crash is robust and reproducible, and the disable override did not take effect

Delta to the diagnostic report above.

### The fault is deterministic and localised

Three independent runs, each resolving the fault instruction the same way:

| run | environment | fault |
|---|---|---|
| patched winevulkan (366 asserts NOPed) | T1V | `0x7FFE32E9F6` -> `xaudio2_9.dll +0xd9f6` |
| original winevulkan (`cf8260f13144062c`) | T1V | same address, same module, same offset |
| original winevulkan + `xaudio2_9=d` | T1V | **same address, same module, same offset** |

Always `mov eax,[rax+0xDC]` with `RAX=0`, read of `0xDC`, thread `0024`. So the faulting site is stable across the winevulkan question and across the disable attempt - it is a specific bug in wine's XAudio2/FAudio, not an environment accident.

### XAudio2 trace: it dies at voice creation, after the mastering voice

```
0024:trace:xaudio2:DllMain Using FAudio version 241000
0024:trace:xaudio2:XAudio2Create 00000001420CFA58 0x0 0x1
0024:trace:xaudio2:XAudio2CF_CreateInstance Created XAudio version 29: 000000000079F610
0024:warn:xaudio2:xaudio2_initialize Processor affinity not implemented in FAudio
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice (000000000079F610)->(00000001420CFA60, 2, 0, 0x0, 0)
0024:trace:xaudio2:IXAudio2Impl_CreateMasteringVoice device id (null), category 0x6
0024:trace:xaudio2:IXAudio2Impl_CreateSubmixVoice (000000000079F610)->(00000001420CFA68, 2, 48000, 0x0, 0, 0, 0)
```
then the page fault.

So: `XAudio2Create` succeeds, the mastering voice call returns, and the fault follows the **submix voice** call - i.e. inside the linked FAudio code (the module reports `Using FAudio version 241000`; FAudio is statically linked into `xaudio2_9.dll`, which is wine's `dlls/xaudio2_7`).

### The disable attempt did not apply

`WINEDLLOVERRIDES=...;xaudio2_9=d` was exported for the run, yet the module still loaded (the fault is inside it). Open question worth knowing for future runs: the port writes DllOverrides into the prefix registry as well, and the launcher has its own `base_overrides` path, so the effective override may come from the registry rather than the environment. Not yet investigated.

### Consequences for the plan

* The graphics branch stays exonerated (`PASS_DXGI_FACTORY`, `PASS_D3D12_DEVICE` under the live-X T1V environment).
* The next useful graphics step is the smoke ladder (S2 queue, S3 commands, S4 resources, S5 swapchain, S6 present) only to bound D3D12 above device creation - but the crash we actually have is in audio.
* For the audio branch: verify which override path actually wins (registry vs environment), and test a different FAudio build (e.g. the parked wine 11.18 tree's `xaudio2_9.dll`, or an external FAudio) since the linked version here is 241000.
