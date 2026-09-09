#!/usr/bin/env bash
# Final tables: best-of-3 cold runs per (benchmark, compiler), -bootclasspath java.base.jar.
set -uo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"; LIBCP="$(cat libcp.txt)"; B=scala3-benchmarks/bench-sources
SHARED=(-feature -Werror -deprecation "-Wconf:msg=re-run with -deprecation:s")
mkdir -p b2

# run <outdir> <label> <extra-opts-pipe-separated> <sources...>  -> "besttime status"
run3() {
  local out=$1 label=$2 e=$3; shift 3
  local -a extra=(); [[ -n $e ]] && IFS='|' read -ra extra <<< "$e"
  local -a cmd
  case $label in
    jvm)       cmd=(java -Xms8G -Xmx8G -cp "$CP" dotty.tools.dotc.Main);;
    native)    cmd=(./scalac-native    -bootclasspath java.base.jar);;
    native-O3) cmd=(./scalac-native-O3 -bootclasspath java.base.jar);;
  esac
  local best=999 st=0 t x
  for i in 1 2 3; do
    rm -rf "$out"; mkdir -p "$out"
    /usr/bin/time -f "%e %x" -o "$out.time" \
      "${cmd[@]}" -classpath "$LIBCP" "${SHARED[@]}" "${extra[@]}" -d "$out" "$@" \
      > "$out.log" 2>&1
    read -r t x < "$out.time"
    [[ $x != 0 ]] && st=$x
    awk -v a="$t" -v b="$best" 'BEGIN{exit !(a<b)}' && best=$t
  done
  echo "$best $st"
}

echo "######## big benchmarks + hello world ########"
printf '%-11s %6s %10s %10s %10s   %s\n' bench files jvm native native-O3 output
for name in helloWorld dottyUtil re2s sourcecode tastyQuery scalaz; do
  case $name in
    helloWorld) SRCS=($B/small/helloWorld.scala); E="";;
    dottyUtil)  SRCS=($(find $B/dottyUtil -name '*.scala'|sort)); E="";;
    re2s)       SRCS=($(find $B/re2s -name '*.scala'|sort)); E="";;
    sourcecode) SRCS=($(find $B/sourcecode/src $B/sourcecode/src-3 $B/sourcecode/test/src $B/sourcecode/test/src-3 -name '*.scala'|sort)); E="";;
    tastyQuery) SRCS=($(find $B/tastyQuery/tasty-query -name '*.scala'|sort)); E="-Yexplicit-nulls|-Wconf:msg=Unnecessary .nn:s";;
    scalaz)     SRCS=($(find $B/scalaz -name '*.scala'|sort)); E="-nowarn|-source|3.0|-Xkind-projector|-language:implicitConversions";;
  esac
  printf '%-11s %6s ' "$name" "${#SRCS[@]}"
  for label in jvm native native-O3; do
    read -r t st <<< "$(run3 "b2/$name-$label" $label "$E" "${SRCS[@]}")"
    if [[ $st != 0 ]]; then printf '%10s ' "FAIL"; else printf '%9ss ' "$t"; fi
  done
  if diff -rq "b2/$name-jvm" "b2/$name-native" >/dev/null 2>&1 &&
     diff -rq "b2/$name-jvm" "b2/$name-native-O3" >/dev/null 2>&1
  then echo "  identical"; else echo "  DIFFERS"; fi
done

echo
echo "######## small single-file benchmarks ########"
printf '%-20s %10s %10s %8s   %s\n' bench jvm native-O3 speedup output
for f in $B/small/*.scala; do
  name=$(basename "$f" .scala)
  read -r tj sj <<< "$(run3 "b2/s-$name-jvm" jvm "" "$f")"
  read -r tn sn <<< "$(run3 "b2/s-$name-nat" native-O3 "" "$f")"
  printf '%-20s %9ss %9ss %7sx   ' "$name" "$tj" "$tn" "$(awk -v a="$tj" -v b="$tn" 'BEGIN{printf "%.1f", (b>0? a/b : 0)}')"
  if [[ $sj != 0 || $sn != 0 ]]; then echo "jvm=$sj native=$sn"
  elif diff -rq "b2/s-$name-jvm" "b2/s-$name-nat" >/dev/null 2>&1; then echo "identical"
  else echo "DIFFERS"; fi
done
