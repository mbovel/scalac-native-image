#!/usr/bin/env bash
# Refined min-heap: ladder extended down to 8m, and the wall time of the
# successful run at that minimum (the "does it fit AND is it usable" number).
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
TMP="${SCRATCH:-/tmp}/minheap2"; mkdir -p "$TMP"
LADDER=(8 12 16 24 32 48 64 96 128 192 256 384 512)
names=(helloWorld dottyUtil re2s tastyQuery)
srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }

LASTT=""
try() { # try <label> <name> <mb>; sets LASTT to wall seconds on success
  local label=$1 name=$2 mb=$3
  local -a C
  case $label in
    native)  C=(./scalac-native-O3 -Xmx${mb}m -bootclasspath java.base.jar);;
    jvm)     C=(java -Xmx${mb}m -cp "$CP" dotty.tools.dotc.Main);;
    jvm-aot) C=(java -Xmx${mb}m -XX:AOTCache=aot/$name-cold.aot -cp "$CP" dotty.tools.dotc.Main);;
  esac
  rm -rf "$TMP/o"; mkdir -p "$TMP/o"
  /usr/bin/time -f "%e" -o "$TMP/t" timeout 200 "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" \
    "${XX[@]}" -d "$TMP/o" "${SRCS[@]}" > "$TMP/log" 2>&1 || return 1
  [[ $(find "$TMP/o" -name '*.class' | wc -l) -gt 0 ]] || return 1
  LASTT=$(cat "$TMP/t"); return 0
}

printf '%-11s %18s %18s %18s\n' bench "native (t@min)" "jvm (t@min)" "jvm-aot (t@min)"
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a XX=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra XX <<< "$e"
  printf '%-11s ' "$name"
  for label in native jvm jvm-aot; do
    lo=0; hi=$(( ${#LADDER[@]} - 1 ))
    if ! try $label $name "${LADDER[$hi]}"; then printf '%18s ' ">512m"; continue; fi
    while (( lo < hi )); do
      mid=$(( (lo + hi) / 2 ))
      if try $label $name "${LADDER[$mid]}"; then hi=$mid; else lo=$(( mid + 1 )); fi
    done
    try $label $name "${LADDER[$hi]}" || true
    printf '%18s ' "${LADDER[$hi]}m (${LASTT}s)"
  done
  echo
done
