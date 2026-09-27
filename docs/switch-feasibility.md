# Switch-native feasibility

## Input examined

The supplied merged Switch extraction is base v0 + update v655360.

Final ExeFS hashes from the supplied manifest:

- `main`: 31,967,027 bytes, SHA-256 `5b0721161df8fda62bbfa8492a695ee4be0c8eac02277e655883c9c2b648bcc6`
- `sdk`: 6,201,287 bytes, SHA-256 `d6cd37d349b2ff22f994ce77e032dd6cb59ea18504ba4c6474411df0c0ffe849`
- `rtld`: 10,113 bytes, SHA-256 `6c28d1cd179b6735cc8cc770daa9ceacde35ed086f9de189ad7dcc6f786d736a`

The executable is an ARM64 Nintendo Switch NSO. Static strings show:

- `SDK_gfx-20_5_7-Release`
- `nvnBootstrapLoader`
- many NVN entry points such as window, program, sampler-pool, sync and command-buffer operations
- Nintendo SDK services for HID, filesystem, account, time, audio and NIFM.

## Bloodstained comparison

The supplied Bloodstained archive identifies a NextOS-native Switch port layout:

- `cotm-switch-nextos`
- `nxextract/` plus Switch extraction helpers
- an adapter contract
- a generated runtime generation under `.nxruntime/`
- a game-specific runtime/config layer.

This is a native/shim route, not the Wine route.

## Conclusion

ANIMAL WELL is a plausible candidate for the same *class* of approach because its Switch program is already ARM64. It is **not a drop-in reuse** of the Bloodstained runtime.

The main blocker is graphics. ANIMAL WELL clearly uses Nintendo NVN directly and therefore needs enough of the NVN ABI translated or shimmed to the TSPS graphics stack. The port also needs implementations/adapters for the Nintendo SDK services actually reached at runtime.

Recommended order:

1. Finish the Windows Box64/Wine/VKD3D prototype first; it provides a faster path to first frame and gives a performance baseline.
2. Treat Switch-native as a separate backend.
3. Obtain/build the reusable NextOS Switch shim source corresponding to the Bloodstained runtime.
4. Instrument unresolved imports/service calls and implement only the subset ANIMAL WELL reaches.
5. Prioritize NVN bootstrap/device/queue/window/program/texture/sampler/memory/sync/command-buffer calls.
6. Map input, filesystem/save data, audio and account stubs after graphics initialization reaches a first frame.

The Switch path can ultimately be more efficient than Wine because it avoids x86-64 translation, but its up-front compatibility work is substantially larger.
