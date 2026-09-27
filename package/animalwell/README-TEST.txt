ANIMAL WELL - TSPS / SpruceOS physical test package
====================================================

Install:
  Extract/copy both top-level launchers and the animalwell/ directory into:
    /mnt/SDCARD/Roms/ports/

Expected layout:
  Roms/ports/Animal Well.sh
  Roms/ports/Animal Well Diagnose.sh
  Roms/ports/animalwell/game/Animal Well.exe
  Roms/ports/animalwell/prefix.ext2
  Roms/ports/animalwell/runtime/...

Disk space:
  Keep at least about 2 GiB free after extraction; prefix.ext2 is a 1 GiB persistent Wine filesystem image.

Normal launch:
  Run "Animal Well" from Ports/PortMaster.

The default backend is "wine" (Wine's built-in VKD3D), because it has the
lowest Vulkan requirements and is the safest first test for the Mali-G57 stack.
To test another backend, edit animalwell/backend and set exactly one of:
  wine
  vkd3d-2.6
  vkd3d-3.0.1

Logs:
  animalwell/log.txt          current launch
  animalwell/log.prev.txt     previous launch
  animalwell/logs/diagnostics-YYYYMMDD-HHMMSS.tar.gz

If the game exits with an error, the normal launcher automatically gathers a
diagnostic bundle. If it hangs, stays black, or must be killed/rebooted, launch
"Animal Well Diagnose" afterwards; it runs Vulkan + D3D12 smoke tests and
creates the diagnostics archive without requiring the game to stay running.

Important implementation detail:
  spruceOS uses a FAT32 SD card, while Wine prefixes require Unix symlinks.
  Therefore prefix.ext2 is loop-mounted at /tmp/animalwell-wineprefix while the
  game runs. Do NOT unpack or delete that image. It is persistent game state.

Game files in this private test bundle came from the user-supplied Windows
archive. They are not stored in the public GitHub repository.
