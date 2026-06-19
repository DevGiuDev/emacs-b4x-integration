# emacs-b4x-integration (WIP)

> **WIP / current status**
>
> This extension is under active development. At the moment it is already
> usable for **B4J** and **B4A** work from Emacs on Linux:
>
> - opening and detecting B4X projects
> - navigating across modules and layouts
> - building under Wine
> - opening the official IDE (`B4J.exe` / `B4A.exe`)
> - Android-side helpers for B4A (`adb`, emulator, APK install, logcat)
>
> However, some areas are still evolving and may change:
>
> - the B4A debugging flow
> - multi-device / multi-emulator integration
> - Designer / complex layout polish
> - general UX and automation commands
>
B4X (B4J / B4A) development for **Emacs on Linux**, with first-class
[Wine](https://www.winehq.org/) support — implemented as a **pure Emacs Lisp**
package. No Node, no LSP server, no extra runtime: just Emacs ≥ 28.

It uses Emacs' native intelligence stack instead of an external language server:

| Capability | Native Emacs facility |
| --- | --- |
| Project model | `project.el` |
| Goto-definition / references | `xref` backend |
| Completion | `completion-at-point` (capf) |
| Diagnostics | `flymake` |
| Outline / structure | `imenu` + `outline` |
| Signature help | `eldoc` |
| Build / run | `compile.el` |
| Open in B4X IDE | detached Wine process |

Build and run under Wine delegate to two **vendored, battle-tested shell
scripts** shipped inside the package (`emacs/scripts/`).

## Status

Phases 0–6 complete (pure-Elisp package, Linux/Wine first). See
[`docs/roadmap.md`](docs/roadmap.md): Wine path translation, project model,
major mode with native xref/capf/imenu/eldoc, flymake diagnostics, build/run
under Wine, open-in-IDE, plus ergonomics (layout jump, module switcher,
dispatch menu).

MVP target achieved: open a B4J project, get navigation/completion/diagnostics,
build, run, and hop into the official IDE — all from Emacs on a Linux box where
B4X lives inside a Wine prefix. Phase 7 now includes practical **B4A** support:
B4A project detection, module creation, build under Wine, APK install / launch,
native Linux `adb` / emulator helpers, device selection, uninstall / restart,
filtered logcat, and a hybrid flow that opens `B4A.exe` for the official
debugger. Phase 8 now also includes native layout converter / sync support for
`.bjl` / `.bal` / `.bil` ↔ `JsonLayouts/*.json`, with conflict-aware project
sync and no SQLite dependency. Remaining: designer later (Phase 9).

---

## Requirements

- **Emacs ≥ 28.1** (built-in `project.el`, modern `xref`, `flymake`, `transient`).
- **Wine + `winepath`** on `$PATH` (for Windows ↔ host path translation and to
  run the B4X builders/IDE).
- **Java** on `$PATH` (to run the jars produced by B4J; a JDK 11 is the common
  target — see [docs/wine.md](docs/wine.md)).
- A **B4X install inside a Wine prefix**, in the standard layout:

  ```
  $WINEPREFIX/drive_c/Program Files/Anywhere Software/
    B4J/{B4J.exe, B4JBuilder.exe}
    B4A/{B4A.exe, B4ABuilder.exe}
  ```

  and the per-platform config under:

  ```
  $WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/B4J/b4xV5.ini
  $WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/Basic4android/b4xV5.ini
  ```

- For **B4A**, you should open `B4A.exe` under Wine at least once and configure
  the Android / Java paths from **Tools → Configure Paths**. Headless B4A builds
  reuse those saved paths from `b4xV5.ini`.

## Installation

Clone the repo, then load the package directory from your Emacs init.

### Option A — plain `load-path` (simplest)

```elisp
;; in your init.el / early-init.el
(add-to-list 'load-path "~/dev/emacs-b4x-integration/emacs")
(require 'b4x)
```

### Option B — `use-package`

```elisp
(use-package b4x
  :load-path "~/dev/emacs-b4x-integration/emacs"
  :custom
  (b4x-enable-flymake t)
  ;; (b4x-wine-prefix "~/.wine_b4x")   ; only if not the default / not in WINEPREFIX
  ;; (b4x-build-port 8080)             ; for jServer apps that read PORT
  ;; (b4x-java-opts '("-Xmx512m"))
  )
```

### Option C — `straight.el` / `elpaca` (from the Git remote)

```elisp
;; straight
(straight-use-package
 '(b4x :type git :host github :repo "DevGiuDev/emacs-b4x-integration"
       :files ("emacs/*.el" "emacs/scripts/*")))
```

> The package lives in the `emacs/` subdirectory. If you install it with a
> package manager, make sure that directory (and the `scripts/` inside it) are
> part of the installed files — the build/run commands find the scripts relative
> to `b4x.el` via `locate-library`.

On load, the package auto-registers:

- `auto-mode-alist` → `.b4j`, `.b4a`, `.b4i`, `.b4r`, `.bas` open in `b4x-mode`.
- `project-find-functions` → `project.el` recognizes B4X project roots.

## Configuration

All options live under the `b4x` customization group (`M-x customize-group RET
b4x RET`). The ones you are most likely to touch:

| Option | Default | Meaning |
| --- | --- | --- |
| `b4x-wine-enabled` | `auto` | `auto` enables Wine on non-Windows when a prefix resolves. Set `nil` to force native, `t` to force Wine. |
| `b4x-wine-prefix` | `nil` | Wine prefix holding the B4X install. `nil` → `$WINEPREFIX` → `~/.wine_b4x`. |
| `b4x-wine-binary` | `wine` | Wine executable used for build/IDE. |
| `b4x-winepath-binary` | `winepath` | `winepath` executable for host→Windows path translation. |
| `b4x-enable-flymake` | `t` | Turn on `flymake-mode` in `b4x-mode` buffers. |
| `b4x-build-port` | `nil` | Port forwarded as `PORT`/`JVM_SERVER_PORT` when running jServer apps. |
| `b4x-java-opts` | `nil` | Extra JVM options when running a B4J jar. |
| `b4x-run-after-build` | `nil` | If `t`, run the jar after a successful build. |
| `b4x-ide-log-file` | `nil` | Where `b4x-open-in-ide` appends Wine output. `nil` → `b4x-ide.log` in `temporary-file-directory`. |
| `b4x-adb-binary` | `adb` | ADB executable used by the B4A Android helpers. |
| `b4x-adb-serial` | `nil` | Optional `adb -s SERIAL` selector for a specific device/emulator. |
| `b4x-b4a-logcat-buffer-name` | `*b4x-logcat*` | Buffer used by `b4x-b4a-logcat`. |
| `b4x-b4a-logcat-fallback-specs` | `("B4A:V" "B4X:V" "AndroidRuntime:E" "System.err:W" "*:S")` | Quieter tag-based logcat filter used before the app PID is available. |
| `b4x-emulator-binary` | `emulator` | Native Linux Android emulator executable. |
| `b4x-b4a-default-avd` | `nil` | Preferred AVD name for emulator/hybrid-debug commands. |
| `b4x-b4a-emulator-args` | `nil` | Extra args passed to `emulator -avd ...`. |
| `b4x-b4a-emulator-log-file` | `nil` | Detached emulator log file. |
| `b4x-b4a-device-buffer-name` | `*b4x-android*` | Buffer used by device wait / hybrid debug helpers. |

### Per-project settings (`.dir-locals.el`)

```elisp
((b4x-mode . ((b4x-build-port . 8090)
              (b4x-java-opts . ("-Xmx1g")))))
```

### First-time sanity check

After loading, run these in `*scratch*` / `M-:`:

```elisp
(b4x-wine-resolve-prefix)             ; => "/home/you/.wine_b4x"
(b4x-wine-active-p)                   ; => t
(b4x-find-wine-ini 'b4j)             ; => ".../Anywhere Software/B4J/b4xV5.ini"
(b4x-find-wine-ini 'b4a)             ; => ".../Anywhere Software/Basic4android/b4xV5.ini"
(b4x--ide-exe-path 'b4j)             ; => ".../B4J/B4J.exe"
(b4x--ide-exe-path 'b4a)             ; => ".../B4A/B4A.exe"
```

If `b4x-wine-active-p` is `nil` while you're on Linux, set `b4x-wine-enabled`
to `t` explicitly.

For **B4A specifically**, do one first interactive run of `B4A.exe` and set the
Android SDK / platform / build-tools / Java paths in **Tools → Configure Paths**.
After that, Emacs / the headless builder reuse the saved B4A configuration.

## Quick start

```elisp
C-x C-f  ~/dev/MyProject/B4J/MyProject.b4j   ; opens in b4x-mode
C-c C-d                                         ; dispatch menu (everything)
```

Typical first session:

1. `C-c C-o` (or `M-x b4x-open-project`) to load a project.
2. `C-c C-i` to verify the parsed model (modules, libraries, INI).
3. Edit `.bas` files; `M-.` / `M-?` to navigate; `M-TAB` to complete; flymake
   shows duplicate-symbol/type-placement warnings.
4. Use completion: project symbols + keywords + library XML metadata + indexed `.b4xlib` symbols from referenced core / Additional Libs.
5. `C-c C-c` to build under Wine; output lands in a `compilation-mode` buffer.
6. `M-x b4x-list-available-libraries` to inspect core / Additional Libs.
7. In that buffer, use `RET` / click to toggle a library, `a` to add, `r`/`k` to remove.
8. `C-c C-r` to run the jar.
9. `C-c C-e` to pop open the official B4X IDE under Wine (detached).

## Cheatsheet — commands & key bindings

All bindings are in `b4x-mode` (active for `.bas`/`.b4j`/`.b4a`/`.b4i`/`.b4r`).

### Dispatch

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-d` | `b4x-dispatch` | Transient menu grouping all the commands below. |

### Project

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-o` | `b4x-open-project` | Load a project (auto-detected or prompted). |
| `C-c C-i` | `b4x-project-info` | Show modules, libraries, INI, root, and indexed POM count in a buffer. |
| `C-c C-v` | `b4x-version` | Show the loaded package version and the exact file path Emacs is executing. |
| `C-c C-n` | `b4x-new-module` | Create/register a new module in the current B4J/B4A project (`Static Code`, `Class`, `B4XPage`; plus `Service` on B4A). |
| `M-x b4x-list-available-libraries` / `C-c C-d S` | `b4x-list-available-libraries` | List all libraries visible from the core and Additional Libs folders, including source, kind, and path. The list buffer is clickable and supports `RET`, `a`, `r`/`k`, and `g`. |
| `C-c C-s` | `b4x-add-library` | Add a library from the core or Additional Libs folders to the current project. |
| `C-c C-k` | `b4x-remove-library` | Remove a library from the current project. |
| `C-c C-m` | `b4x-switch-module` | Jump to another module (completing-read). |

### Navigation & intelligence (native Emacs)

| Key | Command | Description |
| --- | --- | --- |
| `M-.` | `xref-find-definitions` | Go to Sub/Type/global definition (B4X xref backend). |
| `M-?` | `xref-find-references` | Find references across project modules. |
| `M-TAB` / `C-M-i` | `completion-at-point` | Complete project symbols + keywords + XML metadata + indexed `.b4xlib` symbols from referenced libraries. Library candidates expose annotations/doc when the frontend supports them. |
| `M-x imenu` | `b4x-imenu-index` | Browse Subs / Types / Globals of the buffer. |
| — (eldoc) | `b4x-eldoc-function` | Sub signature in the echo area, with fallback to library XML / `.b4xlib` signatures/docs. |
| — (flymake) | `b4x-flymake` | Duplicate-symbol + type-placement warnings. |

### Layouts

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-l` | `b4x-goto-layout` | Jump to the layout at point (`LoadLayout("X")`) or pick one. |
| `C-c C-y` | `b4x-layout-sync-project` | Sync all project layouts between `Files/` and `JsonLayouts/`, with conflict detection. |
| `M-x b4x-layout-open-json` | `b4x-layout-open-json` | Open the `JsonLayouts/<name>.json` sidecar for a layout, exporting it first if needed. |
| `M-x b4x-layout-export` | `b4x-layout-export` | Export a binary layout to pretty JSON. |
| `M-x b4x-layout-import` | `b4x-layout-import` | Import a JSON sidecar back to `.bjl` / `.bal` / `.bil`. |
| `M-x b4x-layout-sync-project` | `b4x-layout-sync-project` | Sync all project layouts between `Files/` and `JsonLayouts/`, with conflict detection. |

### Build, run & IDE

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-c` | `b4x-build` | Build with `wine B4JBuilder.exe`/`B4ABuilder.exe` (the builder itself handles code generation + Java compilation internally). |
| `C-c C-r` | `b4x-run-project` | Run the jar (`java -jar`, or `wine java` for JavaFX) for B4J projects. |
| `C-c C-e` | `b4x-open-in-ide` | Open the project in the official B4X IDE under Wine (fully detached via `setsid`/`nohup`; Wine output → `b4x-ide-log-file`). |
| `C-c C-d L` | `b4x-ide-log` | Show the Wine log if the IDE ever fails to open. |
| `C-c a s` | `b4x-b4a-select-device` | Select the Android device used by later B4A helper commands in this Emacs session. |
| `C-c a v` | `b4x-b4a-list-avds` | List available Android virtual devices (AVDs). |
| `C-c a e` | `b4x-b4a-start-emulator` | Start a native Linux Android emulator (`emulator -avd ...`). |
| `C-c a w` | `b4x-b4a-wait-for-device` | Wait until ADB sees a fully booted device/emulator. Auto-selects a target when several devices are visible. |
| `C-c a d` | `b4x-b4a-debug-in-ide` | Hybrid flow: optional emulator start, wait for device, then open B4A IDE for official debugging. |
| `C-c a i` | `b4x-b4a-install-apk` | Install the built B4A APK with `adb install -r`. Auto-selects / prompts for the target device when needed. |
| `C-c a u` | `b4x-b4a-uninstall-app` | Uninstall the current B4A app from the selected device. |
| `C-c a l` | `b4x-b4a-launch-app` | Launch the B4A app on device/emulator via `adb shell monkey`. |
| `C-c a r` | `b4x-b4a-restart-app` | Force-stop and relaunch the B4A app on the selected device. |
| `C-c a g` | `b4x-b4a-logcat` | Stream Android logcat into Emacs (`C-u` first clears it). Uses PID filtering when possible, otherwise a quieter tag filter. |
| `C-c a k` | `b4x-b4a-stop-logcat` | Stop the running logcat stream. |

### `project.el`

Opening any file under a B4X project root registers it with `project.el`; use
`C-x p p` (`project-switch-project`) or `C-x p f` (`project-find-file`) to move
across modules.

### B4A device flow

Before the first headless B4A build on a machine / Wine prefix, open `B4A.exe`
once and configure the SDK / JDK paths from **Tools → Configure Paths**. After
that, the saved B4A config is reused by `B4ABuilder.exe`.

Typical Android loop after opening a `.b4a` project:

1. `C-c C-c` → build the APK under Wine.
2. Optional: `C-c a s` → pin the current Android device for this Emacs session.
3. `C-c a i` → install/update it on the selected device (`adb install -r`).
4. `C-c a r` → restart it quickly (`am force-stop` + launch), or `C-c a l` to launch only.
5. `C-c a g` → inspect runtime logs in Emacs.
6. `C-c a u` → uninstall it when needed.

If `b4x-adb-serial` is nil, the helper commands automatically reuse the last
selected device, auto-pick the sole connected device, or prompt when several
ready devices are connected.

### Hybrid B4A debugging flow

If you want the **official B4A debugger** instead of a pure adb loop:

1. `C-u C-c a d` → choose/start an AVD natively on Linux.
2. Emacs waits for `adb wait-for-device` + `sys.boot_completed=1`.
3. Emacs opens the current project in `B4A.exe` under Wine.
4. Use **Run / Debug** inside the B4A IDE.

This keeps emulator / adb native on Linux while leaving the real B4A debugger
under control of the official IDE.

> **How the bridge works.** B4A never manages emulators; it talks to Android
> over ADB. The Windows `adb.exe` used by B4A under Wine and the native Linux
> `adb` **share the same ADB server** (port 5037), so any device the native
> adb sees is visible to B4A's `adb.exe` too. No AVD registration inside Wine
> is needed.

### B4A on the official IDE: the `robocopy` stub

Compiling from the **B4A IDE** under Wine can fail with
`No se puede encontrar: C:\windows\System32\Robocopy.exe` or silently copy
0 asset/layout files. Cause: Wine ships `robocopy.exe` as a **builtin stub**
that copies nothing (exit code 16); B4A invokes it by a fixed path. Fixes:

- install a real `robocopy.exe` into the prefix's `system32` (B4A.exe is
  64-bit), **and**
