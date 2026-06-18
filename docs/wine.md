# Wine notes

Practical notes on running B4X under Wine on Linux. This is the operating
assumption baked into the core.

## Canonical layout

The skills and installer assume a single Wine prefix holding the B4X install:

```
$WINEPREFIX/drive_c/Program Files/Anywhere Software/
  B4J/B4JBuilder.exe
  B4J/B4J.exe
  B4A/B4ABuilder.exe
```

On this machine:

- Prefix: `~/.wine_b4x` (the `b4x-build` / `b4x-run` skills default).
- `WINEPREFIX` env is often **unset**; the core must fall back to a configured
  prefix, then `~/.wine`, then `~/.wine_b4x`.

## b4xV5.ini discovery

B4X stores per-platform config under the Wine user profile:

```
$WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/<Platform>/b4xV5.ini
```

Known platform subfolders: `B4J`, `B4A` / `Basic4android`, `B4i`, `B4R`.

Example keys we care about:

```
AdditionalLibrariesFolder=Z:\home\devgiu\dev\B4XAdditionalLibs
SharedModulesFolder=
JavaBin=C:\Java\jdk-11.0.31+11\bin
```

## Path translation

### Windows path → host (Linux)

`C:\...` and `D:\...` map through the prefix's `dosdevices/<letter>:` symlinks:

```
$WINEPREFIX/dosdevices/c: -> ../drive_c
$WINEPREFIX/dosdevices/z: -> /   (the host root, Wine's default Z: drive)
```

So `Z:\home\devgiu\dev\B4XAdditionalLibs` → `/home/devgiu/dev/B4XAdditionalLibs`.

The core implements this deterministically (no `wine` subprocess needed) using
`dosdevices` symlinks, with fallbacks to `drive_c` for `C:` and the host root
for `Z:`.

### Host (Linux) → Windows path

Uses `winepath -w` (with `WINEPREFIX` set) for correctness, with a
deterministic fallback that maps `drive_c` → `C:\` and everything else →
`Z:\...`.

## Project module resolution

A `.b4j` lives in a platform folder, e.g. `Project/B4J/Project.b4j`. Module
entries are relative to that platform folder:

```
Module1=|relative|..\B4XMainPage      -> ../B4XMainPage(.bas)
Module2=|relative|..\Test             -> ../Test(.bas)
```

Module path kinds (prefix in `|...|`):

- `|relative|` — relative to the project file's directory.
- `|absolute|` — absolute path (possibly a Wine path); translate + normalize.
- `|shared|` — relative to the configured Shared Modules folder.
- plain (no prefix) — treated like relative.

Resolution tries the path as-is, then appends `.bas`. Shared modules fall back
to the `SharedModulesFolder` from the platform INI.

## Embedded "Main" code

The `.b4j`/`.b4a` file contains the Main module source *after* the
`@EndOfDesignText@` marker. The indexer does not read `.b4j` directly, so the
core extracts that post-marker code to a generated `.b4x` file (under a cache
dir) so the LSP can index `Process_Globals`, etc.

## Build under Wine

```
WINEPREFIX=<prefix> wine "<install>/B4J/B4JBuilder.exe" \
  -Task=Build -BaseFolder=<windows project dir> -Project=<windows .b4j path>
```

- Paths passed to the builder must be **Windows paths** (`winepath -w`).
- `B4JBuilder` / `B4ABuilder` perform the real build work internally: they
  read the project file, generate any intermediate sources they need, and
  invoke the configured Java toolchain themselves (for B4J, based on
  `JavaBin=` in `b4xV5.ini`). Emacs does not compile Java sources directly.
- Wine's exit code is unreliable; success is detected from the
  `Completed successfully` textual marker in output.
- Output jar: `<project>/Objects/<ProjectName>.jar`.

## Run

- `AppType=StandardJava` → native `java -jar` (no Wine).
- `AppType=JavaFX` → `wine java.exe --module-path <javafx/lib> --add-modules ... -jar ...`
  (the shipped JavaFX has Windows-only DLLs).

See the vendored `core/scripts/b4x-build.sh` and `core/scripts/b4x-run.sh` for
the full, battle-tested logic.
