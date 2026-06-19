---
name: b4x-emacs-dev
description: Work on the emacs-b4x-integration codebase itself. Use when adding or modifying B4X project parsing, Wine integration, layouts, navigation, flymake, build/run wrappers, keybindings, tests, or documentation in this repository.
---

# B4X Emacs Dev

Use this skill when the target is this repository, not just an arbitrary B4X app.

## Read first

Always read the relevant docs before implementing:

- `README.md`
- `docs/architecture.md`
- `docs/roadmap.md`
- `docs/wine.md`
- `docs/layout-converter.md` when layouts are involved

Then inspect the affected module(s):

- `emacs/b4x.el`
- `emacs/b4x-project.el`
- `emacs/b4x-wine.el`
- `emacs/b4x-nav.el`
- `emacs/b4x-flymake.el`
- `emacs/b4x-layout.el`
- `test/b4x-test.el`

## Repo-specific rules learned here

- Architecture is pure Emacs Lisp, not Node/LSP.
- Prefer existing helpers over introducing parallel parsing logic.
- Real local B4X fixture projects are available and should be used for smoke tests.
- Layout sync uses JSON sidecar state, not SQLite.
- Navigation, completion, and layout lookup are project-aware and should stay consistent.

## Required validation mindset

After changes, do the lightest relevant validation:

- load the changed file with `emacs -Q --batch -L emacs ...`
- run targeted ERT tests from `test/b4x-test.el`
- for layout changes, round-trip real `.bjl/.bal/.bil` fixtures
- for UI command/keymap changes, verify the symbol is bound and autoloadable

## Good task breakdowns

### Project model changes
- validate on real `.b4j` / `.b4a` fixtures
- check root-dir vs platform-dir behavior
- verify `ModuleN=` and `FileN=` resolution

### Wine changes
- validate both path directions
- avoid breaking deterministic fallback behavior

### Layout changes
- verify B4J, B4A, and B4i
- preserve typed values and script compression
- keep conflict behavior conservative

### Navigation/intelligence changes
- make sure xref, capf, imenu, and eldoc remain coherent
- add focused tests rather than only manual checks

## Common pitfalls

- editing docs but forgetting code or tests
- adding a feature in `b4x.el` without exposing it in README / dispatch / tests when relevant
- breaking project-local fixture assumptions
- bypassing current architecture with ad-hoc shell parsing where Elisp logic already exists

## Useful local validation commands

```bash
emacs -Q --batch -L emacs --eval '(require '\''b4x)'
emacs -Q --batch -L emacs -l test/b4x-test.el -f ert-run-tests-batch-and-exit
```

Use narrower ERT selectors when possible to keep iteration fast.
