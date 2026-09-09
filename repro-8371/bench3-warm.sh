#!/usr/bin/env bash
# Warm only: 12 in-process iterations, min of last 5. Caches already trained by bench3.sh.
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
JF=(-Xms8G -Xmx8G)
names=(helloWorld dottyUtil re2s tastyQuery)
srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }

printf '%-11s %11s %11s %11s   %s\n' bench native-O3 jvm jvm-aot "iter0 native/jvm/aot"
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  declare -A W=() I0=()
  for label in native-O3 jvm jvm-aot; do
    case $label in
      native-O3) full=(./scalac-native-loop-O3 12 -bootclasspath java.base.jar);;
      jvm)       full=(java "${JF[@]}" -cp "$CP:loop.jar" Loop 12);;
      jvm-aot)   full=(java "${JF[@]}" -XX:AOTCache=aot/$name-warm.aot -cp "$CP:loop.jar" Loop 12);;
    esac
    out=b3/w-$name-$label; rm -rf "$out"; mkdir -p "$out"
    "${full[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" -d "$out" "${SRCS[@]}" > "$out.log" 2>&1
    ms=($(grep -oP 'iter \d+: \K\d+' "$out.log"))
    if [[ ${#ms[@]} -lt 12 ]]; then W[$label]=ERR; I0[$label]=ERR
    else I0[$label]=${ms[0]}; W[$label]=$(printf '%s\n' "${ms[@]:7}" | sort -n | head -1); fi
  done
  printf '%-11s %9sms %9sms %9sms   %s/%s/%s ms\n' "$name" "${W[native-O3]}" "${W[jvm]}" "${W[jvm-aot]}" \
    "${I0[native-O3]}" "${I0[jvm]}" "${I0[jvm-aot]}"
done
echo
echo "### full curves ###"
for name in "${names[@]}"; do for label in native-O3 jvm jvm-aot; do
  printf '%-11s %-10s ' "$name" "$label"; grep -oP 'iter \d+: \K\d+ ms' b3/w-$name-$label.log | paste -sd' '
done; done
