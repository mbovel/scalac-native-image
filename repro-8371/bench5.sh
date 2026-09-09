#!/usr/bin/env bash
# Smallest -Xmx at which each config completes the compile (bisect over a ladder).
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
TMP="${SCRATCH:-/tmp}/minheap"; mkdir -p "$TMP"
LADDER=(32 48 64 96 128 192 256 384 512 768 1024 1536 2048 3072)
names=(helloWorld dottyUtil re2s tastyQuery)
srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }

try() { # try <label> <name> <mb> ; 0 = compiled successfully
  local label=$1 name=$2 mb=$3
  local -a C
  case $label in
    native)  C=(./scalac-native-O3 -Xmx${mb}m -bootclasspath java.base.jar);;
    jvm)     C=(java -Xmx${mb}m -cp "$CP" dotty.tools.dotc.Main);;
    jvm-aot) C=(java -Xmx${mb}m -XX:AOTCache=aot/$name-cold.aot -cp "$CP" dotty.tools.dotc.Main);;
  esac
  rm -rf "$TMP/o"; mkdir -p "$TMP/o"
  timeout 150 "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${XX[@]}" \
    -d "$TMP/o" "${SRCS[@]}" > "$TMP/log" 2>&1 || return 1
  [[ $(find "$TMP/o" -name '*.class' | wc -l) -gt 0 ]]
}

printf '%-11s %10s %10s %10s\n' bench native jvm jvm-aot
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a XX=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra XX <<< "$e"
  printf '%-11s ' "$name"
  for label in native jvm jvm-aot; do
    lo=0; hi=$(( ${#LADDER[@]} - 1 )); res="  >3072m"
    if try $label $name "${LADDER[$hi]}"; then
      res="${LADDER[$hi]}m"
      while (( lo < hi )); do
        mid=$(( (lo + hi) / 2 ))
        if try $label $name "${LADDER[$mid]}"; then hi=$mid; else lo=$(( mid + 1 )); fi
      done
      res="${LADDER[$hi]}m"
    fi
    printf '%10s ' "$res"
  done
  echo
done
