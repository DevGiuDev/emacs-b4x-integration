---
name: b4x-layout-sync
description: Work with B4X layouts and JSON sidecars. Use when converting or syncing .bjl/.bal/.bil files with JsonLayouts/*.json, debugging LoadLayout targets, editing designer data outside the IDE, resolving layout-sync conflicts, or working on the layout converter in this repo.
---

# B4X Layout Sync

Use this skill when the task involves B4X layout binaries or their JSON form.

## Scope

Covers:
- `.bjl`, `.bal`, `.bil`
- `Files/` layout discovery
- `JsonLayouts/*.json` sidecars
- conflict-aware sync
- the pure-Elisp converter implemented in this repo

## In this repo

Read these first when changing layout behavior:

- `emacs/b4x-layout.el`
- `docs/layout-converter.md`
- `test/b4x-test.el`
- `README.md`

## Important format facts

- Layout files are little-endian binary.
- There are two string caches.
- Maps are recursive and typed.
- `DesignerScript` is stored as a gzip-compressed subpayload.
- Typed wrappers matter; plain JSON strings are not equivalent to typed string values.
- B4i (`.bil`) has a write-time exception: skip `CNULL` and `RECT32` typed wrappers.

## Sync policy

Do **not** use raw file mtimes as the only truth source.

Preferred policy in this repo:

1. Use the optional sidecar:
   - `JsonLayouts/.b4x-layout-sync.json`
2. Compare current mtimes against the last synced mtimes.
3. If only one side changed, sync that direction.
4. If both sides changed:
   - if semantic content is equal, accept as unchanged
   - otherwise report conflict; do not guess
5. No SQLite dependency.

## Commands in this repo

When working inside the Emacs package, prefer the built-in commands:

- `b4x-layout-open-json`
- `b4x-layout-export`
- `b4x-layout-import`
- `b4x-layout-sync-project`

Key binding:

- `C-c C-y` → sync project layouts

## Safe workflow

1. Resolve the project and layout name first.
2. Read the binary or JSON side that is authoritative.
3. Preserve typed values and ordering-sensitive structure.
4. Round-trip test when changing converter code:
   - binary → object → binary
   - binary → JSON → object → binary
5. Validate on real fixtures for B4J, B4A, and B4i.

## Common pitfalls

- Assuming `.bal` for every platform.
- Treating JSON as an untyped map.
- Ignoring the `.bil` special case.
- Using mtimes alone and overwriting a concurrent edit.
- Forgetting to create `JsonLayouts/` before export.

## Validation targets

Good local fixtures used in this repo:

- `~/dev/B4XProj/emacs-testing/B4J/Files/MainPage.bjl`
- `~/dev/B4XProj/emacs-testing/B4A/Files/mainpage.bal`
- `~/dev/B4XProj/emacs-testing/B4i/Files/mainpage.bil`
