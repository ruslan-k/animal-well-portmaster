## WINEDEBUG=+module works but also perturbs the run; partial base resolution

Third heavy debug channel in a row, and the same pattern: `WINEDEBUG=+module` does take effect (11384 `module:` lines) but the game then dies **without** the `strlen` crash, exactly as happened with `BOX64_SHOWBT/SHOWSEGV`. So on this device every heavy logging channel changes the behaviour being observed, and none of them is usable for the live run.

What the `+module` log did give:

* The module lines do carry guest addresses, e.g. a contiguous run `0x7ffde80000, 0x7ffde81000, 0x7ffde94000, ... 0x7ffded3000`, i.e. one module's sections.
* Module names appear as well (`winevulkan.dll`, `kernelbase.dll`, `vulkan-1.dll`, ...), but the log interleaves host and guest addresses, so name-to-base pairing cannot be extracted reliably from it.

What can be stated with evidence:

* ntdll's guest base is derivable from the crash line itself: `x64pc=0x7ffff94200` with `ntdll.dll + 0x64200` gives base `0x7ffff30000`.
* The return address on the stack at fault time is `0x7fffc4a946`, which is about 3 MB **below** ntdll's base. In wine's 64-bit guest layout the DLLs are placed downward from the high region, so the caller sits in a wine DLL loaded immediately below ntdll - the kernel32/kernelbase class. That is a hypothesis, not a verified name; the pairing still needs a cleaner source.

Cleaner routes for the pairing, for the next attempt: `winedbg --command "info share"` with an explicit output redirect (the previous winedbg attempt lost its output), or a wine layout table for this exact build.
