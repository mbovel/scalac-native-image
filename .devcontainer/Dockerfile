# Dev container image for experimenting with GraalVM native-image builds of the
# Scala 3 compiler. Ships GraalVM Community (JDK + native-image), the C toolchain
# native-image links against, sbt, coursier and scala-cli. Claude Code and Node
# are added on top by dev container features (see devcontainer.json).
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# ---------------------------------------------------------------------------
# Versions. devcontainer.json pins them in "build": { "args": { ... } }; the
# defaults below match and only apply to a standalone `docker build`.
#
# GraalVM Community releases: https://github.com/graalvm/graalvm-ce-builds/releases
#   Since GraalVM 25.1 the release tag is `graal-<graal version>` and the
#   archive is `graalvm-community-jdk-<jdk marker>_linux-<arch>_bin.tar.gz`.
#   Older releases use tag `jdk-<version>` and artifact
#   `graalvm-community-jdk-<version>`, e.g.
#     GRAALVM_TAG=jdk-21.0.2 GRAALVM_ARTIFACT=graalvm-community-jdk-21.0.2
ARG GRAALVM_TAG=graal-25.3.4.1
ARG GRAALVM_ARTIFACT=graalvm-community-jdk-25i3-25.0.4.1
# sbt launcher: https://github.com/sbt/sbt/releases
#   The launcher boots whatever `sbt.version` a project pins in
#   project/build.properties; 1.12.1 is what scala3 pins.
ARG SBT_VERSION=1.12.1
# coursier CLI: https://github.com/coursier/coursier/releases
ARG COURSIER_VERSION=2.1.24

# ---------------------------------------------------------------------------
# Native toolchain. native-image requires gcc, glibc headers and zlib headers;
# gdb is for debugging native executables (-g / -H:+SourceLevelDebug).
RUN export DEBIAN_FRONTEND=noninteractive \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      zlib1g-dev \
      gdb \
      unzip \
      zip \
      jq \
      time \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# GraalVM (JDK + native-image, native-image-agent, native-image-configure).
ENV JAVA_HOME=/opt/graalvm
ENV GRAALVM_HOME=/opt/graalvm
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  ARCH=x64 ;; \
      aarch64) ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    URL="https://github.com/graalvm/graalvm-ce-builds/releases/download/${GRAALVM_TAG}/${GRAALVM_ARTIFACT}_linux-${ARCH}_bin.tar.gz"; \
    curl -fsSL -o /tmp/graalvm.tar.gz "${URL}"; \
    curl -fsSL -o /tmp/graalvm.sha256 "${URL}.sha256"; \
    echo "$(awk '{print $1}' /tmp/graalvm.sha256)  /tmp/graalvm.tar.gz" | sha256sum -c -; \
    mkdir -p "${JAVA_HOME}"; \
    tar -xzf /tmp/graalvm.tar.gz -C "${JAVA_HOME}" --strip-components=1; \
    rm -f /tmp/graalvm.tar.gz /tmp/graalvm.sha256; \
    "${JAVA_HOME}/bin/java" -version; \
    "${JAVA_HOME}/bin/native-image" --version

# ---------------------------------------------------------------------------
# sbt launcher (bin/sbt script + sbt-launch.jar + sbtn native client).
RUN set -eux; \
    URL="https://github.com/sbt/sbt/releases/download/v${SBT_VERSION}/sbt-${SBT_VERSION}.tgz"; \
    curl -fsSL -o /tmp/sbt.tgz "${URL}"; \
    curl -fsSL -o /tmp/sbt.sha256 "${URL}.sha256"; \
    echo "$(awk '{print $1}' /tmp/sbt.sha256)  /tmp/sbt.tgz" | sha256sum -c -; \
    tar -xzf /tmp/sbt.tgz -C /opt; \
    rm -f /tmp/sbt.tgz /tmp/sbt.sha256; \
    test -x /opt/sbt/bin/sbt

# ---------------------------------------------------------------------------
# coursier CLI (`cs`): resolves/fetches artifacts and prints classpaths, which
# is the quickest way to hand a published scala3-compiler to native-image.
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)  URL="https://github.com/coursier/coursier/releases/download/v${COURSIER_VERSION}/cs-x86_64-pc-linux.gz" ;; \
      # No aarch64 asset on the release page; fall back to the rolling launcher.
      aarch64) URL="https://github.com/coursier/launchers/raw/master/cs-aarch64-pc-linux.gz" ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/cs.gz "${URL}"; \
    gunzip -c /tmp/cs.gz > /usr/local/bin/cs; \
    chmod +x /usr/local/bin/cs; \
    rm -f /tmp/cs.gz; \
    cs version

ENV PATH=${JAVA_HOME}/bin:/opt/sbt/bin:/home/vscode/.local/share/coursier/bin:${PATH}

# ---------------------------------------------------------------------------
# Per-user setup for the dev user (vscode). The cache directories are created
# here so the named volumes mounted over them inherit vscode ownership.
USER vscode
RUN set -eux; \
    mkdir -p "/home/vscode/.cache/coursier" "/home/vscode/.sbt" "/home/vscode/.ivy2" "/home/vscode/.claude"; \
    cs install --install-dir "/home/vscode/.local/share/coursier/bin" scala-cli; \
    scala-cli --version; \
    rm -rf "/home/vscode/.cache/coursier/v1"
