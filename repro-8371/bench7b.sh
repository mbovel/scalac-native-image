#!/usr/bin/env bash
# sourcecode row only (the macro benchmark).
set -uo pipefail
R="$(cd "$(dirname "$0")" && pwd)"
WORK="${SCRATCH:-/tmp}/bench7b"; rm -rf "$WORK"; mkdir -p "$WORK"; cd "$WORK"; cp "$R/java.base.jar" .
CP="$(cat $R/cp.txt)"; LIBCP="$(cat $R/libcp.txt)"; B=$R/scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
SRCS=($(find $B/sourcecode/src $B/sourcecode/src-3 $B/sourcecode/test/src $B/sourcecode/test/src-3 -name '*.scala'|sort))
cmd_for() { case $1 in
  jvm)           echo "java|-cp|$CP|dotty.tools.dotc.Main";;
  native)        echo "$R/scalac-native|-bootclasspath|java.base.jar";;
  native-rcl)    echo "$R/scalac-native-rcl4|-bootclasspath|java.base.jar";;
  native-O3)     echo "$R/scalac-native-O3|-bootclasspath|java.base.jar";;
  native-rcl-O3) echo "$R/scalac-native-rcl4-O3|-bootclasspath|java.base.jar";;
esac; }
printf '%-11s %9s %9s %11s %10s %13s\n' bench jvm native native-rcl native-O3 native-rcl-O3
declare -A T=() M=()
for label in jvm native native-rcl native-O3 native-rcl-O3; do
  IFS='|' read -ra C <<< "$(cmd_for $label)"
  best=999; ok=0; rss=()
  for i in 1 2 3; do
    out="o-$label"; rm -rf "$out"; mkdir -p "$out"
    /usr/bin/time -f "%e %M" -o tt "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" -d "$out" "${SRCS[@]}" > "log-$label" 2>&1
    read -r t m < <(tail -1 tt)
    if [[ $(find "$out" -name '*.class'|wc -l) -gt 0 ]]; then ok=1
       awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t; rss+=("$m"); fi
  done
  if [[ $ok == 1 ]]; then T[$label]=$best; M[$label]=$(( $(printf '%s\n' "${rss[@]}"|sort -n|head -1)/1024 ))
  else T[$label]=FAIL; M[$label]="-"; fi
done
printf '%-11s %8ss %8ss %10ss %9ss %12ss\n' sourcecode "${T[jvm]}" "${T[native]}" "${T[native-rcl]}" "${T[native-O3]}" "${T[native-rcl-O3]}"
eq=""
for label in native native-rcl native-O3 native-rcl-O3; do
  if [[ ${T[$label]} == FAIL ]]; then eq+="$label=FAIL "
  elif diff -rq "o-jvm" "o-$label" >/dev/null 2>&1; then eq+="$label=identical "
  else eq+="$label=DIFFERS "; fi
done
echo "            RSS MB: ${M[jvm]}/${M[native]}/${M[native-rcl]}/${M[native-O3]}/${M[native-rcl-O3]}   $eq"
echo "            classfiles: jvm=$(find o-jvm -name '*.class'|wc -l) rcl=$(find o-native-rcl -name '*.class'|wc -l) rclO3=$(find o-native-rcl-O3 -name '*.class'|wc -l)"
