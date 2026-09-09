# Scala 3 compiler + GraalVM native-image dev container

A dev container for experimenting with compiling the Scala 3 compiler
(`dotty.tools.dotc.Main`) to a native executable with GraalVM native-image.
Claude Code runs inside the container and keeps its sign-in and state in a
project-specific Docker volume, independent from the host and from other
projects (see below).

## What is inside

| Tool | Version / source | Where |
| --- | --- | --- |
| GraalVM Community (JDK 25.0.4.1) with `native-image`, `native-image-agent`, `native-image-configure` | release `graal-25.3.4.1` | `/opt/graalvm` (`JAVA_HOME`, `GRAALVM_HOME`) |
| sbt launcher | 1.12.1, the version scala3 pins (the launcher boots whatever `sbt.version` a project asks for) | `/opt/sbt/bin` |
| coursier (`cs`) | 2.1.24 | `/usr/local/bin/cs` |
| scala-cli | latest, installed with `cs install` | `~/.local/share/coursier/bin` |
| C toolchain for native-image | `build-essential`, `zlib1g-dev`, `gdb` | apt |
| Node.js LTS + Claude Code CLI and VS Code extension | dev container features (Claude Code auto-updates) | `claude` |
| VS Code extensions | Metals, Claude Code | |

Versions are pinned in `build.args` in
[.devcontainer/devcontainer.json](.devcontainer/devcontainer.json); the `ARG`
defaults at the top of [.devcontainer/Dockerfile](.devcontainer/Dockerfile)
match them. GraalVM release tags and archive names are listed at
<https://github.com/graalvm/graalvm-ce-builds/releases>.

The Scala 3 CI builds the compiler on JDK 17. Building it on the GraalVM JDK 25
shipped here is normally fine; if the sbt build ever objects to the JDK
version, install a second JDK for sbt with `cs java-home --jvm temurin:17` and
keep GraalVM for native-image.

## Prerequisites

- Docker.
- VS Code with the Dev Containers extension, or the `devcontainer` CLI.
- If VS Code reaches this machine through Remote-SSH, Docker runs on this
  machine and "host" below means this machine, not your laptop.

## Claude Code sign-in and state

Claude Code keeps its OAuth token, settings, `.claude.json` and session history
in `CLAUDE_CONFIG_DIR`, which the container sets to `/home/vscode/.claude`.
That directory is the Docker named volume `scala3-graal-claude-config`, so:

- you sign in once (`claude` in the integrated terminal) and stay signed in
  across container rebuilds;
- the account used here is independent from Claude Code on the host and from
  other projects, because the volume is specific to this project. To share one
  account between projects, give their containers the same volume name;
- nothing from the host's `~/.claude` is mounted into the container.

Useful on the host:

```bash
docker volume inspect scala3-graal-claude-config   # where the state lives
docker volume rm scala3-graal-claude-config        # forget the account (remove the container first)
```

To switch accounts, remove the volume and sign in again, or change the volume
name in `devcontainer.json` and rebuild.

GitHub Codespaces and CI have no persistent volume; there, store a token from
`claude setup-token` as the `CLAUDE_CODE_OAUTH_TOKEN` secret instead.

Verify inside the container:

```bash
echo $CLAUDE_CONFIG_DIR      # /home/vscode/.claude
ls -la $CLAUDE_CONFIG_DIR    # .credentials.json, .claude.json, projects/ once signed in
claude                       # /status shows the signed-in account
```

## First start

Open this folder in VS Code and choose **Reopen in Container**. The first
build downloads GraalVM (about 400 MB) and installs Node and Claude Code; later
builds reuse Docker's layer cache. When the container is ready
`.devcontainer/post-create.sh` prints the tool versions and whether Claude Code
is already signed in. Run `claude` in the integrated terminal to sign in; the
sign-in persists in the volume.

## Working on the Scala 3 compiler

Clone the compiler into the workspace (it is bind-mounted from the host, so
the clone persists):

