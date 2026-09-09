#!/usr/bin/env bash
#
# Cold and warm evaluation of the native scalac against the JVM, over four configurations:
#
#   jvm             java -cp <compiler jars> dotty.tools.dotc.Main
#   jvm-aot         the same, with a JDK 25 AOT cache (JEP 483/514/515) trained per benchmark
#   native-O3       the :slim image -- native-image -O3, closed world
#   native-rcl-O3   the :macros image -- native-image -O3 with -H:+RuntimeClassLoading
#
#   cold = best of N fresh processes
#   warm = min of the last K of M iterations compiled in one process
#
# Every configuration compiles the same sources with the same flags, and every configuration's
# output is diffed against the JVM's, because a native image that is missing reachability
# metadata still "succeeds" while emitting class files that fail verification. A time is only
# reported for a run that exited zero AND produced byte-identical output.
#
# Usage:
#   bench/eval.sh                                  # build both images, run the full evaluation
#   bench/eval.sh --quick                          # the CI dry run
#   bench/eval.sh --slim DIR --rcl DIR             # reuse bundles exported earlier
#
# Options:
#   --slim DIR           bundle for the closed-world image (default: docker build --target artifact)
#   --rcl DIR            bundle for the RuntimeClassLoading image (default: likewise, MACROS=true)
#   --cp-dir DIR         compiler jars for the JVM configurations (default: fetch with coursier)
#   --scala-version V    compiler version to fetch and to build the images from (default 3.9.0)
#   --bench-sources DIR  scala3-benchmarks/bench-sources (default: clone at the pinned commit)
#   --benchmarks LIST    comma-separated subset of the names below
#   --reps N             cold repetitions, best of (default 3)
#   --iterations M       in-process iterations for the warm measurement (default 12)
#   --warm-tail K        warm time is the min of the last K iterations (default 5)
#   --skip-cold          / --skip-warm
#   --quick              helloWorld,sourcecode with 1 rep and 3 iterations: proves the script runs
#   --work-dir DIR       scratch (default: a temporary directory, removed on exit)
#   --out FILE           write the Markdown report here as well as to stdout
set -uo pipefail

# declare -A and mapfile: bash 4. macOS ships 3.2 as /bin/bash, so `brew install bash` there.
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "eval.sh needs bash 4 or newer" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../docker/scripts/common.sh
. "$ROOT/docker/scripts/common.sh"

# The benchmark corpus, pinned so the numbers mean something across machines and dates.
BENCH_REPO=https://github.com/lampepfl/scala3-benchmarks.git
BENCH_REF=99ac20c5476e16dd70037ddd0c0f4d17e894c694

SCALA_VERSION=3.9.0
SLIM_DIR= RCL_DIR= CP_DIR= BENCH_SRC= WORK_DIR= OUT_FILE=
BENCHMARKS=helloWorld,dottyUtil,re2s,tastyQuery,sourcecode
REPS=3 ITERATIONS=12 WARM_TAIL=5
DO_COLD=1 DO_WARM=1

die() { echo "eval.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --slim)          SLIM_DIR="$2"; shift 2 ;;
    --rcl)           RCL_DIR="$2"; shift 2 ;;
    --cp-dir)        CP_DIR="$2"; shift 2 ;;
    --scala-version) SCALA_VERSION="$2"; shift 2 ;;
    --bench-sources) BENCH_SRC="$2"; shift 2 ;;
    --benchmarks)    BENCHMARKS="$2"; shift 2 ;;
    --reps)          REPS="$2"; shift 2 ;;
    --iterations)    ITERATIONS="$2"; shift 2 ;;
    --warm-tail)     WARM_TAIL="$2"; shift 2 ;;
    --skip-cold)     DO_COLD=0; shift ;;
    --skip-warm)     DO_WARM=0; shift ;;
    --quick)         BENCHMARKS=helloWorld,sourcecode; REPS=1; ITERATIONS=3; WARM_TAIL=1; shift ;;
    --work-dir)      WORK_DIR="$2"; shift 2 ;;
    --out)           OUT_FILE="$2"; shift 2 ;;
    -h|--help)       sed -n '2,36p' "$0"; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