- set the Wine override `robocopy.exe = native` (the `.exe` suffix is
  mandatory; a bare `robocopy` override is ignored).

The `b4x-android-emulator` skill ships both a prebuilt native `robocopy.exe`
and an installer script. Details and the full emulator recipe are in
[docs/wine.md](docs/wine.md) ("B4A on Android emulator") and in the skill.

> Headless `B4ABuilder.exe` builds (`C-c C-c`) do **not** hit this — they
> package `Files/` via `aapt -A ..\Files` directly. The fix is only needed
> for IDE builds.

## Notes & troubleshooting

- **`void-function` / `wrong-number-of-arguments` after an update**: delete the
  stale `.elc` files and reload:

  ```elisp
  (mapc #'delete-file (directory-files (file-name-directory (locate-library "b4x"))
                                       t "\\.elc\\'"))
  ```

- **Build fails with `bad class file ... wrong version`**: a referenced library
  was compiled for a newer Java than `JavaBin` in `b4xV5.ini`. Edit the INI
  (`Tools → Configure Paths` in the B4X IDE) and point `JavaBin` at a matching
  JDK. Close the IDE before editing the INI by hand (it rewrites it on exit).

- **`module not found: javafx.*`**: for `AppType=JavaFX` projects, `JavaBin`
  must point at a JDK that bundles JavaFX (see [docs/wine.md](docs/wine.md)).

