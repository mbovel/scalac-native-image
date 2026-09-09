#!/usr/bin/env bash
# What did RuntimeClassLoading + Preserve cost us?
# Isolate it at each optimization level:
#   native      (-O2, no RCL)  vs  native-rcl      (-O2, RCL+Preserve)
#   native-O3   (-O3 -march)   vs  native-rcl-O3   (-O3 -march, RCL+Preserve)
# jvm for reference. Runs from a clean cwd (RCL scans the working dir as a module path).
set -uo pipefail
R="$(cd "$(dirname "$0")" && pwd)"
WORK="${SCRATCH:-/tmp}/bench7"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"; cp "$R/java.base.jar" .
CP="$(cat $R/cp.txt)"; LIBCP="$(cat $R/libcp.txt)"; B=$R/scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
labels=(jvm native native-rcl native-O3 native-rcl-O3)
names=(helloWorld dottyUtil re2s tastyQuery sourcecode)
srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
  sourcecode) find $B/sourcecode/src $B/sourcecode/src-3 $B/sourcecode/test/src $B/sourcecode/test/src-3 -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }
cmd_for() { case $1 in
  jvm)           echo "java|-cp|$CP|dotty.tools.dotc.Main";;
  native)        echo "$R/scalac-native|-bootclasspath|java.base.jar";;
  native-rcl)    echo "$R/scalac-native-rcl4|-bootclasspath|java.base.jar";;
  native-O3)     echo "$R/scalac-native-O3|-bootclasspath|java.base.jar";;
  native-rcl-O3) echo "$R/scalac-native-rcl4-O3|-bootclasspath|java.base.jar";;
esac; }

printf '%-11s %9s %9s %11s %10s %13s\n' bench jvm native native-rcl native-O3 native-rcl-O3
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  declare -A T=() M=()
  for label in "${labels[@]}"; do
    IFS='|' read -ra C <<< "$(cmd_for $label)"
    best=999; ok=0; rss=()
    for i in 1 2 3; do
      out="o-$name-$label"; rm -rf "$out"; mkdir -p "$out"
      /usr/bin/time -f "%e %M" -o tt "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" \
        -d "$out" "${SRCS[@]}" > "log-$name-$label" 2>&1
      read -r t m < <(tail -1 tt)
      [[ $(find "$out" -name '*.class' | wc -l) -gt 0 ]] && ok=1
      awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t
      rss+=("$m")
    done
    if [[ $ok == 1 ]]; then T[$label]=$best; M[$label]=$(( $(printf '%s\n' "${rss[@]}"|sort -n|head -1)/1024 ))
    else T[$label]=FAIL; M[$label]="-"; fi
  done
  printf '%-11s %8ss %8ss %10ss %9ss %12ss\n' "$name" \
    "${T[jvm]}" "${T[native]}" "${T[native-rcl]}" "${T[native-O3]}" "${T[native-rcl-O3]}"
  # correctness: every succeeding native config vs jvm
  eq=""
  for label in native native-rcl native-O3 native-rcl-O3; do
    if [[ ${T[$label]} == FAIL ]]; then eq+="$label=FAIL "
    elif diff -rq "o-$name-jvm" "o-$name-$label" >/dev/null 2>&1; then eq+="$label=identical "
    else eq+="$label=DIFFERS "; fi
  done
  echo "            RSS MB: ${M[jvm]}/${M[native]}/${M[native-rcl]}/${M[native-O3]}/${M[native-rcl-O3]}   $eq"
done