[ "$WARM_TAIL" -le "$ITERATIONS" ] || die "--warm-tail ($WARM_TAIL) exceeds --iterations ($ITERATIONS)"
command -v java >/dev/null 2>&1 || die "java must be on PATH"

if [ -n "$WORK_DIR" ]; then mkdir -p "$WORK_DIR"; else
  WORK_DIR="$(mktemp -d)"; trap 'rm -rf "$WORK_DIR"' EXIT
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
LOGS="$WORK_DIR/logs"; RUN="$WORK_DIR/run"; HARNESS="$WORK_DIR/harness"
mkdir -p "$LOGS" "$RUN" "$HARNESS" "$WORK_DIR/aot"

# ---------------------------------------------------------------------------
# Inputs: compiler jars, the two bundles, the benchmark corpus.
# ---------------------------------------------------------------------------
if [ -z "$CP_DIR" ]; then
  command -v cs >/dev/null 2>&1 || die "coursier (cs) not on PATH; pass --cp-dir instead"
  bash "$ROOT/docker/scripts/fetch-compiler.sh" "$SCALA_VERSION" "$WORK_DIR/cp" "$WORK_DIR/lib" >/dev/null
  CP_DIR="$WORK_DIR/cp"; LIB_DIR="$WORK_DIR/lib"
else
  CP_DIR="$(cd "$CP_DIR" && pwd)"
  # The Scala library is the default -classpath the native bundles hand to user code; the JVM
  # configurations must be given exactly the same one, or they are not compiling the same thing.
  LIB_DIR="$WORK_DIR/lib"; mkdir -p "$LIB_DIR"
  find "$CP_DIR" \( -name 'scala-library-*.jar' -o -name 'scala3-library_3-*.jar' \) \
    -exec cp {} "$LIB_DIR/" \;
fi
CP="$(jars_cp "$CP_DIR")" || die "no compiler jars in $CP_DIR"
LIBCP="$(jars_cp "$LIB_DIR")" || die "no Scala library jars found"

build_bundle() { # build_bundle <macros true|false> <dest>
  log "docker build --target artifact (MACROS=$1)"
  docker build --target artifact --output "type=local,dest=$2" \
    --build-arg "SCALA_VERSION=$SCALA_VERSION" --build-arg "MACROS=$1" \
    "$ROOT/docker" >"$LOGS/build-$1.log" 2>&1 \
    || { tail -30 "$LOGS/build-$1.log" >&2; die "docker build failed (MACROS=$1)"; }
}
[ -n "$SLIM_DIR" ] || { SLIM_DIR="$WORK_DIR/slim"; build_bundle false "$SLIM_DIR"; }
[ -n "$RCL_DIR" ]  || { RCL_DIR="$WORK_DIR/rcl";   build_bundle true  "$RCL_DIR"; }
SLIM_DIR="$(cd "$SLIM_DIR" && pwd)"; RCL_DIR="$(cd "$RCL_DIR" && pwd)"
for d in "$SLIM_DIR" "$RCL_DIR"; do
  [ -x "$d/scalac$EXE_SUFFIX" ] || die "no scalac$EXE_SUFFIX in $d"
done

if [ -z "$BENCH_SRC" ]; then
  log "cloning scala3-benchmarks at $BENCH_REF"
  git clone -q "$BENCH_REPO" "$WORK_DIR/scala3-benchmarks" \
    && git -C "$WORK_DIR/scala3-benchmarks" checkout -q "$BENCH_REF" \
    || die "could not fetch the benchmark corpus; pass --bench-sources instead"
  BENCH_SRC="$WORK_DIR/scala3-benchmarks/bench-sources"
  CORPUS_DESC="scala3-benchmarks \`${BENCH_REF:0:12}\`"
else
  CORPUS_DESC="$BENCH_SRC (supplied with --bench-sources)"
fi
BENCH_SRC="$(cd "$BENCH_SRC" && pwd)"
[ -d "$BENCH_SRC/small" ] || die "$BENCH_SRC does not look like scala3-benchmarks/bench-sources"

