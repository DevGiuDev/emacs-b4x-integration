# Architecture

This document describes the architecture of **emacs-b4x-integration**: a
**pure Emacs Lisp** package that brings B4X (B4J / B4A) development to Emacs on
Linux, with first-class [Wine](https://www.winehq.org/) support.

> **Design note.** The original WORKPLAN.md proposed a Node "core + CLI + LSP"
> backend shared with other editors. After analysis we chose a **pure Elisp**
> implementation instead. Rationale below.

## Why pure Emacs Lisp (no Node/LSP)

The B4X surface we target is modest enough that Emacs' native facilities do the
job better than an external server:

| Concern | Native Emacs facility | Notes |
| --- | --- | --- |
| Project model / parsing | Elisp + I/O | `.b4j`/`.b4a`/`b4xV5.ini` are plain text. |
| Path translation (Wine) | `file-symlinks`, `expand-file-name` | ~30 lines; no subprocess needed. |
| Symbol navigation | `xref-backend` API | First-class, integrates with `M-.`/`M-?`. |
| Completion | `completion-at-point-functions` (capf) | Native, no LSP overhead. |
| On-the-fly diagnostics | `flymake` | Built into Emacs 26+. |
| Outline / structure | `imenu` + `outline-minor-mode` | |
| Signature help / docs | `eldoc` | |
| Build / run | `compile.el` + `project.el` | Wraps vendored Wine shell scripts. |

Benefits:

- **One dependency: Emacs ≥ 28.** No Node, no `npm install`, no subprocess IPC,
  no JSON-RPC. Installable directly from MELPA / `use-package`.
- **Tight integration.** xref, capf, flymake, imenu, project.el, compile.el are
  all native — better UX than any LSP adapter.
- **No lock-in to a server we'd have to maintain.** eglot/lsp-mode earn their
  place when a mature external server already exists; here we'd be writing it.

The only external processes we spawn are the genuine ones — `wine`/`winepath`
for path translation edge-cases and builds, and `java` to run jars. Build/run
logic is delegated to two **vendored, battle-tested shell scripts** shipped
inside the package.

## Goals (MVP)

From Emacs, on Linux with B4X installed under Wine:

1. Open a B4X project (`.b4j`, then `.b4a`).
2. Detect platform configuration (`b4xV5.ini`).
3. Resolve modules and libraries correctly through Wine paths.
4. Navigation + completion + diagnostics (native Emacs backends).
5. Build a B4J project (`B4JBuilder.exe` under Wine).
6. Run the produced jar with Java.

## Non-goals (initial)

- Visual layout designer.
- Full parity with the VSCode extension UX.
- B4A install/deploy to a device.

## Package layout

```
emacs/
├── b4x.el            ; entry: defcustoms, autoloads, minor/major-mode setup
├── b4x-project.el    ; .b4j/.b4a parsing, module/lib resolution, project.el
├── b4x-wine.el       ; prefix discovery, path translation, b4xV5.ini discovery
├── b4x-nav.el        ; xref backend + completion-at-point + imenu + eldoc
├── b4x-flymake.el    ; flymake diagnostics backend
├── b4x-flymake.el    ; flymake diagnostics (dup symbols + type placement)
└── scripts/
    ├── b4x-build.sh  ; vendored — wine B4JBuilder/B4ABuilder, exit parsing
    └── b4x-run.sh    ; vendored — java -jar (StandardJava) or wine java (JavaFX)
```

Build & run commands (`b4x-build` / `b4x-run-project`) live in `b4x.el` and
delegate to the vendored scripts via `compile.el`.

### Module responsibilities

**`b4x-wine.el`** — the Linux/Wine foundation.

- Resolve the active Wine prefix (`defcustom` → `WINEPREFIX` → `~/.wine_b4x`).
- Translate `C:\…` / `Z:\…` → host paths via `dosdevices` symlinks (no `wine`
  subprocess); deterministic fallbacks for `C:` → `drive_c`, `Z:` → `/`.
- Translate host → Windows path; prefers `winepath -w`, falls back to a
  deterministic `drive_c`→`C:\`, everything-else→`Z:\` mapping.
- Discover `b4xV5.ini` and the install dir under the prefix.

**`b4x-project.el`** — the project model.

- Parse a `.b4j`/`.b4a` header (everything up to `@EndOfDesignText@`) into
  structured data: `LibraryN`, `ModuleN`, `BuildN`, `FileN`, `AppType`, etc.
- Resolve `ModuleN=` entries (kinds: `relative` / `absolute` / `shared` /
  plain) to actual host files, trying the path then `+.bas`.
- Extract the embedded "Main" code (post `@EndOfDesignText@`) so navigation
  can index `Process_Globals` in the project file itself.
- Integrate with `project.el`: register a project finder that treats a
  directory containing a `.b4j`/`.b4a` (or their `B4J/`/`B4A/` platform folder)
  as a B4X project.

**`b4x-nav.el`** — navigation & intelligence (native APIs).

- Builds an in-memory symbol table (Subs, Types, globals) by scanning the
  project's resolved module files.
- `xref-backend`: definitions & references for sub/type/global names.
- `completion-at-point`: symbol names + language keywords.
- `imenu`: Subs/Types/Process_Globals for `imenu-list` / outline.
- `eldoc`: signature of the sub at point.

**`b4x-flymake.el`** — diagnostics.

- Duplicate-symbol detection across modules (the classic B4X footgun),
  reusing the symbol table from `b4x-nav`.
- Runs on save / idle; cheap because the table is already built.

**`b4x-build` / `b4x-run-project`** (in `b4x.el`) — build & run.

- `b4x-build` / `b4x-run-project` commands; locate the vendored
  `scripts/b4x-{build,run}.sh` relative to the package, invoke via
  `compile`, route output through `compilation-mode`.
- Honour `defcustom`s for wine prefix, install dir, java path, ports, env.

## Decisions (resolved)

| Question | Decision | Rationale |
| --- | --- | --- |
| Core in Node or Elisp? | **Pure Elisp** | See "Why pure Emacs Lisp" above. |
| LSP server? | **None** | Native xref/capf/flymake integrate better; no server to maintain. |
| Build/Run implementation | **Vendor shell scripts**, elisp wraps with `compile.el` | Wine exit-code parsing + `AppType=JavaFX` are already solved and tested there. |
| Config format | `defcustom` + `.dir-locals.el` | Idiomatic Emacs; per-project overrides via dir-locals. |
| Project integration | `project.el` (built-in ≥ 28) | Standard, no extra deps. |
| Emacs target | **Emacs ≥ 28** | `project.el`, modern `xref`, `flymake`, `capf` all stable. |
| Multi-platform project layout | support `Project/B4J/Project.b4j` with modules in parent | Matches real B4X projects on disk. |

## Reusing elsewhere

The project model (`b4x-project.el`) and Wine layer (`b4x-wine.el`) are pure
Elisp data modules with no editor side-effects; they could be extracted into a
separate library if a non-Emacs consumer ever needs the *model* (but not the
navigation). For now, Emacs is the only consumer and we keep it monolithic.
