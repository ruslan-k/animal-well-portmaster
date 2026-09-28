#!/usr/bin/env python3
"""Apply an opt-in TSPS Mali GIPA guard to the Box64 Vulkan wrapper."""
from __future__ import annotations

import sys
from pathlib import Path

MARKER = "BOX64_VULKAN_GIPA_BLOCK"
NEEDLE = '    const char* rname = (const char*)name;\n'
GUARD = '''    const char* rname = (const char*)name;
    const char* skip_unsafe_gipa = getenv("BOX64_VULKAN_SKIP_UNSAFE_GIPA");
    if (skip_unsafe_gipa && strcmp(skip_unsafe_gipa, "1") == 0 && rname &&
        strcmp(rname, "vkEnumeratePhysicalDeviceQueueFamilyPerformanceCountersByRegionARM") == 0) {
        fprintf(stderr, "BOX64_VULKAN_GIPA_BLOCK name=%s\\n", rname);
        return NULL;
    }
'''


def patch(text: str) -> str:
    if MARKER in text:
        return text
    start = text.find("my_vkGetInstanceProcAddr")
    if start < 0:
        raise ValueError("vkGetInstanceProcAddr wrapper not found")
    position = text.find(NEEDLE, start)
    if position < 0:
        raise ValueError("GIPA insertion point not found in wrapper")
    next_function = text.find("EXPORT ", start + len("my_vkGetInstanceProcAddr"))
    if next_function >= 0 and position >= next_function:
        raise ValueError("GIPA insertion point escaped wrapper")
    return text[:position] + GUARD + text[position + len(NEEDLE):]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} /path/to/wrappedvulkan.c", file=sys.stderr)
        return 2
    path = Path(sys.argv[1])
    source = path.read_text()
    updated = patch(source)
    path.write_text(updated)
    if MARKER not in path.read_text():
        raise SystemExit("patch marker missing after write")
    print(f"patched {path}: {MARKER}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
