# Layout converter notes (`.bjl` / `.bal` / `.bil` ⇄ JSON)

This document captures the format and workflow reverse-engineered from
`~/dev/B4XProj/JsonLayouts/` so we can add layout sync to this package without
opening B4J / B4A / B4i.

## Source studied

- `~/dev/B4XProj/JsonLayouts/BalConverter.bas`
- `~/dev/B4XProj/JsonLayouts/JsonLayouts.b4j`

I also sanity-checked the format against real local layout files from B4J and
B4A projects (`MainPage.bjl`, `mainpage.bal`).

## What the external project does

`JsonLayouts` has two parts:

1. `BalConverter.bas`
   - pure binary reader/writer for layout files
   - converts `.bjl` / `.bal` / `.bil` ⇄ JSON
2. `JsonLayouts.b4j`
   - folder synchronizer
   - compares mtimes of `Files/*.b?l` vs `JsonLayouts/*.json`
   - stores last synced state in `JsonLayouts/layouts.db`
   - detects conflicts when both sides changed

For this Emacs package, the converter itself is reusable, but the SQLite part is
**not required**. We can keep the same conflict semantics with either:

- no persisted state at all for manual import/export commands, or
- a small optional JSON sidecar for automatic sync.

So the important reusable part for us is **`BalConverter.bas`**.

## File format

All numeric values are little-endian.

### Primitive tags used inside maps

| Tag | Name | Meaning |
| --- | --- | --- |
| `1` | `CINT` | 32-bit int |
| `2` | `CSTRING` | raw UTF-8 string, wrapped as `{ "ValueType": 2, "Value": ... }` |
| `3` | `CMAP` | nested map/object |
| `4` | `ENDOFMAP` | end sentinel for a map |
| `5` | `BOOL` | single byte `0/1` |
| `6` | `CCOLOR` | 4 raw bytes, exposed as `0xAARRGGBB`-style hex |
| `7` | `CFLOAT` | 32-bit float |
| `9` | `CACHED_STRING` | string table index |
| `11` | `RECT32` | 4 little-endian 16-bit ints |
| `12` | `CNULL` | explicit null marker |

### High-level layout structure

1. `Int32 version`
2. `Int32 header_size_stub`
3. `Int32 grid_size` when `version >= 4`
4. layout-header string cache
5. control headers list
6. referenced files list
7. compressed designer-scripts blob
8. data-section string cache
9. variants list
10. recursive property map
11. `Int32 0` sentinel
12. `Byte font_awesome_flag`
13. `Byte material_icons_flag`

### Layout header

The header decodes to:

```json
{
  "Version": 5,
  "GridSize": 10,
  "ControlsHeaders": [
    {"Name": "Button1", "JavaType": ".ButtonWrapper", "DesignerType": "Button"}
  ],
  "Files": [],
  "DesignerScript": [
    "'All variants script\n",
    "'Variant specific script: 600x600,scale=1\n"
  ]
}
```

Notes:

- `ControlsHeaders` are written using a dedicated string cache.
- `DesignerScript` is either:
  - a base64 string in older JSON exports, or
  - the decoded logical representation used by current code: a list where the
    first item is the global script and the remaining items are per-variant
    scripts.

### Variants

Each variant is always:

```json
{"Scale": 1.0, "Width": 600, "Height": 600}
```

Binary form is `Float32 + Int32 + Int32`.

### Recursive property map

The layout body is a recursive map of key/value pairs. Plain JSON values are
**not** enough; some values need typed wrappers.

Encoding rules from `WriteMap`:

- nested object without `ValueType` => real nested map (`CMAP`)
- plain integer => `CINT`
- plain string => `CACHED_STRING`
- plain boolean => `BOOL`
- `null` => `CNULL`
- typed object with `ValueType` => exact binary type

Typed JSON wrappers used by the converter:

```json
{"ValueType": 2, "Value": "raw string"}
{"ValueType": 7, "Value": 14.0}
{"ValueType": 6, "Value": "0xFF000000"}
{"ValueType": 11, "Value": [left, top, right, bottom]}
{"ValueType": 12}
```

This means a future Emacs-side writer must preserve the distinction between:

- plain JSON string => cached/interned string
- typed string wrapper => raw string payload

