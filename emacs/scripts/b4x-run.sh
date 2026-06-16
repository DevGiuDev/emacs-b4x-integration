#!/usr/bin/env bash
# b4x-run.sh — Run a B4J project's compiled jar (Objects/<name>.jar).
#
# Supports both B4J `AppType` flavors:
#
#   StandardJava  →  exec native `java -jar <jar>`       (no Wine needed)
#   JavaFX        →  exec `wine java.exe` with the JavaFX module-path
#                    and `--add-modules`. Required because the JavaFX
#                    shipped with B4X is Windows-only (DLL-based).
#
# Usage:
#   b4x-run.sh [--jar <path>] [--env <file>] [--workdir <dir>]
#              [--java-opts '<opts>'] [--port <n>] [--timeout <s>]
#              [--app-type <StandardJava|JavaFX>]
#              [--wineprefix <dir>] [--java-exe <win-path>]
#              [--javafx-lib <win-path>] [--javafx-modules <csv>]
#              [--] [project-dir]
#
# Defaults:
#   project-dir     = current working directory
#   --jar           = the only Objects/*.jar, or the one whose basename
#                     matches the *.b4j file in project-dir
#   --env           = ./.env (loaded only if present)
#   --workdir       = project-dir
#   --java-opts     = $JAVA_OPTS
#   --port          = (forwarded to the app as PORT=)
#   --timeout       = 0 (run until killed; pass seconds to auto-kill)
#   --app-type      = read from `AppType=` line of the .b4j
#   --wineprefix    = $WINEPREFIX or ~/.wine_b4x
#   --java-exe      = <JavaBin>/java.exe (from b4xV5.ini), or
#                     $B4X_JAVA_EXE if set
#   --javafx-lib    = <JavaBin>/../javafx/lib, or $B4X_JAVAFX_LIB
#   --javafx-modules= $B4X_JAVAFX_MODULES or
#                     javafx.controls,javafx.graphics,javafx.fxml,
#                     javafx.web,javafx.swing

set -euo pipefail

die() { echo "b4x-run: $*" >&2; exit "${2:-1}"; }

# ---- defaults -------------------------------------------------------------
WINEPREFIX_DEFAULT="$HOME/.wine_b4x"
DEFAULT_JAVAFX_MODULES="javafx.controls,javafx.graphics,javafx.fxml,javafx.web,javafx.swing"
B4X_INI_DEFAULT_PATH_IN_WIN="users/$USER/AppData/Roaming/Anywhere Software/B4J/b4xV5.ini"

# ---- arg parsing ----------------------------------------------------------
JAR=""
ENV_FILE=""
WORKDIR=""
JAVA_OPTS_VAL=""
PORT_VAL=""
TIMEOUT_VAL="0"
APP_TYPE=""
WINEPREFIX_VAL=""
JAVA_EXE_VAL=""
JAVAFX_LIB_VAL=""
JAVAFX_MODULES_VAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jar)            JAR="$2"; shift 2 ;;
    --env)            ENV_FILE="$2"; shift 2 ;;
    --workdir)        WORKDIR="$2"; shift 2 ;;
    --java-opts)      JAVA_OPTS_VAL="$2"; shift 2 ;;
    --port)           PORT_VAL="$2"; shift 2 ;;
    --timeout)        TIMEOUT_VAL="$2"; shift 2 ;;
    --app-type)       APP_TYPE="$2"; shift 2 ;;
    --wineprefix)     WINEPREFIX_VAL="$2"; shift 2 ;;
    --java-exe)       JAVA_EXE_VAL="$2"; shift 2 ;;
    --javafx-lib)     JAVAFX_LIB_VAL="$2"; shift 2 ;;
    --javafx-modules) JAVAFX_MODULES_VAL="$2"; shift 2 ;;
    -h|--help)        sed -n '2,40p' "$0"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown flag: $1" ;;
    *)  break ;;
  esac
done

PROJECT_DIR="${1:-$PWD}"
shift || true
[[ $# -eq 0 ]] || die "trailing arguments: $*"

[[ -d "$PROJECT_DIR" ]] || die "project-dir not found: $PROJECT_DIR"
[[ -d "$PROJECT_DIR/Objects" ]] || die "no Objects/ dir in $PROJECT_DIR; build first?"

WORKDIR="${WORKDIR:-$PROJECT_DIR}"
: "${ENV_FILE:=$PROJECT_DIR/.env}"
: "${JAVA_OPTS_VAL:=${JAVA_OPTS:-}}"
: "${WINEPREFIX_VAL:=${WINEPREFIX:-$WINEPREFIX_DEFAULT}}"

# ---- locate jar + .b4j ----------------------------------------------------
B4J_FILE=""
mapfile -t B4J_FILES < <(find "$PROJECT_DIR" -maxdepth 1 -type f -name '*.b4j' -printf '%f\n')
if [[ ${#B4J_FILES[@]} -eq 1 ]]; then
  B4J_FILE="$PROJECT_DIR/${B4J_FILES[0]}"
fi

if [[ -n "$JAR" ]]; then
  [[ -f "$JAR" ]] || die "jar not found: $JAR"
else
  if [[ -n "$B4J_FILE" ]]; then
    STEM="$(basename "${B4J_FILE%.b4j}")"
    if [[ -f "$PROJECT_DIR/Objects/$STEM.jar" ]]; then
      JAR="$PROJECT_DIR/Objects/$STEM.jar"
    fi
  fi
  if [[ -z "$JAR" ]]; then
    mapfile -t JAR_CANDIDATES < <(find "$PROJECT_DIR/Objects" -maxdepth 1 -type f -name '*.jar' -printf '%p\n')
    case "${#JAR_CANDIDATES[@]}" in
      0) die "no *.jar in $PROJECT_DIR/Objects; build first?" ;;
      1) JAR="${JAR_CANDIDATES[0]}" ;;
      *) die "multiple jars in Objects/; pass --jar <path>" ;;
    esac
  fi
fi

# ---- detect AppType from .b4j --------------------------------------------
# The .b4j file typically has a UTF-8 BOM and CRLF line endings.
if [[ -z "$APP_TYPE" ]]; then
  if [[ -n "$B4J_FILE" ]]; then
    APP_TYPE=$(sed -e '1s/^\xef\xbb\xbf//' -e '/@EndOfDesignText@/q' "$B4J_FILE" \
                 | tr -d '\r' \
                 | awk -F= '/^AppType=/ { print $2 }' \
                 | tail -1)
  fi
  APP_TYPE="${APP_TYPE:-StandardJava}"
fi
case "$APP_TYPE" in
  StandardJava|JavaFX) ;;
  *) die "unsupported AppType='$APP_TYPE' (expected StandardJava or JavaFX)" ;;
