import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPT_DIR))
from patch_box64_vk_gipa import patch


class Box64GipaPatchTests(unittest.TestCase):
    def test_adds_opt_in_guard_before_native_lookup(self):
        source = """EXPORT void* my_vkGetInstanceProcAddr(x64emu_t* emu, void* instance, void* name)
{
    khint_t k;
    const char* rname = (const char*)name;

   pFpp_t getprocaddr = getBridgeFnc2((void*)R_RIP);
"""
        result = patch(source)
        self.assertIn('getenv("BOX64_VULKAN_SKIP_UNSAFE_GIPA")', result)
        self.assertIn('strcmp(rname, "vkEnumeratePhysicalDeviceQueueFamilyPerformanceCountersByRegionARM") == 0', result)
        self.assertIn('strcmp(rname, "vkEnumeratePhysicalDeviceShaderInstrumentationMetricsARM") == 0', result)
        self.assertIn('strcmp(rname, "vkGetPhysicalDeviceCalibrateableTimeDomainsKHR") == 0', result)
        self.assertLess(result.index("BOX64_VULKAN_GIPA_BLOCK"), result.index("getprocaddr ="))
        self.assertIn('return NULL;', result)

    def test_patch_is_idempotent(self):
        source = """EXPORT void* my_vkGetInstanceProcAddr(void)
{
    const char* rname = (const char*)name;
}
"""
        once = patch(source)
        self.assertEqual(patch(once), once)

    def test_patch_targets_wrapper_when_source_has_other_matches(self):
        source = """const char* unrelated = (const char*)name;
EXPORT void* my_vkGetInstanceProcAddr(void)
{
    const char* rname = (const char*)name;
}
"""
        result = patch(source)
        self.assertEqual(result.count("BOX64_VULKAN_GIPA_BLOCK"), 1)
        self.assertLess(result.index("const char* unrelated"), result.index("BOX64_VULKAN_GIPA_BLOCK"))
        self.assertLess(result.index("BOX64_VULKAN_GIPA_BLOCK"), result.index("}\n"))

    def test_rejects_unknown_source_layout(self):
        with self.assertRaises(ValueError):
            patch("void unrelated(void) {}\n")


if __name__ == "__main__":
    unittest.main()
