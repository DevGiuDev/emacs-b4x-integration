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

Build and run under Wine delegate to two **vendored, battle-tested shell
scripts** shipped inside the package (`emacs/scripts/`).

## Status

Phases 0–6 complete (pure-Elisp package, Linux/Wine first). See
[`docs/roadmap.md`](docs/roadmap.md): Wine path translation, project model,
major mode with native xref/capf/imenu/eldoc, flymake diagnostics, build/run
under Wine, plus ergonomics (layout jump, module switcher, dispatch menu).

MVP target achieved: open a B4J project, get navigation/completion/diagnostics,
build and run it — all from Emacs on a Linux box where B4X lives inside a Wine
prefix. Remaining: B4A polish (Phase 7) and designer (Phase 8).

## Repository layout

```
emacs-b4x-integration/
├── WORKPLAN.md          # goals, scope, phases
├── docs/
│   ├── architecture.md  # design + decisions (why pure Elisp)
│   ├── roadmap.md       # phase checklist
│   └── wine.md          # Wine layout & path translation notes
├── emacs/               # the Elisp package
│   ├── b4x.el           # entry: defcustoms, autoloads, major mode
│   ├── b4x-wine.el      # prefix discovery, path translation, ini discovery
│   ├── b4x-project.el   # .b4j/.b4a parsing, module/lib resolution, project.el
│   ├── b4x-nav.el       # xref + capf + imenu + eldoc
│   ├── b4x-flymake.el   # flymake diagnostics
│   └── scripts/         # vendored b4x-build.sh / b4x-run.sh
└── test/                # ERT tests
```

Build & run commands live in `b4x.el` (not a separate `b4x-build.el`).

## Documentation

- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Wine notes](docs/wine.md)
- [Work plan](WORKPLAN.md)

## License

MIT — see [LICENSE](LICENSE).
