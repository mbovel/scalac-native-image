#!/usr/bin/env bash
#
# Build java.base.jar: the JDK's own classes, packaged as a jar.
#
# A native image has no jrt:/ filesystem and no java.home, so dotc finds zero JDK
# classes and dies with "asTerm called on not-a-Term val <none>" (oracle/graal#8371).
# We hand it these classes via -bootclasspath instead.
#
# A jar, not the jimage-extracted directory: dotc rescans that 250 MB tree on
# every invocation, a flat ~0.14 s, which is two thirds of a hello-world compile.
#
# Usage: jdk-classes.sh <output-jar>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/scripts/common.sh"

OUT="${1:?usage: jdk-classes.sh <output-jar>}"
: "${JAVA_HOME:?JAVA_HOME must be set}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

log "extracting JDK modules from $JAVA_HOME"
jimage extract --dir="$(jpath "$work/modules")" "$(jpath "$JAVA_HOME/lib/modules")"

mkdir -p "$(dirname "$OUT")"
# Absolute, because `jar` runs after a cd into the extracted tree.
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"
( cd "$work/modules/java.base" && jar --create --file "$(jpath "$OUT")" . )

log "wrote $OUT ($(du -h "$OUT" | cut -f1))"
