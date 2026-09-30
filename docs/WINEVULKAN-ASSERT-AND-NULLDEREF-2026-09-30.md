# Winevulkan assert crash fixed; the next blocker is a null dereference

Measured on the device (menu launch, 16:23 diagnostics tarball):

    Assertion failed: !status, file /home/runner/build_wine/wine/dlls/winevulkan/loader.c, line 668

`winevulkan.dll` imports `_assert` from `ucrtbase.dll` (IAT slot RVA 0x2e39c) and
contains **366** `_assert` call sites - wine generates an assert-wrapped wrapper
for every Vulkan entry point.  The site for line 668 (the one that fired) is
unambiguous:

    41 b8 9c 02 00 00     mov r8d, 0x29c          ; line = 668
    48 8d 15 ...          lea rdx, [file string]
    48 8d 0d ...          lea rcx, [expr string]
    ff 15 33 8f 02 00     call qword ptr [rip+0x28f33]   ; -> _assert

The code immediately after that assert *handles* the failure (frees the command
buffers and returns the result), so a debug build turns a recoverable Vulkan error
into a fatal abort.  The wine here is the pinned Kron4ek 10.0 archive
(`/home/runner/build_wine/...` is their build environment), i.e. asserts are
compiled in.

`scripts/patch-wine-asserts.py` neutralises every `_assert` call site in
`winevulkan.dll` (six NOPs per `ff 15` whose target is that IAT slot).  Applied on
device with the original kept as `winevulkan.dll.orig-<time>`.

Result: the assertion count in the launcher log went from 1 to **0** and the game
process survives the Vulkan call.  But the run then hits the *next* blocker, which
is loader-independent:

    wine: Unhandled page fault on read access to 00000000000000DC at address 0000007FFE32E9F6
    x64opcode = 8B 80 DC 00 00 00   ->  mov eax, [rax+0xDC]   with RAX = 0

The same fault reproduces with the port's bundled loader 1.2.131 (X11 WSI present)
and with the firmware 1.3.296 (no X11 WSI), so it is not the loader: a null object
is dereferenced at +0xDC during startup.  Evidence: with the firmware loader the
wrapper log additionally shows the WSI path timing out
(`AcquireNextImage: wait_for_free_buffer failed with result 1`), which is the
presentation symptom, not this crash.

Next: obtain a real backtrace for the fault (run winedbg with a captured console,
or a core/`bt all`), locate the module behind guest address 0x60030b33, then fix or
work around that dereference.  The assert patch belongs in the CI (apply the script
after the wine archive is unpacked) so devices get a wine without the fatal guard.
