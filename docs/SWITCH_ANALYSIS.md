# ANIMAL WELL Switch build feasibility

This note records metadata and interface observations from a user-supplied, legally
owned merged Switch build. No Nintendo or game binaries are stored in this repository.

## Supplied ANIMAL WELL Switch build

Archive SHA-256:

\`4bba651770e187abdfcf37b20a59c649ad79713a9197b992e9ea24230423bd8d\`

The merged package contains a compact ExeFS:

- \`rtld\`
- \`main\`
- \`sdk\`
- no \`subsdk0\` module

NSO metadata observed after locally decoding the NSO0 segments:

| module | raw SHA-256 | build id prefix | text | rodata | data | extra/BSS field |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| rtld | \`6c28d1cd179b6735cc8cc770daa9ceacde35ed086f9de189ad7dcc6f786d736a\` | \`b676db0a1a453423...\` | 9,536 | 2,604 | 4,104 | 4,088 |
| main | \`5b0721161df8fda62bbfa8492a695ee4be0c8eac02277e655883c9c2b648bcc6\` | \`6a6ec42ffb98642a...\` | 1,013,696 | 33,618,772 | 59,128 | 562,669,832 |
| sdk | \`d6cd37d349b2ff22f994ce77e032dd6cb59ea18504ba4c6474411df0c0ffe849\` | \`112ea664a8df6229...\` | 6,693,520 | 5,025,004 | 349,416 | 850,712 |

The large \`main\` extra/BSS field is a virtual-memory reservation signal, **not**
proof that the game has that much resident RAM at runtime. It is nevertheless a
critical item to measure on a 1 GiB handheld.

The main module contains an NVN loader surface and runtime GLSLC names including
\`nvnBootstrapLoader\`, \`glslcCompile\`, \`glslcCompilePreSpecialized\`,
\`glslcCompileSpecialized\`, \`glslcInitialize\` and \`glslcFinalize\`. Shader
names are dominated by a custom 2D renderer (Basic2D, background, fluid,
midground, water/reflection and related pixel shaders).

### Exact dynamic import contract

Following the NSO's MOD0 header into the ELF-style dynamic table is more useful
than a string scan. For the supplied \`main\` it yields **199 undefined dynamic
symbols**. Of those, **135 are Nintendo \`nn::*\` imports**:

| namespace | imports |
| --- | ---: |
| audio | 46 |
| hid | 26 |
| os | 12 |
| fs | 10 |
| mem | 8 |
| codec | 7 |
| vi | 7 |
| util | 5 |
| account | 3 |
| diag | 3 |
| time | 3 |
| oe | 2 |
| detail | 1 |
| pl | 1 |
| ro | 1 |

The graphics bootstrap is direct and explicit: \`nvnBootstrapLoader\` plus eight
\`glslc*\` imports are in the undefined dynamic symbol table. The remaining
imports are ordinary libc/libm/libc++/pthread and Nintendo graphics-allocation
helpers.

This makes the work split clearer:

- \`audio\` / Opus -> host audio bridge, with NextOS nxaudio as a useful base;
- \`hid\` -> nxinput / SDL2;
- \`vi\` -> nxgl / SDL window and native drawable;
- \`fs\`, \`os\`, \`mem\`, \`account\`, \`time\` -> narrow host shims;
- \`nvnBootstrapLoader\` -> ANIMAL WELL-specific NVN resolver;
- \`glslc*\` -> shader translation/preprocessing path and currently the largest
  renderer-specific unknown.

\`scripts/analyze_switch.py\` now derives this contract directly from MOD0 and
dynsym when they are present.

## Bloodstained reference port

The supplied Bloodstained: Curse of the Moon package is not a Wine port. Its own
README describes a game-specific native AArch64 loader plus NVN-to-GLES2
translation, PCM audio and system SDL2 controller input.

Its \`cotm-switch-nextos\` runtime is:

- ELF64 AArch64 PIE, interpreter \`/lib/ld-linux-aarch64.so.1\`
- linked to system SDL2, libm, zlib, libdl, pthread and libc
- maximum observed numeric glibc requirement: **GLIBC_2.27**
- exports hundreds of game-specific \`cotm_nvn*\` wrappers
- consumes extracted NSO segment files rather than emulating a whole Switch

This is exactly the class of approach worth testing for ANIMAL WELL because it
removes Box64, Wine and D3D12-to-Vulkan from the hot path.

The supplied package pins generic NextOS components such as nxloader 0.9.0 and
nxgl 0.3.9. Those generic components are available in the public
\`NextOs-Ports/nextos-framework\` repository. The CotM-specific NVN shim/patch
source, however, is referenced as a separate source companion archive and is
not embedded in the supplied runtime package.

A key boundary: generic nxloader 0.9.0 is an Android \`ET_DYN\` ELF loader. It
does **not** consume NSO0 directly. ANIMAL WELL therefore still needs its own
small Switch NSO image/mapping/relocation layer, like the CotM port has above
the generic framework.

## Static NVN surface comparison

A conservative name-based comparison found:

- ANIMAL WELL \`main\`: **536** unique strings matching \`nvn*\`
- Bloodstained shim: **480** exported \`cotm_nvn*\` wrappers
- common names: **475**
- names visible in ANIMAL WELL but absent from that shim: **61**
- static name-surface overlap: **88.62%**

This figure must **not** be read as "88.62% of the port is complete". Nintendo's
generated NVN loader can contain names that the game never calls. The useful
next measurement is the active call set, obtained with relocation/xref analysis
and then with runtime tracing.

Notable names absent from the Bloodstained wrapper surface include deferred
binding variants, queue/window active-texture controls, checkpoint/debug
functions, some raw-storage/subtile helpers, GL interop sync functions and
\`nvnBootstrapLoader\`.

## Feasibility conclusion

The Bloodstained architecture is a credible route for ANIMAL WELL, but its
binary shim is not a drop-in compatibility layer. It contains game-specific
module/layout assumptions, shader extraction, patches and wrapper names.

ANIMAL WELL is structurally encouraging:

1. only \`rtld + main + sdk\` are present;
2. the renderer is small and strongly 2D-oriented;
3. most of the statically visible NVN name surface already has an analogue in
   the Bloodstained shim;
4. the exact dynamic import contract is modest enough to enumerate and test;
5. a native Switch path avoids the Windows x86-64 -> Box64 -> Wine -> D3D12 ->
   Vulkan translation stack.

The hard parts are expected to be:

- implementing only the *actually used* missing NVN calls;
- translating/handling its GLSLC/NVN shader path;
- satisfying the 135 imported Nintendo SDK symbols through explicit bridges;
- reproducing the guest address-space layout safely within TSPS memory limits;
- validating GLES2/GLES3 feature and precision assumptions on the Mali-G57
  system stack.

Therefore the Switch path should be developed in parallel with the Windows
runtime. It has a higher initial reverse-engineering cost, but a substantially
better final architecture for a 1 GiB ARM64 handheld if the active API surface
stays small.

## Reproduce the static analysis

After legally extracting ExeFS:

\`\`\`sh
python3 scripts/analyze_switch.py /path/to/exefs --output animalwell-switch.json
\`\`\`

To compare against a Bloodstained-style shim available locally:

\`\`\`sh
python3 scripts/analyze_switch.py /path/to/exefs \
  --compare-shim /path/to/cotm-switch-nextos
\`\`\`

The generated JSON contains metadata, the MOD0/dynsym import contract and API
names only; do not commit proprietary NSO segments.
