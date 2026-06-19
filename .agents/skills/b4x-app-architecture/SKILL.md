---
name: b4x-app-architecture
description: Design and review the structure of real B4X applications and shared codebases. Use when deciding how to organize modules across B4J/B4A/B4i, whether to use shared modules, how to name files, how to separate platform-specific code from shared logic, or when reviewing project structure, prefixes, and IDE groups.
---

# B4X App Architecture

Use this skill when the task is not just "edit this module", but **how to structure a B4X codebase well**.

This skill is based on practical B4X constraints:

- B4X projects are **module-oriented**, not package/folder-oriented like Java/Kotlin/C#.
- The B4X IDE organizes code primarily with **modules and groups**, not with deep filesystem hierarchies.
- In practice, the cleanest structure usually comes from:
  - **file/module naming prefixes**
  - **IDE groups**
  - **shared modules** for cross-platform logic
  - **small platform adapters** when behavior differs

## Core principle

In B4X, the normal and maintainable approach is usually:

- keep modules as **top-level files** or in the standard project/shared locations
- structure by **filename prefixes**
- structure visually in the IDE with **groups**
- avoid trying to emulate a deep domain-folder tree in the filesystem

In other words:

- **prefixes at file level**
- **groups in the IDE**
- **shared modules for common logic**
- **platform folders only where the platform really differs**

---

## Recommended project shape

For multi-platform apps, prefer a layout like:

```text
MyApp/
  B4J/
    MyApp.b4j
    Files/
  B4A/
    MyApp.b4a
    Files/
  B4i/
    MyApp.b4i
    Files/
  AppCore.bas
  AppConfig.bas
  NavRouter.bas
  SvcSync.bas
  UiTheme.bas
  B4XMainPage.bas
  ...
```

Or equivalent with a configured shared modules folder.

### Meaning

- `B4J/`, `B4A/`, `B4i/`: project/platform shells
- shared `.bas` files at the root or shared-modules location: common logic
- platform-specific layouts remain inside each platform's `Files/`
- platform-specific modules exist only when required

## Shared code strategy

Prefer to share:

- business logic
- state management
- routing/navigation logic
- formatting/parsing
- service orchestration
- repository / use-case logic
- B4XPages code when truly cross-platform

Do **not** over-share:

- designer/layout-specific code
- UI code with many platform-specific assumptions
- code that branches constantly on platform

If a shared module accumulates too many platform conditionals, split it.

---

## Naming convention: prefixes over folders

This is the most important practical rule.

Use prefixes to encode role and domain in the filename.

Examples:

- `AppMain.bas`
- `AppConfig.bas`
- `AppBootstrap.bas`
- `UiTheme.bas`
- `UiDialogs.bas`
- `PgHome.bas`
- `PgSettings.bas`
- `PgCustomerEdit.bas`
- `SvcSync.bas`
- `SvcNotifications.bas`
- `RepoCustomers.bas`
- `RepoOrders.bas`
- `DomInvoice.bas`
- `DomCustomer.bas`
- `UtilDate.bas`
- `UtilJson.bas`
- `PlatDesktopShare.bas`
- `PlatAndroidPerms.bas`

### Why this works better in B4X

Because in B4X you typically navigate by:

- module names
- IDE lists
- groups
- xref/search

not by package hierarchy.

Prefixes make related modules cluster naturally:

- all pages together
- all services together
- all repositories together
- all platform adapters together

without needing filesystem nesting.

---

## IDE groups are first-class organization

Use **groups in the IDE** for the human-facing architecture.

Typical groups:

- App
- Pages
- UI
- Services
- Domain
- Repositories
- Platform
- Utils
- Tests / Debug helpers

Think of groups as the main "folder view" for developers.

### Practical consequence

Prefer this:
- flat/shared files with strong prefixes
- grouped cleanly in the IDE

instead of this:
- many subfolders by domain trying to simulate package trees

## Anti-pattern: deep filesystem domain trees

Avoid forcing structures like:

```text
customer/application/usecases/
customer/infrastructure/repositories/
customer/presentation/pages/
```

inside a normal B4X project unless there is a very strong reason.

Why:

- adds friction to `ModuleN=` maintenance
- complicates shared-module resolution
- fights the way the IDE wants to present modules
- gives less value in B4X than in package-oriented ecosystems

If you want architectural boundaries, express them with:

- prefixes
- groups
- small modules
- naming discipline

---

## Platform separation strategy

Keep platform-specific code thin.

Good pattern:

- shared module defines app behavior
- small platform adapter module handles the platform-specific API

Example:

- `SvcShare.bas` → shared orchestration
- `PlatDesktopShare.bas` → B4J behavior
- `PlatAndroidShare.bas` → B4A behavior

This is better than scattering `#If B4J / #If B4A` everywhere.

### Prefer

- one shared abstraction/orchestrator
- one adapter per platform when needed

### Avoid

- giant shared modules full of branching
- duplicating the whole feature per platform when only 10% differs

---

## Layout and UI organization

Layouts are inherently platform-bound.

Rules:

- keep layouts in each platform's `Files/`
- name them consistently with prefixes too
- keep code/layout naming aligned

Examples:

- `PgHome.bas` ↔ `PgHome.bal` / `PgHome.bjl`
- `DlgLogin.bas` ↔ `DlgLogin.bal`
- `CvCustomerCard.bas` ↔ `CvCustomerCard.bal`

Suggested UI prefixes:

- `Pg` = page / screen / B4XPage
- `Dlg` = dialog
- `Cv` = custom view
- `Ui` = shared UI helpers/theme/style

---

## Suggested prefix taxonomy

Adapt as needed, but be consistent.

### App / bootstrap
- `App...`

### Pages / screens / B4XPages
- `Pg...`

### Dialogs / UI components
- `Dlg...`
- `Cv...`
- `Ui...`

### Services / background orchestration
- `Svc...`

### Domain / business models
- `Dom...`

### Data access / repositories
- `Repo...`

### Platform-specific adapters
- `Plat...`

### Utilities
- `Util...`

### Debug / tooling helpers
- `Dbg...`
- `Dev...`

The exact taxonomy matters less than **staying consistent across the whole project**.

---

## How to decide whether code should be shared

Ask:

1. Does this logic depend on platform UI or APIs?
   - yes → platform module or adapter
   - no → shared module
2. Is the difference only in a thin integration layer?
   - yes → shared orchestrator + platform adapter
3. Will this module be easier to find by prefix/group than by subfolder?
   - in B4X, usually yes

---

## Good default architecture for a real app

Example:

```text
AppMain.bas
AppConfig.bas
AppSession.bas

PgHome.bas
PgSettings.bas
PgCustomerList.bas
PgCustomerEdit.bas

UiTheme.bas
UiFormat.bas
DlgConfirm.bas
CvCustomerCard.bas

SvcSync.bas
SvcAuth.bas
SvcExport.bas

RepoCustomers.bas
RepoInvoices.bas

DomCustomer.bas
DomInvoice.bas

PlatDesktopExport.bas
PlatAndroidExport.bas

UtilDate.bas
UtilJson.bas
UtilStrings.bas
```

And then groups in the IDE:

- App
- Pages
- UI
- Services
- Repositories
- Domain
- Platform
- Utils

This is usually more idiomatic in B4X than a complex tree of folders.

---

## Review checklist

When asked to review a B4X architecture, check:

- Are modules named clearly with prefixes?
- Are related modules clustered naturally by name?
- Are IDE groups doing most of the organization work?
- Is shared logic actually shared?
- Are platform-specific differences isolated?
- Are layouts named consistently with code modules?
- Is the project avoiding unnecessary folder complexity?
- Are large modules split by role instead of by arbitrary domain trees?

---

## Recommended advice style

When helping on B4X architecture, prefer recommendations like:

- "Move this to a shared module"
- "Split this into shared orchestration + platform adapter"
- "Rename these files with `Svc` / `Pg` / `Repo` prefixes"
- "Use IDE groups instead of extra filesystem nesting"
- "Keep layouts per platform, keep logic shared"

Prefer **practical B4X-native structure** over imported architecture aesthetics from other ecosystems.

## See also

- `../b4x-project-model/SKILL.md`
- `../b4x-wine-setup/SKILL.md`
- `../b4x-emacs-dev/SKILL.md`
