# Roadmap

Tracks the phases from `WORKPLAN.md`, adapted to the pure-Elisp design.
Status is updated as work lands.

## Phase 0 — Bootstrap
- [x] Repo structure
- [x] License (MIT)
- [x] Stack decision: **pure Emacs Lisp** package, vendored Wine shell scripts
- [x] Architecture document
- [x] Vendored `b4x-build.sh` / `b4x-run.sh` into `emacs/scripts/`

## Phase 1 — Wine foundation + project model
- [x] `b4x-wine.el` — prefix discovery, path translation, ini discovery
- [x] `b4x-project.el` — `.b4j`/`.b4a` parsing + module/lib resolution + main extraction
- [x] Tested against real B4J projects under Wine on this machine (10 ERT tests green)

**Success criterion:** given a real B4J project on Linux/Wine, Elisp returns
correct modules, libraries, and host paths. ✅

## Phase 2 — Emacs basics
- [x] `b4x.el` — package header, defcustoms, autoloads, derived major mode
- [x] `project.el` integration (project finder + project roots)
- [x] B4X major mode: font-lock, syntax table, imenu
- [x] `b4x-open-project` / `b4x-project-info` interactive commands

**Success criterion:** load a B4J project from Emacs and inspect its metadata. ✅

## Phase 3 — Navigation & intelligence
- [x] `b4x-nav.el` — symbol table builder (scan resolved modules + main code)
- [x] xref backend: definitions + references for subs/types/globals
- [x] `completion-at-point` (symbols + keywords)
- [x] `imenu` + `outline` + `which-function` (current sub)
- [x] `eldoc` sub signatures

**Success criterion:** open a `.bas`/`.b4j` and get goto-def, completion,
references. ✅

## Phase 4 — Diagnostics
- [x] `b4x-flymake.el` — duplicate-symbol detection across modules +
      type-placement heuristic
- [x] reuses the symbol table from `b4x-nav`; current buffer parsed live
- [x] wired into `b4x-mode' (flymake on by default via `b4x-enable-flymake')

**Success criterion:** warnings appear for symbols defined in multiple
modules. ✅

## Phase 5 — Build / Run
- [x] `b4x-build` / `b4x-run-project` commands wrapping the vendored scripts
      via `compile.el` (flags-first arg order, two-arg `--flag value` form)
- [x] defcustoms for wine prefix (auto), java opts, port
- [x] compilation error regexp matching B4JBuilder/javac `file:line:` output
- [x] validated end-to-end: a minimal StandardJava project builds under Wine
      (`Completed successfully`, jar produced) and runs with native `java`
      (`Hello from B4J via Emacs!`); Emacs wrapper emits the exact validated
      command line

**Success criterion:** compile and run a real B4J project from Emacs on Linux. ✅

## Phase 6 — Ergonomics
- [x] jump to `.bal`/`.bjl` layouts from `LoadLayout("...")` (case-insensitive;
      resolves via header `FileN=` entries + `Files/` dir scan, platform-aware
      extension: `.bjl`/`.bal`/`.bil`)
- [x] module switcher (`b4x-switch-module`, completing-read over project modules)
- [x] transient dispatch menu (`b4x-dispatch`, no extra deps)
- [x] keymap: C-c C-d dispatch, C-c C-l layout, C-c C-m module, C-c C-c build,
      C-c C-r run, C-c C-o open, C-c C-i info
- [x] fixed latent bug in project-file walk-up (misplaced `cl-return')

**Success criterion:** fast ergonomic navigation between code, modules, and
layouts. ✅

## Phase 7 — B4A
- [ ] B4A config + build under Wine
- [ ] (later) install/run on device

## Phase 8 — Designer
- Deferred. Open questions captured in WORKPLAN.md.
