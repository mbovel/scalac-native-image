#!/usr/bin/env bash
#
# Populate a compiler classpath from published Maven artifacts.
#
# Two separate directories, because they play different roles:
#   <cp-dir>   every compiler jar; what native-image compiles into the image
#   <lib-dir>  just the Scala library; what the produced scalac hands to user
#              code as its default -classpath
#
# Usage: fetch-compiler.sh <scala-version> <cp-dir> <lib-dir>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
. "$ROOT/scripts/common.sh"

SCALA_VERSION="${1:?usage: fetch-compiler.sh <scala-version> <cp-dir> <lib-dir>}"
CP_DIR="${2:?}"
LIB_DIR="${3:?}"

command -v cs >/dev/null 2>&1 || { echo "coursier (cs) not on PATH" >&2; exit 2; }

mkdir -p "$CP_DIR" "$LIB_DIR"

log "fetching scala3-compiler $SCALA_VERSION"
cs fetch -p "org.scala-lang:scala3-compiler_3:$SCALA_VERSION" \
  | tr "$CPSEP" '\n' | while IFS= read -r jar; do
      [ -n "$jar" ] && cp "$(spath "$jar")" "$CP_DIR/"
    done

log "fetching scala3-library $SCALA_VERSION"
cs fetch -p "org.scala-lang:scala3-library_3:$SCALA_VERSION" \
  | tr "$CPSEP" '\n' | while IFS= read -r jar; do
      [ -n "$jar" ] && cp "$(spath "$jar")" "$LIB_DIR/"
    done

ls "$CP_DIR" "$LIB_DIR"