```bash
git clone https://github.com/scala/scala3.git
cd scala3
sbt                 # the launcher fetches the sbt version pinned by the repo
```

See the repository's `docs/_docs/contributing/getting-started.md` for the sbt
tasks (`scala3-compiler-bootstrapped/compile`, `dist/pack`, `buildQuick`, ...).

### Quick native-image experiments with a published compiler

coursier turns a Maven coordinate into a classpath, which native-image
accepts directly:

```bash
CP="$(cs fetch -p org.scala-lang:scala3-compiler_3:3.9.0)"

# 1. Record reflection / resource usage with the tracing agent while compiling something
mkdir -p /tmp/hello && echo '@main def hello = println("hi")' > /tmp/hello/hello.scala
java -agentlib:native-image-agent=config-output-dir=ni-config \
     -cp "$CP" dotty.tools.dotc.Main -d /tmp/hello/out /tmp/hello/hello.scala

# 2. Build the image
native-image -cp "$CP" -H:ConfigurationFileDirectories=ni-config \
     --no-fallback -H:+ReportExceptionStackTraces -o scalac-native \
     dotty.tools.dotc.Main

# 3. Run it
./scalac-native -d /tmp/hello/out /tmp/hello/hello.scala
```

Expect to iterate on the reachability metadata; the compiler loads plugins and
classes reflectively and uses resources (`compiler.properties`, the standard
library TASTy files). `native-image --help-extra`, `-H:+PrintClassInitialization`
and `--trace-class-initialization=...` are the usual next steps.

To compile a locally built compiler instead, run `sbt buildQuick` in the scala3
checkout: it writes the compiler classpath to `bin/.cp`, which can replace `$CP`
above.

### Notes

- `NATIVE_IMAGE_INSTALLED=true` and `GRAALVM_HOME` are set, so the
  [sbt-native-image](https://github.com/scalameta/sbt-native-image) plugin uses
  the installed GraalVM instead of downloading one.
- native-image is memory hungry. The image builder picks its heap from the
  container's memory; pass `-J-Xmx16g` (or more) and `--parallelism=<n>` to
  control it explicitly. Docker on Linux gives the container all host memory
  unless limited.
- Dependency caches live in the named volumes `scala3-graal-coursier-cache`,
  `scala3-graal-sbt` and `scala3-graal-ivy2` and survive rebuilds, like the
  Claude Code state. Remove them with `docker volume rm <name>` to start clean.
- For a fully static binary (`--static --libc=musl`) install `musl-tools` and a
  musl build of zlib; the default glibc dynamic linking needs nothing extra.

## Shipping a native `scalac`

The dev container is for experimenting. [docker/](docker/README.md) turns the
result into something distributable: a Docker image and standalone binaries, in
a `slim` flavour and a larger `macros` one that can expand macros.

```bash
cd docker
docker build -t scalac-native:slim .
docker run --rm -v "$PWD:/src" -w /src scalac-native:slim -d out hello.scala
```

The build flow lives in `docker/scripts/`, which the Dockerfile calls and which
also runs directly on machines without Docker. That is how
[.github/workflows/release.yml](.github/workflows/release.yml) builds macOS and
Windows binaries: native-image only ever targets the machine it runs on, so
those platforms cannot go through a Linux container.

## Files

- [docker/](docker/README.md): the distributable image and binaries, and the shared build scripts.
- [.github/workflows/release.yml](.github/workflows/release.yml): multi-platform binaries and multi-arch images.
- [.devcontainer/devcontainer.json](.devcontainer/devcontainer.json): image build, features, mounts, environment, VS Code settings.
- [.devcontainer/Dockerfile](.devcontainer/Dockerfile): GraalVM, sbt, coursier, scala-cli and the native toolchain.
- [.devcontainer/post-create.sh](.devcontainer/post-create.sh): fixes volume ownership and prints tool versions after creation.
- [dev-container-setup.md](dev-container-setup.md): background notes on per-account Claude Code profiles.