esac

# ---- load .env ------------------------------------------------------------
if [[ -f "$ENV_FILE" ]]; then
  echo "b4x-run: loading $ENV_FILE"
  set -a
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# || ! "$line" =~ = ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    value="${value#\"}"; value="${value%\"}"
    value="${value#\'}"; value="${value%\'}"
    export "$key=$value"
  done < "$ENV_FILE"
  set +a
fi

if [[ -n "$PORT_VAL" ]]; then
  export PORT="$PORT_VAL"
  export JVM_SERVER_PORT="$PORT_VAL"
fi

# ---- resolve JavaFX launcher (only matters for JavaFX) --------------------
JAVA_BIN_WIN=""
if [[ "$APP_TYPE" == "JavaFX" ]]; then
  # 1. --java-exe wins
  # 2. $B4X_JAVA_EXE
  # 3. JavaBin from b4xV5.ini (under the wineprefix)
  : "${JAVA_EXE_VAL:=${B4X_JAVA_EXE:-}}"
  if [[ -z "$JAVA_EXE_VAL" ]]; then
    INI_PATH="$WINEPREFIX_VAL/drive_c/$B4X_INI_DEFAULT_PATH_IN_WIN"
    if [[ -f "$INI_PATH" ]]; then
      JAVA_BIN_WIN=$(grep -E '^JavaBin=' "$INI_PATH" | tail -1 | sed 's/^JavaBin=//; s/\r$//')
    fi
    [[ -n "$JAVA_BIN_WIN" ]] || die "could not find JavaBin in $INI_PATH; pass --java-exe"
    JAVA_EXE_VAL="$JAVA_BIN_WIN\\java.exe"
  fi

  : "${JAVAFX_LIB_VAL:=${B4X_JAVAFX_LIB:-}}"
  if [[ -z "$JAVAFX_LIB_VAL" ]]; then
    # JavaFX lib dir is conventionally <JavaBin>\..\javafx\lib
    if [[ -n "$JAVA_BIN_WIN" ]]; then
      JAVAFX_LIB_VAL="${JAVA_BIN_WIN%\\bin}\\javafx\\lib"
    else
      # Derive from JAVA_EXE_VAL: strip trailing \java.exe and \bin.
      PARENT="${JAVA_EXE_VAL%\\java.exe}"
      PARENT="${PARENT%\\bin}"
      JAVAFX_LIB_VAL="$PARENT\\javafx\\lib"
    fi
  fi

  : "${JAVAFX_MODULES_VAL:=${B4X_JAVAFX_MODULES:-$DEFAULT_JAVAFX_MODULES}}"
fi

# ---- launch ---------------------------------------------------------------
echo "b4x-run: jar=$JAR workdir=$WORKDIR appType=$APP_TYPE"
[[ -n "$JAVA_OPTS_VAL" ]] && echo "b4x-run: JAVA_OPTS=$JAVA_OPTS_VAL"
[[ -n "${PORT:-}" ]] && echo "b4x-run: PORT=$PORT"

cd "$WORKDIR"

cleanup() {
  if [[ -n "${CHILD_PID:-}" ]]; then
    kill "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

if [[ "$APP_TYPE" == "JavaFX" ]]; then
  echo "b4x-run: launching via Wine"
  echo "b4x-run:   java=$JAVA_EXE_VAL"
  echo "b4x-run:   javafx-lib=$JAVAFX_LIB_VAL"
  echo "b4x-run:   javafx-modules=$JAVAFX_MODULES_VAL"
  # shellcheck disable=SC2086
  CMD=(env WINEPREFIX="$WINEPREFIX_VAL" wine "$JAVA_EXE_VAL"
       --module-path "$JAVAFX_LIB_VAL"
       --add-modules "$JAVAFX_MODULES_VAL"
       $JAVA_OPTS_VAL
       -jar "$JAR")
else
  # shellcheck disable=SC2086
  CMD=(java $JAVA_OPTS_VAL -jar "$JAR")
fi

if [[ "$TIMEOUT_VAL" -gt 0 ]]; then
  "${CMD[@]}" &
  CHILD_PID=$!
  # `timeout` on the outer wrapper gives us a guaranteed kill.
  ( sleep "$TIMEOUT_VAL"; kill "$CHILD_PID" 2>/dev/null || true ) &
  KILLER=$!
  wait "$CHILD_PID" || true
  kill "$KILLER" 2>/dev/null || true
else
  exec "${CMD[@]}"
fi
