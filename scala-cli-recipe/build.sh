#!/usr/bin/env bash
# Minimal reproduction / local dev loop for a native dotc, using scala-cli.
# The Dockerfile in ../docker does the same thing with pinned versions.
set -euo pipefail
cd "$(dirname "$0")"
SCALA=3.9.0

# 1. JDK classes as a jar. A native image has no jrt:/ filesystem, so this is
#    the only way dotc can see java.lang.Object (oracle/graal#8371).
if [ ! -f java.base.jar ]; then
  rm -rf jdk-classes && mkdir jdk-classes
  jimage extract --dir=jdk-classes "${JAVA_HOME:?}/lib/modules"
  (cd jdk-classes/java.base && jar --create --file ../../java.base.jar .)
  rm -rf jdk-classes
fi

# 2. The Scala library the produced compiler hands to user code.
mkdir -p lib && cs fetch -p "org.scala-lang:scala3-library_3:$SCALA" | tr ':' '\n' | xargs -I{} cp {} lib/

# 3. Reachability metadata. NOT optional: without it the image builds and runs,
#    but emits invalid constructors (VerifyError at run time) -- this is the
#    "corrupted bytecode" of issue comment #4.
if [ ! -d ni-config ]; then
  mkdir -p ni-config /tmp/ni-train && echo '@main def train = println((1 to 3).map(_ * 2).mkString(","))' > /tmp/ni-train/Train.scala
  java -agentlib:native-image-agent=config-output-dir=ni-config \
       -cp "$(cs fetch -p org.scala-lang:scala3-compiler_3:$SCALA)" dotty.tools.dotc.Main \
       -classpath "$(cs fetch -p org.scala-lang:scala3-library_3:$SCALA)" \
       -d /tmp/ni-train /tmp/ni-train/Train.scala
fi

# 4. Build. scala-cli ignores GRAALVM_HOME/NATIVE_IMAGE_INSTALLED and fetches its
#    own GraalVM (17.0.9 by default!), so pin it explicitly.
scala-cli --power package --native-image -o scalac -f \
  --graalvm-jvm-id "graalvm-community:25" . -- \
  --no-fallback -O3 -H:ConfigurationFileDirectories=ni-config

echo
echo "built ./scalac -- try:  mkdir -p out && ./scalac -d out <file>.scala"
