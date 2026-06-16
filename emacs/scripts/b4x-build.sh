#!/usr/bin/env bash
# b4x-build.sh — Compile a B4X project (B4J or B4A) via the corresponding
# *Builder.exe running under Wine.
#
# Usage:
#   b4x-build.sh [--project <file.b4j|file.b4a>] [--task <Task>]
#                 [--config <configuration>] [--wineprefix <dir>]
#                 [--b4x-root <dir>] [--] [project-dir]
#
# Defaults:
#   project-dir     = current working directory
#   --project       = the only .b4j/.b4a file in project-dir (auto-detected)
#   --task          = Build
#   --config        = Default (B4J), or empty for B4A
#   --wineprefix    = $WINEPREFIX or ~/.wine_b4x
#   --b4x-root      = $B4X_ROOT or $WINEPREFIX/drive_c/Program Files/Anywhere Software
#
# Environment overrides (same names) take priority over defaults but are
# overridden by command-line flags.
#
# Exit codes:
#   0  build succeeded (B4JBuilder prints "Completed successfully")
#   1  usage error / missing prerequisites
#   2  build failed (compile error, missing libs, Wine crash, ...)
#
# Output:
#   Wine noise goes to stderr, builder output goes to stdout/stderr.
#   The last 5 lines of stdout are scanned for the "Completed successfully"
#   marker so callers can treat exit-code 0 as authoritative.

set -euo pipefail

die() { echo "b4x-build: $*" >&2; exit "${2:-1}"; }

# ---- defaults -------------------------------------------------------------
# Note: B4JBuilder expects -BuildConfig=<ConfigurationName>,<PackageName>
# in that exact form. If omitted, the builder uses the first Build1= entry
# from the .b4j file. We default to "omitted" (use the project's own value).
DEFAULT_TASK="Build"
WINEPREFIX_DEFAULT="$HOME/.wine_b4x"
B4X_ROOT_DEFAULT="$WINEPREFIX_DEFAULT/drive_c/Program Files/Anywhere Software"

# ---- arg parsing ----------------------------------------------------------
PROJECT_FILE=""
TASK=""
CONFIG=""
WINEPREFIX_VAL=""
B4X_ROOT_VAL=""
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)     PROJECT_FILE="$2"; shift 2 ;;
    --task)        TASK="$2"; shift 2 ;;
    --config)      CONFIG="$2"; shift 2 ;;
    --wineprefix)  WINEPREFIX_VAL="$2"; shift 2 ;;
    --b4x-root)    B4X_ROOT_VAL="$2"; shift 2 ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown flag: $1" ;;
    *)  break ;;
  esac
done

if [[ $# -gt 0 && -z "$PROJECT_DIR" ]]; then
  PROJECT_DIR="$1"; shift
fi
[[ $# -eq 0 ]] || die "trailing arguments: $*"

# ---- resolve values -------------------------------------------------------
: "${WINEPREFIX_VAL:=${WINEPREFIX:-$WINEPREFIX_DEFAULT}}"
: "${B4X_ROOT_VAL:=${B4X_ROOT:-$B4X_ROOT_DEFAULT}}"
[[ -d "$WINEPREFIX_VAL" ]] || die "WINEPREFIX not found: $WINEPREFIX_VAL"
[[ -d "$B4X_ROOT_VAL"   ]] || die "B4X root not found: $B4X_ROOT_VAL"

PROJECT_DIR="${PROJECT_DIR:-$PWD}"
[[ -d "$PROJECT_DIR" ]] || die "project-dir not found: $PROJECT_DIR"

# Detect project flavor from --project (if given) or directory contents.
if [[ -n "$PROJECT_FILE" ]]; then
  [[ -f "$PROJECT_FILE" ]] || die "project file not found: $PROJECT_FILE"
  case "${PROJECT_FILE##*.}" in
    b4j) FLAVOR="B4J" ;;
    b4a) FLAVOR="B4A" ;;
    *)   die "unsupported project extension: $PROJECT_FILE" ;;
  esac
else
  mapfile -t B4J_FILES < <(find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.b4j' -printf '%f\n')
  mapfile -t B4A_FILES < <(find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.b4a' -printf '%f\n')
  case "${#B4J_FILES[@]}:${#B4A_FILES[@]}" in
    1:0) FLAVOR="B4J"; PROJECT_FILE="$PROJECT_DIR/${B4J_FILES[0]}" ;;
    0:1) FLAVOR="B4A"; PROJECT_FILE="$PROJECT_DIR/${B4A_FILES[0]}" ;;
    0:0) die "no .b4j/.b4a file in $PROJECT_DIR; pass --project" ;;
    *)   die "multiple project files in $PROJECT_DIR; pass --project" ;;
  esac
fi

: "${TASK:=$DEFAULT_TASK}"
# CONFIG is intentionally left empty unless the user passes --config.
# See note above on the expected `Name,Package` format.

BUILDER_DIR="$B4X_ROOT_VAL/$FLAVOR"
case "$FLAVOR" in
  B4J) BUILDER="B4JBuilder.exe" ;;
  B4A) BUILDER="B4ABuilder.exe" ;;
esac
[[ -f "$BUILDER_DIR/$BUILDER" ]] || die "$BUILDER not found in $BUILDER_DIR"

# ---- run builder ----------------------------------------------------------
PROJECT_WIN="$(WINEPREFIX="$WINEPREFIX_VAL" winepath -w "$PROJECT_DIR")"

echo "b4x-build: flavor=$FLAVOR builder=$BUILDER task=$TASK config=${CONFIG:-<none>}"
echo "b4x-build: project=$PROJECT_WIN"

# Build the argument list. Only pass -BuildConfig when the user explicitly
# provided --config; otherwise let the builder pick the first Build1= entry
# from the .b4j file.
ARGS=(-Task="$TASK" -BaseFolder="$PROJECT_WIN")
if [[ -n "${CONFIG:-}" ]]; then
  ARGS+=(-BuildConfig="$CONFIG")
fi

# Some builders prepend a Wine server noise line; capture both streams.
BUILD_LOG="$(mktemp -t b4x-build.XXXXXX.log)"
trap 'rm -f "$BUILD_LOG"' EXIT

# B4JBuilder writes "Completed successfully" on success. We can't rely on
# Wine's exit code (it's often 0 even on build failure), so we scan output.
cd "$BUILDER_DIR"
WINEPREFIX="$WINEPREFIX_VAL" wine "./$BUILDER" "${ARGS[@]}" 2>&1 | tee "$BUILD_LOG"
BUILD_RC=${PIPESTATUS[0]}

# ---- verdict --------------------------------------------------------------
# Look for the canonical success marker. Also detect known failure banners.
if grep -qiE 'Completed successfully' "$BUILD_LOG"; then
  echo "b4x-build: ✓ build OK (task=$TASK)"
  exit 0
fi

if grep -qiE 'Error|Exception|error compiling|Cannot find|Build failed|Failed to' "$BUILD_LOG"; then
  echo "b4x-build: ✗ build FAILED (see log above)" >&2
  exit 2
fi

if [[ "$BUILD_RC" -ne 0 ]]; then
  echo "b4x-build: ✗ Wine exit $BUILD_RC without a success marker" >&2
  exit 2
fi

# Ambiguous: no success marker but no error either. Treat as failure.
echo "b4x-build: ? builder exited cleanly but no 'Completed successfully' marker found" >&2
exit 2