That distinction is essential for round-tripping.

## B4I special case (`.bil`)

`BalConverter.Initialize(ToBIL As Boolean)` sets `mToBIL`.

When writing `.bil`, `WriteMap` skips typed values whose `ValueType` is:

- `CNULL` (`12`)
- `RECT32` (`11`)

So B4I output is **not** a byte-for-byte superset of B4J/B4A output. The
writer must keep this branch.

## Sync algorithm used by `JsonLayouts.b4j`

Per layout name:

- if only binary exists:
  - convert to JSON unless DB says JSON owned the last sync, then delete stale side
- if only JSON exists:
  - convert to binary unless DB says binary owned the last sync, then delete stale side
- if both exist:
  - unchanged if both mtimes match DB
  - binary newer => export to JSON
  - JSON newer => import to binary
  - both newer => conflict, delete DB row and force manual resolution

The original project stores that state in this DB table:

```sql
CREATE TABLE IF NOT EXISTS layouts (
  name_lower TEXT PRIMARY KEY,
  name_not_lower TEXT,
  bal_layout_time INTEGER,
  json_layout_time INTEGER,
  owner INTEGER
)
```

## Decision for this package

We will **not** add SQLite for layout sync.

Planned behavior:

- `export` / `import` commands: no persisted state needed
- `sync` command: optional sidecar JSON file, e.g.
  `JsonLayouts/.b4x-layout-sync.json`
- if no sidecar exists yet, sync can still work in a conservative mode:
  - only-one-side-exists => create the missing side
  - both exist => compare mtimes
  - ambiguous case => report conflict instead of guessing

So the real must-have is the **conflict rule**, not the database engine.

## Observed decoded shapes

Real files decode cleanly to data like:

- top-level `Data` map with keys such as `csType`, `type`, `drawable`,
  `variant0`, `:kids`
- child controls stored under `:kids` as nested maps keyed by string indices
- designer scripts stored separately in `LayoutHeader.DesignerScript`

So JSON export is suitable as a text-friendly, diffable representation.

## Risks / compatibility notes

1. **Unsupported versions**
   - `BalConverter` rejects versions `< 3`.

2. **Designer-script string length quirk**
   - `WriteBinaryString` writes the varint length using `s.Length`, then writes
     `s.GetBytes("utf8")`.
   - For non-ASCII text this may differ from UTF-8 byte length.
   - In practice designer scripts seem ASCII, but an Emacs implementation
     should either mimic this behavior exactly or document the limitation.

3. **Stable ordering**
   - To keep JSON diffs readable, the reader should preserve decoded key order
     as much as possible.

4. **Gzip blob**
   - designer scripts are stored as a gzip-compressed sub-payload; this is the
     only compressed part of the format.

## Recommended integration in this package

To stay aligned with the current architecture, the best target is a new pure
Elisp module, tentatively:

- `emacs/b4x-layout.el`

Responsibilities:

1. binary reader for `.bjl` / `.bal` / `.bil`
2. binary writer for the same formats
3. JSON import/export helpers
4. project-level layout sync helpers for `Files/` ↔ `JsonLayouts/`

Suggested interactive commands:

- `b4x-layout-export` — current layout file → JSON
- `b4x-layout-import` — JSON → binary layout
- `b4x-layout-sync-project` — sync all layouts of current project
- `b4x-layout-open-json` — jump from `LoadLayout("X")` to `JsonLayouts/X.json`

## Suggested implementation order

### Phase 1
- add low-level reader
- validate on local `.bjl` / `.bal` / `.bil` fixtures
- expose an internal Lisp object shape matching the JSON converter

### Phase 2
- add writer
- round-trip test: binary → object → binary → object
- keep B4I special-case behavior

### Phase 3
- add project commands and conflict detection
- optional JSON sidecar state file for sync ownership / last mtimes
- no SQLite dependency

### Phase 4
- optional save hooks / transient entries / layout-aware navigation to JSON sidecars

## Practical conclusion

The converter is very feasible in this repo.

The format is not huge; the only tricky parts are:

- the two string caches
- typed map values
- gzip-compressed designer scripts
- the `.bil` write exception

Everything else is straightforward little-endian binary I/O.