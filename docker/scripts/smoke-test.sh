#!/usr/bin/env bash
#
# Check that a built scalac actually compiles Scala, rather than merely existing.
# Runs against either an exported bundle directory or a Docker image, so the CI
# jobs on all four platforms assert the same things.
#
# Compiling is not enough on its own: an image missing reachability metadata
# still builds and still "succeeds", but emits class files that fail
# verification. So every case runs the output on a JVM and checks what it prints.
#
# Usage:
#   smoke-test.sh --bundle DIR    [--macros true|false]
#   smoke-test.sh --docker IMAGE  [--macros true|false]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/scripts/common.sh"

BUNDLE= IMAGE= MACROS=false
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="$2"; shift 2 ;;
    --docker) IMAGE="$2";  shift 2 ;;
    --macros) MACROS="$2"; shift 2 ;;
    *) echo "smoke-test.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$BUNDLE" ] || [ -n "$IMAGE" ] || { echo "need --bundle or --docker" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The Scala library jars, on the host, so the compiler's output can be run on a
# JVM. For an image that means copying them out: the paths inside it mean
# nothing here.
if [ -n "$BUNDLE" ]; then
  BUNDLE="$(cd "$BUNDLE" && pwd)"
  LIB_CP="$(jars_cp "$BUNDLE/lib")"
else
  mkdir -p "$work/imglib"
  docker run --rm -v "$work/imglib:/dest" --entrypoint sh "$IMAGE" \
    -c 'cp /opt/scalac/lib/*.jar /dest/'
  LIB_CP="$(jars_cp "$work/imglib")"
fi

cp "$ROOT/test/"*.scala "$work/"
cd "$work"          # everything below uses bare relative paths, which keeps
                    # Git Bash from rewriting them on the way into a Windows exe

failed=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; failed=1; }

# Invoke the compiler under test, whichever form it came in.
scalac() {
  if [ -n "$BUNDLE" ]; then
    "$BUNDLE/scalac$EXE_SUFFIX" "$@"
  elif [ "$(uname -s)" = Linux ]; then
    # Match the runner's uid so the output files are not left root-owned.
    docker run --rm --user "$(id -u):$(id -g)" -v "$PWD:/src" -w /src "$IMAGE" "$@"
  else
    docker run --rm -v "$PWD:/src" -w /src "$IMAGE" "$@"
  fi
}

# Run a compiled main class and compare its output.
expect_run() {
  local outdir="$1" main="$2" want="$3" got
  if ! command -v java >/dev/null 2>&1; then
    printf '  skip  run %s (no java on PATH)\n' "$main"; return 0
  fi
  got="$(java -cp "$(jpath "$outdir")$CPSEP$LIB_CP" "$main" 2>&1)" || {
    printf '  FAIL  run %s: %s\n' "$main" "$got" >&2; failed=1; return 0; }
  if [ "$got" = "$want" ]; then pass "run $main"
  else fail "run $main: got '$got', want '$want'"; fi
}

log "smoke test (macros=$MACROS)"

# 1. The compiler starts and knows what it is.
if scalac -version 2>&1 | grep -q 'Scala compiler version'; then pass "-version"
else fail "-version did not print a version"; fi

# 2. Compile and run a hello world. This is the case that fails outright when
#    the JDK classes are missing from -bootclasspath (oracle/graal#8371).
mkdir -p out-hello
if scalac -d out-hello hello.scala; then pass "compile hello.scala"
else fail "compile hello.scala"; fi
expect_run out-hello hello 'hi 2,4,6'

# 3. A source that leans on the JDK, not just the Scala library.
mkdir -p out-jdk
if scalac -d out-jdk jdk.scala; then pass "compile jdk.scala"
else fail "compile jdk.scala"; fi
expect_run out-jdk jdk 'Map(a -> 1) WEDNESDAY'

# 4. Errors must be reported and must set a non-zero exit status.
if scalac -d out-hello bad.scala >err.txt 2>&1; then
  fail "bad.scala compiled successfully"
elif grep -q 'Not found: undefinedName' err.txt; then pass "error reporting"
else fail "error reporting: unexpected output: $(cat err.txt)"; fi

# 5. Macros, for the flavour that claims to support them. The slim image emits
#    the macro-defining class files and then fails on the use site, so this is
#    the one test that separates the two builds.
if [ "$MACROS" = true ]; then
  mkdir -p out-macro
  if scalac -d out-macro Macro.scala UseMacro.scala; then pass "compile macros"
  else fail "compile macros"; fi
  expect_run out-macro useMacro 'add(n, 1) List(x, y, z)'
else
  if scalac -d out-macro-slim Macro.scala UseMacro.scala >mac.txt 2>&1; then
    fail "slim build unexpectedly compiled a macro use site"
  else pass "macro use site rejected, as expected for this flavour"; fi
fi

if [ "$failed" = 0 ]; then log "all smoke tests passed"; else log "SMOKE TESTS FAILED"; fi
exit "$failed"
