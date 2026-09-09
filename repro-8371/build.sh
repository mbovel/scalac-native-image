#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
CP="$(cat cp.txt)"
native-image \
  -cp "$CP" \
  -H:ConfigurationFileDirectories=ni-config \
  --no-fallback \
  -H:+ReportExceptionStackTraces \
  -J-Xmx24g \
  --parallelism=32 \
  -o scalac-native \
  dotty.tools.dotc.Main
