---
name: b4x-wine-setup
description: Troubleshoot and configure B4X on Linux/Wine. Use when resolving WINEPREFIX issues, translating Windows paths, locating b4xV5.ini, fixing JavaBin or JavaFX problems, debugging missing AdditionalLibraries or SharedModules, or making B4J/B4A builds work headlessly under Wine.
---

# B4X Wine Setup

Use this skill for Linux/Wine-specific B4X issues.

## Canonical assumptions

Typical install layout:

```text
$WINEPREFIX/drive_c/Program Files/Anywhere Software/
  B4J/B4J.exe
  B4J/B4JBuilder.exe
  B4A/B4A.exe
  B4A/B4ABuilder.exe
```

Typical config files:

```text
$WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/B4J/b4xV5.ini
$WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/Basic4android/b4xV5.ini
```

## What to inspect

1. `WINEPREFIX`
2. `winepath` availability
3. B4X install dir under the prefix
4. `b4xV5.ini`
5. keys like:
   - `AdditionalLibrariesFolder`
   - `SharedModulesFolder`
   - `JavaBin`
   - platform folders / SDK paths

## Path rules

- `Z:\...` usually maps to `/...` on the host.
- `C:\...` maps through `dosdevices/c:` to `drive_c/...`.
- B4X builders need Windows paths, not Linux ones.
- Project modules may mix host-relative paths with Wine absolute paths.

## In this repo

Consult:

- `emacs/b4x-wine.el`
- `docs/wine.md`
- `emacs/b4x-project.el`

These contain the practical path translation and INI assumptions already used by the extension.

## Common failure modes

### Headless build cannot find libs

Usually one of:
- bad `AdditionalLibrariesFolder`
- missing library files in that folder
- project references a library name not matching on-disk XML/JAR/AAR/B4XLib names

### JavaFX build fails with `module not found: javafx.*`

Check `JavaBin` in `b4xV5.ini`.
It must point to a JDK that actually ships JavaFX for the B4X/Wine setup.

### INI edits do not stick

If `B4J.exe` or `B4A.exe` is open, it may overwrite `b4xV5.ini` on exit.
Close the IDE before manual edits, or change the paths from the IDE UI.

### Path translation bugs

Do not guess path conversion manually when existing helpers or `winepath -w` are available.

### B4A IDE build: `No se puede encontrar: C:\windows\System32\Robocopy.exe`

Wine ships `robocopy.exe` as a **builtin stub** (copies nothing, exit 16).
B4A/B4J invoke it by a **fixed path** to copy project `Files/` (layouts,
assets). A `.bat` shim does NOT work (B4A wants the literal `.exe`), and a
native `.exe` in `system32` is shadowed by the builtin unless the Wine
override is `robocopy.exe = native` (the `.exe` suffix is mandatory).

Use the `b4x-android-emulator` skill (`scripts/install-robocopy-fix.sh`) to
install a prebuilt native `robocopy.exe` + override. Headless builder builds
are unaffected (they use `aapt -A` directly).

## Safe workflow

1. Confirm the active prefix.
2. Confirm the B4X install exists inside it.
3. Read the relevant `b4xV5.ini`.
4. Resolve Windows↔host paths explicitly.
5. Re-run the failing build/run with the corrected environment.

## See also

- global skills: `b4x-build`, `b4x-run`
- `../b4x-project-model/SKILL.md`
