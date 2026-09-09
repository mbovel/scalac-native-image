#!/usr/bin/env bash
# Memory comparison: peak RSS (/usr/bin/time %M), median of 3 runs.
# Cold = one compile per process. Warm = 12 in-process iterations (Loop).
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
TMP="${SCRATCH:-/tmp}/mem"; mkdir -p "$TMP"
names=(helloWorld dottyUtil re2s tastyQuery)
srcs_of() { case $1 in
  helloWorld) echo $B/small/helloWorld.scala;;
  dottyUtil)  find $B/dottyUtil -name '*.scala' | sort;;
  re2s)       find $B/re2s -name '*.scala' | sort;;
  tastyQuery) find $B/tastyQuery/tasty-query -name '*.scala' | sort;;
esac; }
extra_of() { [[ $1 == tastyQuery ]] && echo "-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s" || echo ""; }
med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

# cfg: label -> command prefix.  $1=name
cmd_for() {
  local label=$1 name=$2
  case $label in
    native)      echo "./scalac-native-O3|-bootclasspath|java.base.jar";;
    jvm)         echo "java|-cp|$CP|dotty.tools.dotc.Main";;
    jvm-aot)     echo "java|-XX:AOTCache=aot/$name-cold.aot|-cp|$CP|dotty.tools.dotc.Main";;
    jvm-8g)      echo "java|-Xms8G|-Xmx8G|-cp|$CP|dotty.tools.dotc.Main";;
    jvm-aot-8g)  echo "java|-Xms8G|-Xmx8G|-XX:AOTCache=aot/$name-cold.aot|-cp|$CP|dotty.tools.dotc.Main";;
  esac
}

echo "######## cold: peak RSS (MB), median of 3 ########"
printf '%-11s %9s %9s %9s %9s %9s\n' bench native jvm jvm-aot jvm-8g jvm-aot-8g
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  printf '%-11s ' "$name"
  for label in native jvm jvm-aot jvm-8g jvm-aot-8g; do
    IFS='|' read -ra C <<< "$(cmd_for $label $name)"
    rss=(); tim=()
    for i in 1 2 3; do
      rm -rf "$TMP/o"; mkdir -p "$TMP/o"
      /usr/bin/time -f "%M %e" -o "$TMP/t" "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" \
        -d "$TMP/o" "${SRCS[@]}" > "$TMP/log" 2>&1
      read -r m t < "$TMP/t"; rss+=("$m"); tim+=("$t")
    done
    printf '%9s ' "$(( $(med "${rss[@]}") / 1024 ))"
    echo "$name $label rss=$(med "${rss[@]}") time=$(med "${tim[@]}")" >> "$TMP/detail"
  done
  echo
done

echo
echo "######## warm: peak RSS (MB) over 12 in-process iterations ########"
printf '%-11s %9s %9s %9s %9s\n' bench native jvm jvm-aot jvm-8g
for name in "${names[@]}"; do
  SRCS=($(srcs_of $name)); declare -a X=(); e=$(extra_of $name); [[ -n $e ]] && IFS='|' read -ra X <<< "$e"
  printf '%-11s ' "$name"
  for label in native jvm jvm-aot jvm-8g; do
    case $label in
      native)   C=(./scalac-native-loop-O3 12 -bootclasspath java.base.jar);;
      jvm)      C=(java -cp "$CP:loop.jar" Loop 12);;
      jvm-aot)  C=(java -XX:AOTCache=aot/$name-warm.aot -cp "$CP:loop.jar" Loop 12);;
      jvm-8g)   C=(java -Xms8G -Xmx8G -cp "$CP:loop.jar" Loop 12);;
    esac
    rm -rf "$TMP/o"; mkdir -p "$TMP/o"
    /usr/bin/time -f "%M" -o "$TMP/t" "${C[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${X[@]}" \
      -d "$TMP/o" "${SRCS[@]}" > "$TMP/log" 2>&1
    printf '%9s ' "$(( $(cat "$TMP/t") / 1024 ))"
  done
  echo
done

echo
echo "######## cold time (s) at default heap, median of 3 ########"
grep -v " jvm-8g \| jvm-aot-8g " "$TMP/detail" | awk '{split($0,a," "); print}' | \
  awk '{printf "%-11s %-9s %s\n", $1, $2, $4}' | sed 's/time=//'
