---
name: b4x-project-model
description: Understand and modify real B4X project structure across B4J, B4A, B4i, and B4R. Use when inspecting a .b4j/.b4a/.b4i/.b4r file, resolving ModuleN/FileN/LibraryN entries, locating layouts, understanding @EndOfDesignText@, tracing shared modules, or planning changes before editing code or project metadata.
---

# B4X Project Model

Use this skill before making structural changes to a B4X project.

## What to inspect first

1. Read the project file header up to `@EndOfDesignText@`.
2. Identify:
   - `AppType`
   - `ModuleN=`
   - `FileN=`
   - `LibraryN=`
   - `BuildN=`
3. Determine whether the project is:
   - flat (`Project.b4j` at root), or
   - multi-platform (`Root/B4J/*.b4j`, `Root/B4A/*.b4a`, etc.).
4. Resolve modules relative to the platform folder, not blindly relative to repo root.

## Key B4X rules learned in this repo

- `@EndOfDesignText@` splits project metadata from the embedded Main source.
- `ModuleN=` supports forms like:
  - `|relative|..\B4XMainPage`
  - `|absolute|C:\...`
  - `|shared|MyModule`
  - plain values treated like relative paths.
- Layout files live in `Files/` and are platform-specific:
  - B4J: `.bjl`
  - B4A: `.bal`
  - B4i: `.bil`
- `LoadLayout("Name")` references the basename without extension.
- Additional libraries and shared modules may come from `b4xV5.ini`, not only from the repo.

## In this repo specifically

When modifying the Emacs integration, consult:

- `emacs/b4x-project.el`
- `emacs/b4x-nav.el`
- `docs/architecture.md`
- `docs/wine.md`
- `README.md`

These files encode the current assumptions about project discovery, module resolution, layout lookup, and Wine paths.

## Safe workflow

1. Read the project file.
2. Read any referenced module / layout / library metadata needed for the task.
3. If changing project structure, update the relevant `ModuleN=` / `FileN=` / `LibraryN=` counts consistently.
4. If working on the Emacs package, prefer existing helpers over ad-hoc parsing.
5. Validate with tests or with a real fixture project when possible.

## Common pitfalls

- Confusing logical project root with platform folder.
- Assuming layouts are always `.bal`.
- Forgetting that Main code is embedded after `@EndOfDesignText@`.
- Editing module paths without checking `|shared|` or Wine-translated absolute paths.
- Treating `LibraryN=` as self-contained when the actual files live in Additional Libs configured in `b4xV5.ini`.

## See also

- `../b4x-layout-sync/SKILL.md`
- global skills: `b4x-build`, `b4x-run`
