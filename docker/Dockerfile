# syntax=docker/dockerfile:1.7
#
# Native `scalac` (dotty.tools.dotc.Main) built with GraalVM native-image.
#
#   docker build -t scalac-native:slim   .
#   docker build -t scalac-native:macros --build-arg MACROS=true .
#   docker run --rm -v "$PWD:/src" -w /src scalac-native:slim -d out hello.scala
#
# Export the binary instead of an image (a directory: scalac + java.base.jar + lib/):
#   docker build --target artifact --output type=local,dest=dist/scalac-linux-x86_64 .
#
# Build args:
#   MACROS=false|true        macro support (see the macros stage below for the cost)
#   COMPILER_SOURCE=maven|git  published artifacts, or build dotty from source
#   SCALA_VERSION=3.9.0      used when COMPILER_SOURCE=maven
#   DOTTY_REF=main           used when COMPILER_SOURCE=git

# Global args: must be declared before the first FROM to be usable in FROM lines.
ARG COMPILER_SOURCE=maven
ARG GRAALVM_TAG=graal-25.3.4.1
ARG GRAALVM_ARTIFACT=graalvm-community-jdk-25i3-25.0.4.1
ARG DEBIAN_BASE=debian:trixie-slim

# ---------------------------------------------------------------------------
# 1. Builder base: GraalVM CE + the C toolchain native-image links against.
#    Pinned to the same version the dev container uses.
# ---------------------------------------------------------------------------
FROM ubuntu:24.04 AS graalvm
ARG GRAALVM_TAG
ARG GRAALVM_ARTIFACT
ENV JAVA_HOME=/opt/graalvm GRAALVM_HOME=/opt/graalvm
ENV PATH=/opt/graalvm/bin:$PATH
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential zlib1g-dev curl ca-certificates unzip zip python3 git; \
    apt-get clean; rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  ARCH=x64 ;; \
      aarch64) ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/graalvm/graalvm-ce-builds/releases/download/${GRAALVM_TAG}/${GRAALVM_ARTIFACT}_linux-${ARCH}_bin.tar.gz"; \
    curl -fsSL -o /tmp/graalvm.tar.gz "$URL"; \
    curl -fsSL -o /tmp/graalvm.sha256 "$URL.sha256"; \
    echo "$(awk '{print $1}' /tmp/graalvm.sha256)  /tmp/graalvm.tar.gz" | sha256sum -c -; \
    mkdir -p "$JAVA_HOME"; \
    tar -xzf /tmp/graalvm.tar.gz -C "$JAVA_HOME" --strip-components=1; \
    rm -f /tmp/graalvm.tar.gz /tmp/graalvm.sha256; \
    native-image --version

# ---------------------------------------------------------------------------
# 2a. Compiler classpath from published artifacts (default; seconds, cacheable).
# ---------------------------------------------------------------------------
FROM graalvm AS compiler-maven
ARG SCALA_VERSION=3.9.0
ARG COURSIER_VERSION=2.1.24
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  URL="https://github.com/coursier/coursier/releases/download/v${COURSIER_VERSION}/cs-x86_64-pc-linux.gz" ;; \
      # No aarch64 asset on the release page; fall back to the rolling launcher.
      aarch64) URL="https://github.com/coursier/launchers/raw/master/cs-aarch64-pc-linux.gz" ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/cs.gz "$URL"; \
    gunzip -c /tmp/cs.gz > /usr/local/bin/cs; \
    chmod +x /usr/local/bin/cs; rm -f /tmp/cs.gz; \
    cs version
COPY scripts /work/src/scripts
RUN bash /work/src/scripts/fetch-compiler.sh "${SCALA_VERSION}" /out/cp /out/lib

# ---------------------------------------------------------------------------
# 2b. Compiler classpath by building dotty from source (slow: sbt + bootstrap).
#     `dist/Universal/stage` (sbt-native-packager) republishes the bootstrapped
#     artifacts into dist/target/universal/stage/{lib,maven2}: lib/scala.jar is a
#     manifest-only jar whose Class-Path lists the jars under maven2/ that the
#     `scala` command runs the compiler with. We collect exactly those.
# ---------------------------------------------------------------------------
FROM graalvm AS compiler-git
ARG SBT_VERSION=1.12.1
ARG DOTTY_REPO=https://github.com/scala/scala3.git
ARG DOTTY_REF=main
RUN set -eux; \
    URL="https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz"; \
    curl -fsSL -o /tmp/sbt.tgz "$URL"; tar -xzf /tmp/sbt.tgz -C /opt; rm /tmp/sbt.tgz; \
    ln -s /opt/sbt/bin/sbt /usr/local/bin/sbt
WORKDIR /src
RUN set -eux; \
    if git clone --depth 1 --branch "${DOTTY_REF}" "${DOTTY_REPO}" scala3; then :; else \
      git clone "${DOTTY_REPO}" scala3; \
      git -C scala3 checkout "${DOTTY_REF}"; \
    fi
