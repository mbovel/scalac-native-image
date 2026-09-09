#!/usr/bin/env bash
#
# Build the native scalac from a compiler classpath.
#
# This is the single definition of the build flow. The Dockerfile's `nativebuild`
# stage runs it, and so do the macOS and Windows CI jobs, which cannot use Docker
# because native-image only ever targets the machine it runs on.
#
# Produces <out-dir>/{scalac[.exe], java.base.jar, lib/*.jar}. The three must stay
# together: ScalacMain locates the jars next to the executable at run time.
#
# Usage:
#   build-native.sh --cp-dir DIR --lib-dir DIR --out-dir DIR [options]
#
#   --cp-dir DIR         compiler jars; the native-image build classpath
#   --lib-dir DIR        Scala library jars, bundled as the default -classpath
#   --out-dir DIR        where to write the bundle
#   --macros true|false  macro support; costs build time and image size (default false)
#   --java-base-jar P    reuse a prebuilt java.base.jar instead of extracting one
#   --work-dir DIR       scratch directory (default: a temporary one)
#   --ni-opt OPTS        optimisation flags (default -O3; NOT -march=native, see README)
#   --xmx SIZE           native-image heap bound (default 16g)
#   --parallelism N      native-image threads (default: CPU count)
#   --name NAME          executable name without extension (default scalac)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/scripts/common.sh"

CP_DIR= LIB_DIR= OUT_DIR= JAVA_BASE_JAR= WORK_DIR=
MACROS=false
NI_OPT="-O3"
NI_XMX=16g
NI_PARALLELISM=
NAME=scalac

die() { echo "build-native.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cp-dir)        CP_DIR="$2"; shift 2 ;;
    --lib-dir)       LIB_DIR="$2"; shift 2 ;;
    --out-dir)       OUT_DIR="$2"; shift 2 ;;
    --macros)        MACROS="$2"; shift 2 ;;
    --java-base-jar) JAVA_BASE_JAR="$2"; shift 2 ;;
    --work-dir)      WORK_DIR="$2"; shift 2 ;;
    --ni-opt)        NI_OPT="$2"; shift 2 ;;
    --xmx)           NI_XMX="$2"; shift 2 ;;
    --parallelism)   NI_PARALLELISM="$2"; shift 2 ;;
    --name)          NAME="$2"; shift 2 ;;
    -h|--help)       sed -n '2,26p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

[ -d "${CP_DIR:-}" ]  || die "--cp-dir must be an existing directory"
[ -d "${LIB_DIR:-}" ] || die "--lib-dir must be an existing directory"
[ -n "${OUT_DIR:-}" ] || die "--out-dir is required"
case "$MACROS" in true|false) ;; *) die "--macros must be true or false" ;; esac
: "${JAVA_HOME:?JAVA_HOME must be set}"
[ -n "$NI_PARALLELISM" ] || NI_PARALLELISM="$(cpu_count)"

if [ -n "$WORK_DIR" ]; then
  mkdir -p "$WORK_DIR"
else
  WORK_DIR="$(mktemp -d)"
  trap 'rm -rf "$WORK_DIR"' EXIT
fi
mkdir -p "$OUT_DIR/lib"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

CP="$(jars_cp "$CP_DIR")"
LIB="$(jars_cp "$LIB_DIR")"

# ---------------------------------------------------------------------------
# 1. JDK classes as a jar, for -bootclasspath (see jdk-classes.sh for why).
# ---------------------------------------------------------------------------
if [ -n "$JAVA_BASE_JAR" ]; then
  cp "$JAVA_BASE_JAR" "$OUT_DIR/java.base.jar"
else
  bash "$ROOT/scripts/jdk-classes.sh" "$OUT_DIR/java.base.jar"
fi

# ---------------------------------------------------------------------------
# 2. The wrapper main class that supplies -bootclasspath and -classpath.
# ---------------------------------------------------------------------------
log "compiling ScalacMain"
mkdir -p "$WORK_DIR/classes"
javac -cp "$CP" -d "$(jpath "$WORK_DIR/classes")" "$(jpath "$ROOT/ScalacMain.java")"