# The Loop harness for the JVM configurations. A jar, not a directory: the AOT cache refuses a
# non-empty directory anywhere on the classpath ("Cannot have non-empty directory in paths").
javac -cp "$CP" -d "$HARNESS/classes" "$(jpath "$ROOT/bench/Loop.java")" \
  || die "could not compile the Loop harness"
( cd "$HARNESS/classes" && jar --create --file "$(jpath "$HARNESS/loop.jar")" . ) \
  || die "could not package the Loop harness"
LOOP_JAR="$HARNESS/loop.jar"

# ---------------------------------------------------------------------------
# The corpus. Same selections and flags as scala3-benchmarks' own build.sbt.
# ---------------------------------------------------------------------------
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")

srcs_of() {
  case "$1" in
    helloWorld) echo "$BENCH_SRC/small/helloWorld.scala" ;;
    dottyUtil)  find "$BENCH_SRC/dottyUtil" -name '*.scala' | sort ;;
    re2s)       find "$BENCH_SRC/re2s" -name '*.scala' | sort ;;
    tastyQuery) find "$BENCH_SRC/tastyQuery/tasty-query" -name '*.scala' | sort ;;
    sourcecode) find "$BENCH_SRC/sourcecode/src" "$BENCH_SRC/sourcecode/src-3" \
                     "$BENCH_SRC/sourcecode/test/src" "$BENCH_SRC/sourcecode/test/src-3" \
                     -name '*.scala' | sort ;;
    *) die "unknown benchmark: $1" ;;
  esac
}
# tastyQuery is the one benchmark its build.sbt compiles with extra flags.
extra_of() { [ "$1" = tastyQuery ] && printf '%s\n%s\n' -Yexplicit-nulls '-Wconf:msg=Unnecessary .nn:s'; }

# Benchmarks whose sources expand macros. A closed-world image cannot load and run a macro
# implementation's class file, so native-O3 is *expected* to fail on these -- that is the
# documented difference between the two flavours, not a regression. Every other configuration,
# native-rcl-O3 included, must still compile them correctly.
MACRO_BENCHMARKS=" sourcecode "
is_macro_bench() { case "$MACRO_BENCHMARKS" in *" $1 "*) return 0 ;; esac; return 1; }

IFS=, read -ra NAMES <<< "$BENCHMARKS"
LABELS=(jvm jvm-aot native-O3 native-rcl-O3)

# The command that runs the compiler once, for a configuration. The native bundles supply their
# own -bootclasspath and default -classpath; -classpath below overrides the latter for all four.
cmd_of() { # cmd_of <label> <benchmark> -> argv on stdout, one word per line
  case "$1" in
    jvm)           printf '%s\n' java -cp "$CP" dotty.tools.dotc.Main ;;
    jvm-aot)       printf '%s\n' java "-XX:AOTCache=$WORK_DIR/aot/$2-cold.aot" -cp "$CP" dotty.tools.dotc.Main ;;
    native-O3)     printf '%s\n' "$SLIM_DIR/scalac$EXE_SUFFIX" ;;
    native-rcl-O3) printf '%s\n' "$RCL_DIR/scalac$EXE_SUFFIX" ;;
  esac
}
# Same, for the in-process loop: the JVM goes through Loop, the images through their own hook.
loop_cmd_of() {
  case "$1" in
    jvm)           printf '%s\n' java -cp "$CP$CPSEP$LOOP_JAR" Loop "$ITERATIONS" ;;
    jvm-aot)       printf '%s\n' java "-XX:AOTCache=$WORK_DIR/aot/$2-warm.aot" -cp "$CP$CPSEP$LOOP_JAR" Loop "$ITERATIONS" ;;
    native-O3)     printf '%s\n' "$SLIM_DIR/scalac$EXE_SUFFIX" ;;
    native-rcl-O3) printf '%s\n' "$RCL_DIR/scalac$EXE_SUFFIX" ;;
  esac
}

