# emacs-b4x-integration

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
B4X lives inside a Wine prefix. Remaining: B4A polish (Phase 7) and designer
(Phase 8).

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
  $WINEPREFIX/drive_c/users/<user>/AppData/Roaming/Anywhere Software/<B4J|B4A>/b4xV5.ini
  ```

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
(b4x--ide-exe-path 'b4j)             ; => ".../B4J/B4J.exe"
```

If `b4x-wine-active-p` is `nil` while you're on Linux, set `b4x-wine-enabled`
to `t` explicitly.

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
4. `C-c C-c` to build under Wine; output lands in a `compilation-mode` buffer.
5. `C-c C-r` to run the jar.
6. `C-c C-e` to pop open the official B4X IDE under Wine (detached).

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
| `C-c C-i` | `b4x-project-info` | Show modules, libraries, INI, root in a buffer. |
| `C-c C-n` | `b4x-new-module` | Create a new B4J module (`Static Code`, `Class`, `B4XPage`) and register it in the `.b4j`. |
| `C-c C-m` | `b4x-switch-module` | Jump to another module (completing-read). |

### Navigation & intelligence (native Emacs)

| Key | Command | Description |
| --- | --- | --- |
| `M-.` | `xref-find-definitions` | Go to Sub/Type/global definition (B4X xref backend). |
| `M-?` | `xref-find-references` | Find references across project modules. |
| `M-TAB` / `C-M-i` | `completion-at-point` | Complete symbols + keywords. |
| `M-x imenu` | `b4x-imenu-index` | Browse Subs / Types / Globals of the buffer. |
| — (eldoc) | `b4x-eldoc-function` | Sub signature in the echo area. |
| — (flymake) | `b4x-flymake` | Duplicate-symbol + type-placement warnings. |

### Layouts

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-l` | `b4x-goto-layout` | Jump to the layout at point (`LoadLayout("X")`) or pick one. |

### Build, run & IDE

| Key | Command | Description |
| --- | --- | --- |
| `C-c C-c` | `b4x-build` | Build with `wine B4JBuilder.exe`/`B4ABuilder.exe` (the builder itself handles code generation + Java compilation internally). |
| `C-c C-r` | `b4x-run-project` | Run the jar (`java -jar`, or `wine java` for JavaFX). |
| `C-c C-e` | `b4x-open-in-ide` | Open the project in the official B4X IDE under Wine (fully detached via `setsid`/`nohup`; Wine output → `b4x-ide-log-file`). |
| `C-c C-d L` | `b4x-ide-log` | Show the Wine log if the IDE ever fails to open. |

### `project.el`

Opening any file under a B4X project root registers it with `project.el`; use
`C-x p p` (`project-switch-project`) or `C-x p f` (`project-find-file`) to move
across modules.

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
- [Work plan](WORKPLAN.md)

## License

MIT — see [LICENSE](LICENSE).