# Keep the sbt/coursier caches across rebuilds; this step is the expensive one.
# The repo's .jvmopts (-Xmx8g etc.) is picked up by the sbt launcher.
RUN --mount=type=cache,target=/root/.cache/coursier \
    --mount=type=cache,target=/root/.sbt \
    --mount=type=cache,target=/root/.ivy2 \
    set -eux; cd scala3; sbt -batch "dist/Universal/stage"
RUN set -eux; \
    mkdir -p /out/cp /out/lib; \
    python3 - <<'EOF'
import os, re, shutil, zipfile
stage = "/src/scala3/dist/target/universal/stage"
mf = zipfile.ZipFile(f"{stage}/lib/scala.jar").read("META-INF/MANIFEST.MF").decode()
mf = mf.replace("\r\n", "\n").replace("\n ", "")        # unwrap 72-column continuation lines
cp = re.search(r"^Class-Path: (.*)$", mf, re.M).group(1).split()
assert cp, "empty Class-Path in lib/scala.jar"
for rel in cp:
    src = os.path.normpath(os.path.join(stage, "lib", rel))
    shutil.copy(src, "/out/cp/")
    name = os.path.basename(src)
    if re.match(r"(scala3-library_3|scala-library)-", name):
        shutil.copy(src, "/out/lib/")
print("cp:", sorted(os.listdir("/out/cp")))
print("lib:", sorted(os.listdir("/out/lib")))
assert len(os.listdir("/out/lib")) == 2, "expected scala3-library and scala-library"
EOF

# Pick 2a or 2b. BuildKit only builds the stage that is actually referenced.
FROM compiler-${COMPILER_SOURCE} AS compiler

# ---------------------------------------------------------------------------
# 3. JDK classes as a jar, for -bootclasspath.
#    A native image has no jrt:/ filesystem, so this is how dotc sees the JDK.
#    A jar, not the extracted directory: dotc scans a 250 MB tree on every run
#    otherwise, which costs ~0.14 s -- two thirds of a hello-world compile.
# ---------------------------------------------------------------------------
FROM graalvm AS jdkclasses
COPY scripts /work/src/scripts
RUN bash /work/src/scripts/jdk-classes.sh /out/java.base.jar

# ---------------------------------------------------------------------------
# 4. native-image build.
# ---------------------------------------------------------------------------
FROM graalvm AS nativebuild
ARG MACROS=false
ARG NI_OPT="-O3"   # NOT -march=native: see README, it SIGILLs on older CPUs
ARG NI_XMX=16g
ARG NI_PARALLELISM=8
WORKDIR /work
COPY --from=compiler   /out/cp           /work/cp
COPY --from=compiler   /out/lib          /work/lib
COPY --from=jdkclasses /out/java.base.jar /work/java.base.jar
COPY ScalacMain.java gen-reflect-metadata.py /work/src/
COPY train   /work/src/train
COPY scripts /work/src/scripts

# The whole flow lives in build-native.sh, so the macOS and Windows CI jobs --
# which cannot use Docker, because native-image only targets its own machine --
# run exactly these steps. Writes /out/{scalac,java.base.jar,lib}.
RUN bash /work/src/scripts/build-native.sh \
      --cp-dir /work/cp \
      --lib-dir /work/lib \
      --java-base-jar /work/java.base.jar \
      --out-dir /out \
      --work-dir /work/build \
      --macros "$MACROS" \
      --ni-opt "$NI_OPT" \
      --xmx "$NI_XMX" \
      --parallelism "$NI_PARALLELISM"

# ---------------------------------------------------------------------------
# 5a. Export stage: nothing but the distributable files. Not an image to run;
#     `docker build --target artifact --output type=local,dest=DIR .` writes
#     DIR/scalac, DIR/java.base.jar and DIR/lib/ on the host. The three must
#     stay together: ScalacMain finds the jars next to the executable.
# ---------------------------------------------------------------------------
FROM scratch AS artifact
COPY --from=nativebuild /out /

# ---------------------------------------------------------------------------
# 5b. Runtime image: the binary links only against libc, libm and libz.
# ---------------------------------------------------------------------------
FROM ${DEBIAN_BASE} AS runtime
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    apt-get update; \
    apt-get install -y --no-install-recommends zlib1g; \
    apt-get clean; rm -rf /var/lib/apt/lists/*
# Layout matters: ScalacMain locates java.base.jar and lib/ relative to the
# executable via ProcessProperties.getExecutableName().
COPY --from=nativebuild /out /opt/scalac
ENV PATH=/opt/scalac:$PATH
WORKDIR /src
ENTRYPOINT ["/opt/scalac/scalac"]
CMD ["-version"]