# ---------------------------------------------------------------------------
# Timing. Bash's own `time` rather than /usr/bin/time, which is GNU-only.
# ---------------------------------------------------------------------------
TIMEFORMAT='%3R'
LAST_RC=0
timed() { # timed <logfile> <argv...> -> elapsed seconds on stdout, exit status in LAST_RC
  local log="$1"; shift
  local rc="$log.rc" t
  t=$( { time { "$@" >"$log" 2>&1; printf '%s' "$?" >"$rc"; }; } 2>&1 )
  LAST_RC="$(cat "$rc" 2>/dev/null || echo 1)"; rm -f "$rc"
  printf '%s' "$t"
}
min2() { awk -v a="$1" -v b="$2" 'BEGIN{ if (a == "" || b+0 < a+0) print b; else print a }'; }

# Everything runs from a clean directory. With -H:+RuntimeClassLoading the real module system is
# active at run time, and a stray jar whose classes are in the default package -- loop.jar, for
# instance -- breaks startup with "Unable to derive module descriptor". Hence HARNESS != RUN.
cd "$RUN" || die "cannot enter $RUN"

declare -A COLD WARM ITER0 STATUS

# ---------------------------------------------------------------------------
# AOT caches. Trained per benchmark on that same benchmark, which is the best case for the JVM.
# Two of them: a single-shot run for the cold measurement, one Loop iteration for the warm one.
# ---------------------------------------------------------------------------
AOT_OK=0
java -XX:+PrintFlagsFinal -version 2>/dev/null | grep -q ' AOTCacheOutput ' && AOT_OK=1
[ "$AOT_OK" = 1 ] || log "this JVM has no AOT cache (JDK 24+); skipping jvm-aot"

if [ "$AOT_OK" = 1 ]; then
  for name in "${NAMES[@]}"; do
    mapfile -t SRCS < <(srcs_of "$name"); mapfile -t X < <(extra_of "$name")
    for kind in cold warm; do
      rm -rf "$RUN/train"; mkdir -p "$RUN/train"
      if [ "$kind" = cold ]; then
        pre=(java "-XX:AOTCacheOutput=$WORK_DIR/aot/$name-cold.aot" -cp "$CP" dotty.tools.dotc.Main)
      else
        pre=(java "-XX:AOTCacheOutput=$WORK_DIR/aot/$name-warm.aot" -cp "$CP$CPSEP$LOOP_JAR" Loop 1)
      fi
      "${pre[@]}" -classpath "$LIBCP" "${SHARED[@]}" ${X[@]+"${X[@]}"} \
        -d train "${SRCS[@]}" >"$LOGS/aot-$name-$kind.log" 2>&1
      # -XX:AOTCacheOutput trains in one JVM and then forks a second to assemble the cache. The
      # parent exits as soon as it has handed over, so the 50-75 MB file is often still being
      # written when the training command returns. Wait for it to land, and for the temporary
      # configuration beside it to be cleaned up, before deciding the cache is missing.
      cache="$WORK_DIR/aot/$name-$kind.aot"
      for _ in $(seq 1 180); do
        [ -s "$cache" ] && [ ! -e "$cache.config" ] && break
        sleep 1
      done
      # A benchmark the JVM itself cannot compile cleanly leaves no cache. jvm-aot is then
      # skipped for that benchmark rather than aborting the whole run.
      [ -s "$cache" ] || log "no $kind AOT cache for $name (see logs/aot-$name-$kind.log)"
    done
    log "AOT caches for $name: $(du -m "$WORK_DIR/aot/$name-"*.aot 2>/dev/null | awk '{s+=$1} END{print s+0}') MB"
  done
fi

