#!/usr/bin/env bash
# native-O3 vs jvm vs jvm-aot (JDK 25 AOT cache), cold and warm.
#   cold = best of 3 fresh processes
#   warm = min of the last 5 of 12 in-process iterations (Loop.java)
# AOT caches are trained per benchmark on that same benchmark (best case for the JVM).
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
JF=(-Xms8G -Xmx8G)
mkdir -p aot b3
names=(helloWorld dottyUtil re2s tastyQuery)

srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }

echo "######## training AOT caches ########"
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  for kind in cold warm; do
    rm -rf /tmp/aot-tr; mkdir -p /tmp/aot-tr
    if [[ $kind == cold ]]; then
      java "${JF[@]}" -XX:AOTCacheOutput=aot/$name-cold.aot -cp "$CP" dotty.tools.dotc.Main \
        -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" -d /tmp/aot-tr "${SRCS[@]}" > aot/$name-cold.train 2>&1
    else
      java "${JF[@]}" -XX:AOTCacheOutput=aot/$name-warm.aot -cp "$CP:loop.jar" Loop 1 \
        -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" -d /tmp/aot-tr "${SRCS[@]}" > aot/$name-warm.train 2>&1
    fi
    printf '  %-11s %-5s %s MB\n' "$name" "$kind" "$(du -m aot/$name-$kind.aot 2>/dev/null | cut -f1)"
  done
done

echo
echo "######## cold: best of 3 fresh processes ########"
printf '%-11s %11s %11s %11s   %s\n' bench native-O3 jvm jvm-aot "aot vs native"
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  declare -A R=()
  for label in native-O3 jvm jvm-aot; do
    case $label in
      native-O3) cmd=(./scalac-native-O3 -bootclasspath java.base.jar);;
      jvm)       cmd=(java "${JF[@]}" -cp "$CP" dotty.tools.dotc.Main);;
      jvm-aot)   cmd=(java "${JF[@]}" -XX:AOTCache=aot/$name-cold.aot -cp "$CP" dotty.tools.dotc.Main);;
    esac
    best=999
    for i in 1 2 3; do
      out=b3/$name-$label; rm -rf "$out"; mkdir -p "$out"
      /usr/bin/time -f "%e" -o "$out.time" "${cmd[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" \
        -d "$out" "${SRCS[@]}" > "$out.log" 2>&1
      t=$(cat "$out.time"); awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t
    done
    R[$label]=$best
  done
  printf '%-11s %10ss %10ss %10ss   %sx\n' "$name" "${R[native-O3]}" "${R[jvm]}" "${R[jvm-aot]}" \
    "$(awk -v a="${R[jvm-aot]}" -v b="${R[native-O3]}" 'BEGIN{printf "%.1f", a/b}')"
done

echo
echo "######## warm: 12 in-process iterations, min of last 5 ########"
printf '%-11s %11s %11s %11s   %s\n' bench native-O3 jvm jvm-aot "iter0 (native/jvm/aot)"
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  declare -A W=() I0=()
  for label in native-O3 jvm jvm-aot; do
    case $label in
      native-O3) cmd=(./scalac-native-loop-O3 -bootclasspath java.base.jar);;
      jvm)       cmd=(java "${JF[@]}" -cp "$CP:loop.jar" Loop);;
      jvm-aot)   cmd=(java "${JF[@]}" -XX:AOTCache=aot/$name-warm.aot -cp "$CP:loop.jar" Loop);;
    esac
    out=b3/w-$name-$label; rm -rf "$out"; mkdir -p "$out"
    if [[ $label == native-O3 ]]; then
      "${cmd[@]}" 12 -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" -d "$out" "${SRCS[@]}" > "$out.log" 2>&1
    else
      "${cmd[@]}" 12 -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" -d "$out" "${SRCS[@]}" > "$out.log" 2>&1
    fi
    ms=($(grep -oP 'iter \d+: \K\d+' "$out.log"))
    I0[$label]=${ms[0]:-NA}
    W[$label]=$(printf '%s\n' "${ms[@]:7}" | sort -n | head -1)
  done
  printf '%-11s %9sms %9sms %9sms   %s/%s/%s ms\n' "$name" "${W[native-O3]}" "${W[jvm]}" "${W[jvm-aot]}" \
    "${I0[native-O3]}" "${I0[jvm]}" "${I0[jvm-aot]}"
done
