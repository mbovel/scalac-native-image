#!/usr/bin/env bash
# Compile each scala3-benchmarks project with JVM dotc and with native dotc,
# using the same flags build.sbt uses, then compare outputs.
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"          # compiler classpath (for `java -cp`)
LIBCP="$(cat libcp.txt)"    # what sbt's dependencyClasspath is for these projects
B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")

srcs() { find "$@" -name '*.scala' -o -name '*.java' | sort; }

declare -A OPTS SRCS
SRCS[dottyUtil]="$(srcs $B/dottyUtil)";              OPTS[dottyUtil]=""
SRCS[re2s]="$(srcs $B/re2s)";                        OPTS[re2s]=""
SRCS[scalaz]="$(srcs $B/scalaz)";                    OPTS[scalaz]="-nowarn|-source|3.0|-Xkind-projector|-language:implicitConversions"
SRCS[tastyQuery]="$(srcs $B/tastyQuery/tasty-query)"; OPTS[tastyQuery]="-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s"
SRCS[sourcecode]="$(srcs $B/sourcecode/src $B/sourcecode/src-3 $B/sourcecode/test/src $B/sourcecode/test/src-3)"; OPTS[sourcecode]=""

run() { # run <name> <jvm|native>
  local name=$1 mode=$2 out=bench-out/$name-$mode
  local -a extra=()
  [[ -n "${OPTS[$name]}" ]] && IFS='|' read -ra extra <<< "${OPTS[$name]}"
  rm -rf "$out"; mkdir -p "$out"
  local -a cmd
  if [[ $mode == jvm ]]; then
    cmd=(java -Xms8G -Xmx8G -cp "$CP" dotty.tools.dotc.Main)
  else
    cmd=(./scalac-native -bootclasspath jdk-classes/java.base)
  fi
  /usr/bin/time -f "%e|%M" -o "$out.time" \
    "${cmd[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${extra[@]}" -d "$out" ${SRCS[$name]} \
    > "$out.log" 2>&1
  echo "exit=$? $(cat "$out.time")"
}

mkdir -p bench-out
for name in dottyUtil re2s sourcecode tastyQuery scalaz; do
  n=$(echo "${SRCS[$name]}" | wc -l)
  echo "======== $name ($n files) ========"
  for mode in jvm native; do
    IFS='|' read -r st tm rss <<< "$(run $name $mode | sed 's/exit=\([0-9]*\) /\1|/')"
    printf '  %-7s exit=%-3s %6ss  %6s MB  ' "$mode" "$st" "$tm" "$((rss/1024))"
    echo "$(find bench-out/$name-$mode -name '*.class' | wc -l) classfiles"
    tail -3 "bench-out/$name-$mode.log" | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/          | /'
  done
  if diff -r -q "bench-out/$name-jvm" "bench-out/$name-native" > /dev/null 2>&1; then
    echo "  ==> outputs BYTE-IDENTICAL"
  else
    echo "  ==> outputs DIFFER:"; diff -r -q "bench-out/$name-jvm" "bench-out/$name-native" 2>&1 | head -5 | sed 's/^/          /'
  fi
done