# ---------------------------------------------------------------------------
# Cold: best of REPS fresh processes.
# ---------------------------------------------------------------------------
if [ "$DO_COLD" = 1 ]; then
  log "cold: best of $REPS fresh processes"
  for name in "${NAMES[@]}"; do
    mapfile -t SRCS < <(srcs_of "$name"); mapfile -t X < <(extra_of "$name")
    for label in "${LABELS[@]}"; do
      key="$name/$label"
      if [ "$label" = jvm-aot ] && { [ "$AOT_OK" = 0 ] || [ ! -s "$WORK_DIR/aot/$name-cold.aot" ]; }; then
        COLD[$key]=n/a; STATUS[$key]=skipped; continue
      fi
      mapfile -t C < <(cmd_of "$label" "$name")
      out="out-$name-$label"; best=""
      for i in $(seq 1 "$REPS"); do
        rm -rf "$out"; mkdir -p "$out"
        t="$(timed "$LOGS/cold-$name-$label-$i.log" "${C[@]}" \
              -classpath "$LIBCP" "${SHARED[@]}" ${X[@]+"${X[@]}"} -d "$out" "${SRCS[@]}")"
        [ "$LAST_RC" = 0 ] && best="$(min2 "$best" "$t")"
      done
      if [ -z "$best" ]; then COLD[$key]=fail; STATUS[$key]=fail
      else COLD[$key]="$best"; STATUS[$key]=ok; fi
    done

    # Correctness: every configuration's class files and TASTy against the JVM's.
    for label in "${LABELS[@]}"; do
      key="$name/$label"
      [ "$label" = jvm ] && continue
      [ "${STATUS[$key]}" = ok ] || continue
      if diff -rq "out-$name-jvm" "out-$name-$label" >/dev/null 2>&1; then
        STATUS[$key]=identical
      else
        STATUS[$key]=DIFFERS
      fi
    done
    # The closed-world image on macro code: it emits the macro-defining class files, errors on
    # every use site, and does so quickly. Reporting that as a time would be flattering nonsense.
    if is_macro_bench "$name"; then
      key="$name/native-O3"
      case "${STATUS[$key]}" in DIFFERS|fail) STATUS[$key]=no-macros; COLD[$key]=n/a ;; esac
    fi
    printf '  %-11s %s\n' "$name" \
      "$(for l in "${LABELS[@]}"; do printf '%s=%s(%s) ' "$l" "${COLD[$name/$l]}" "${STATUS[$name/$l]}"; done)"
  done
fi

# ---------------------------------------------------------------------------
# Warm: ITERATIONS compiles in one process, min of the last WARM_TAIL.
# ---------------------------------------------------------------------------
if [ "$DO_WARM" = 1 ]; then
  log "warm: $ITERATIONS in-process iterations, min of the last $WARM_TAIL"
  for name in "${NAMES[@]}"; do
    mapfile -t SRCS < <(srcs_of "$name"); mapfile -t X < <(extra_of "$name")
    for label in "${LABELS[@]}"; do
      key="$name/$label"
      if [ "$label" = jvm-aot ] && { [ "$AOT_OK" = 0 ] || [ ! -s "$WORK_DIR/aot/$name-warm.aot" ]; }; then
        WARM[$key]=n/a; ITER0[$key]=n/a; continue
      fi
      mapfile -t C < <(loop_cmd_of "$label" "$name")
      out="w-$name-$label"; rm -rf "$out"; mkdir -p "$out"
      lg="$LOGS/warm-$name-$label.log"
      case "$label" in
        native-*) SCALAC_BENCH_ITERATIONS="$ITERATIONS" "${C[@]}" \
                    -classpath "$LIBCP" "${SHARED[@]}" ${X[@]+"${X[@]}"} -d "$out" "${SRCS[@]}" >"$lg" 2>&1 ;;
        *)        "${C[@]}" \
                    -classpath "$LIBCP" "${SHARED[@]}" ${X[@]+"${X[@]}"} -d "$out" "${SRCS[@]}" >"$lg" 2>&1 ;;
      esac
      mapfile -t MS < <(sed -n 's/^iter [0-9]*: \([0-9]*\) ms.*/\1/p' "$lg")
      # Both harnesses tag an iteration that reported errors. A compile that gave up is fast and
      # meaningless, so it gets no number.
      if [ "${STATUS[$key]:-}" = no-macros ]; then
        WARM[$key]=n/a; ITER0[$key]=n/a
      elif grep -q '\[ERRORS\]' "$lg" || [ "${#MS[@]}" -lt "$ITERATIONS" ]; then
        WARM[$key]=fail; ITER0[$key]=fail
      else
        ITER0[$key]="${MS[0]}"
        WARM[$key]="$(printf '%s\n' "${MS[@]: -$WARM_TAIL}" | sort -n | head -1)"
      fi
    done
    printf '  %-11s %s\n' "$name" \
      "$(for l in "${LABELS[@]}"; do printf '%s=%sms ' "$l" "${WARM[$name/$l]}"; done)"
  done