- **B4A build fails early with missing Android paths / `android.jar` / build-tools**:
  open `B4A.exe` under Wine once and configure the Android SDK + Java paths in
  `Tools → Configure Paths`. B4A stores them in
  `.../Anywhere Software/Basic4android/b4xV5.ini`, and headless builds reuse
  that file.

- **Builds work from the shell but not from Emacs**: the vendored scripts need
  `WINEPREFIX` or the default `~/.wine_b4x`. Emacs doesn't inherit your shell
  env unless launched from it; set `b4x-wine-prefix` in your init.

## Repository layout

```
emacs-b4x-integration/
├── WORKPLAN.md          # goals, scope, phases
├── docs/
│   ├── architecture.md  # design + decisions (why pure Elisp)
│   ├── roadmap.md       # phase checklist
│   └── wine.md          # Wine layout & path translation notes
├── emacs/               # the Elisp package
│   ├── b4x.el           # entry: defcustoms, autoloads, major mode, commands
│   ├── b4x-wine.el      # prefix discovery, path translation, ini discovery
│   ├── b4x-project.el   # .b4j/.b4a parsing, module/lib/layout resolution
│   ├── b4x-nav.el       # xref + capf + imenu + eldoc
│   ├── b4x-flymake.el   # flymake diagnostics
│   └── scripts/         # vendored b4x-build.sh / b4x-run.sh
└── test/                # ERT tests
```

## Documentation

- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Wine notes](docs/wine.md)
- [Layout converter notes](docs/layout-converter.md)
- [Work plan](WORKPLAN.md)

## License

MIT — see [LICENSE](LICENSE).