# ---------------------------------------------------------------------------
# 3. Reachability metadata, recorded by compiling a sample under the tracing
#    agent. dotc loads classes and resources reflectively; without this the
#    image is missing lazy-val fields, the backend's BTypes, compiler.properties.
# ---------------------------------------------------------------------------
log "recording reachability metadata (tracing agent)"
mkdir -p "$WORK_DIR/ni-config" "$WORK_DIR/trainout"
java "-agentlib:native-image-agent=config-output-dir=$(jpath "$WORK_DIR/ni-config")" \
     -cp "$CP" dotty.tools.dotc.Main \
     -classpath "$LIB" \
     -d "$(jpath "$WORK_DIR/trainout")" \
     "$(jpath "$ROOT/train/Train.scala")"

# ---------------------------------------------------------------------------
# 4. Macro support (see README): runtime class loading needs (a) the flag,
#    (b) every library/compiler class registered so parent delegation returns
#    the image's own class instead of defining a second copy, and (c) members
#    preserved so the interpreter can call into AOT-compiled code.
# ---------------------------------------------------------------------------
CONFIG_DIR="$WORK_DIR/ni-config"
NI_EXTRA=()
if [ "$MACROS" = true ]; then
  [ -n "$PYTHON" ] || die "--macros true needs python3 to generate reflection metadata"
  log "registering every compiler class for reflection"
  "$PYTHON" "$ROOT/gen-reflect-metadata.py" "$CP_DIR" "$WORK_DIR/ni-config" "$WORK_DIR/ni-config-macros"
  CONFIG_DIR="$WORK_DIR/ni-config-macros"

  scalalib="$(find "$CP_DIR" -name 'scala-library-*.jar' | sort | head -1)"
  [ -n "$scalalib" ] || die "no scala-library jar in $CP_DIR"
  NI_EXTRA=(
    -H:+UnlockExperimentalVMOptions
    -H:+RuntimeClassLoading
    "-H:Preserve=path=$(jpath "$scalalib"),package=java.lang.invoke,package=java.util.concurrent,package=java.util,package=java.lang"
  )
fi

# ---------------------------------------------------------------------------
# 5. The image itself.
# ---------------------------------------------------------------------------
log "native-image (macros=$MACROS, xmx=$NI_XMX, parallelism=$NI_PARALLELISM)"

# The entry point lives in $WORK_DIR/classes, and losing that one classpath entry is a confusing
# failure ("Main entry point class 'ScalacMain' neither found on classpath ... nor modulepath"),
# so check for it here instead.
[ -f "$WORK_DIR/classes/ScalacMain.class" ] || die "ScalacMain.class missing from $WORK_DIR/classes"

# Arguments go through an argument file rather than the command line.
#
# On Windows the launcher is native-image.cmd, so every argument travels through cmd.exe, which
# splits on the semicolons that a Windows classpath is made of. That silently dropped the last
# -cp entry -- $WORK_DIR/classes, and with it ScalacMain -- while leaving the eight compiler jars
# intact. An argument file is read by the driver itself, so neither the shell nor cmd.exe gets to
# reinterpret anything. Every path in it comes from jpath, hence forward slashes, which also keeps
# the argfile parser from treating backslashes as escapes.
ARGFILE="$WORK_DIR/native-image.args"
{
  printf '%s\n' "-cp" "$CP$CPSEP$(jpath "$WORK_DIR/classes")"
  printf '%s\n' "-H:ConfigurationFileDirectories=$(jpath "$CONFIG_DIR")"
  printf '%s\n' "--no-fallback"
  # shellcheck disable=SC2086  # NI_OPT is deliberately a word-split option string
  for opt in $NI_OPT; do printf '%s\n' "$opt"; done
  for opt in ${NI_EXTRA[@]+"${NI_EXTRA[@]}"}; do printf '%s\n' "$opt"; done
  printf '%s\n' "-J-Xmx$NI_XMX" "--parallelism=$NI_PARALLELISM"
  printf '%s\n' "-o" "$(jpath "$OUT_DIR/$NAME")"
  printf '%s\n' "ScalacMain"
} > "$ARGFILE"
"$NATIVE_IMAGE_CMD" "@$(jpath "$ARGFILE")"

# ---------------------------------------------------------------------------
# 6. Bundle: the Scala library the produced compiler hands to user code.
# ---------------------------------------------------------------------------
find "$LIB_DIR" -name '*.jar' -exec cp {} "$OUT_DIR/lib/" \;

log "built $OUT_DIR/$NAME$EXE_SUFFIX"
ls -la "$OUT_DIR"