fi

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
cell() { # cell <value> <suffix>
  case "$1" in
    ''|fail) printf 'fail' ;;
    n/a)     printf 'n/a' ;;
    *)       printf '%s%s' "$1" "$2" ;;
  esac
}

report() {
  echo "## Evaluation"
  echo
  echo "- compiler: Scala $SCALA_VERSION"
  echo "- corpus: $CORPUS_DESC, same source selections and flags as its \`build.sbt\`"
  echo "- host: $(uname -s) $(uname -m), $(cpu_count) CPUs"
  echo "- \`java -version\`: $(java -version 2>&1 | head -1 | tr -d '\r')"
  echo "- cold: best of $REPS fresh processes. warm: min of the last $WARM_TAIL of $ITERATIONS in-process iterations."
  echo "- \"identical\" means the emitted class files and TASTy are byte-for-byte the JVM's."
  echo

  if [ "$DO_COLD" = 1 ]; then
    echo "### Cold"
    echo
    echo "| benchmark | jvm | jvm-aot | native-O3 | native-rcl-O3 | output |"
    echo "|---|---:|---:|---:|---:|---|"
    for name in "${NAMES[@]}"; do
      eq=""
      for l in native-O3 native-rcl-O3; do
        case "${STATUS[$name/$l]}" in
          identical) eq="$eq${eq:+, }$l identical" ;;
          DIFFERS)   eq="$eq${eq:+, }**$l DIFFERS**" ;;
          fail)      eq="$eq${eq:+, }**$l fail**" ;;
          no-macros) eq="$eq${eq:+, }$l cannot expand macros (expected)" ;;
        esac
      done
      printf '| %s | %s | %s | %s | %s | %s |\n' "$name" \
        "$(cell "${COLD[$name/jvm]}" s)" "$(cell "${COLD[$name/jvm-aot]}" s)" \
        "$(cell "${COLD[$name/native-O3]}" s)" "$(cell "${COLD[$name/native-rcl-O3]}" s)" "$eq"
    done
    echo
  fi

  if [ "$DO_WARM" = 1 ]; then
    echo "### Warm"
    echo
    echo "| benchmark | jvm | jvm-aot | native-O3 | native-rcl-O3 | iter 0 (jvm/aot/native/rcl) |"
    echo "|---|---:|---:|---:|---:|---|"
    for name in "${NAMES[@]}"; do
      printf '| %s | %s | %s | %s | %s | %s / %s / %s / %s |\n' "$name" \
        "$(cell "${WARM[$name/jvm]}" ms)" "$(cell "${WARM[$name/jvm-aot]}" ms)" \
        "$(cell "${WARM[$name/native-O3]}" ms)" "$(cell "${WARM[$name/native-rcl-O3]}" ms)" \
        "${ITER0[$name/jvm]}" "${ITER0[$name/jvm-aot]}" \
        "${ITER0[$name/native-O3]}" "${ITER0[$name/native-rcl-O3]}"
    done
    echo
  fi
}

echo
report | tee "${OUT_FILE:-/dev/null}"

# What counts as a failed evaluation rather than merely a slow one:
#
#   DIFFERS anywhere     a native image is silently miscompiling. This is the failure the whole
#                        exercise exists to catch, and the reason every run is diffed.
#   any config fails     including the JVM itself, which would mean the flags are wrong.
#
# The one exception is `no-macros`: native-O3 giving up on a benchmark in MACRO_BENCHMARKS is the
# documented difference between the two flavours, not a regression. native-O3 failing on anything
# else still is one. `skipped` (no AOT cache on this JVM) is not a failure either.
rc=0
for k in "${!STATUS[@]}"; do
  case "${STATUS[$k]}" in
    DIFFERS) echo "eval.sh: $k output differs from the JVM's; see $LOGS" >&2; rc=1 ;;
    fail)    echo "eval.sh: $k failed to compile; see $LOGS" >&2; rc=1 ;;
  esac
done
exit "$rc"
