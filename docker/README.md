# Native `scalac` Docker image

Builds `dotty.tools.dotc.Main` into a native executable with GraalVM native-image,
in two published flavours:

| tag | build | binary | image (approx) | macros |
| --- | --- | ---: | ---: | --- |
| `:slim` | `docker build -t scalac-native:slim .` | 113 MB | ~215 MB | no |
| `:macros` | `docker build -t scalac-native:macros --build-arg MACROS=true .` | 452 MB | ~555 MB | yes |

```bash
docker run --rm -v "$PWD:/src" -w /src scalac-native:slim -d out hello.scala
```

No flags needed: the entry point supplies `-bootclasspath` and a default
`-classpath` itself (see below). Both are only defaults -- pass either flag and
yours wins.

## Getting the binary out of the image

The `artifact` stage holds only the distributable files. Export it to a host
directory instead of building an image:

```bash
docker build --target artifact --output type=local,dest=dist/scalac-linux-x86_64 .
```

That writes `scalac`, `java.base.jar` and `lib/` (the Scala library jars). Ship
the directory as one unit: the executable looks for the jars next to itself.

The binary links dynamically against libc, libm and libz and, built on the
Ubuntu 24.04 builder, references glibc symbols up to `GLIBC_2.34`, so it runs on
Ubuntu 22.04+, Debian 12+, RHEL 9+ and anything newer, but not on older glibc or
on musl-based distributions (Alpine). The floor is set by the builder's glibc
alone, so a lower one is a matter of changing the first `FROM`.

## Building without Docker, and for other platforms

native-image does not cross-compile: it emits a binary for the OS and CPU of the
machine it runs on. Docker therefore covers Linux only, and the other platforms
need a real machine of their own -- in practice a CI runner.

So the flow lives in `scripts/`, not in the `RUN` lines, and the Dockerfile is
one of its callers:

| script | what it does | called by |
| --- | --- | --- |
| `scripts/fetch-compiler.sh` | coursier -> `cp/` and `lib/` | `compiler-maven` stage, CI |
| `scripts/jdk-classes.sh` | `jimage extract` + `jar` -> `java.base.jar` | `jdkclasses` stage, `build-native.sh` |
| `scripts/build-native.sh` | ScalacMain, agent run, metadata, native-image, bundle | `nativebuild` stage, CI |
| `scripts/smoke-test.sh` | compiles and *runs* five cases against a bundle or an image | every CI job |
| `scripts/common.sh` | path/classpath handling, so the same scripts work in Git Bash | the others |

Building on a machine with GraalVM and coursier on `PATH`, no Docker involved:

```bash
scripts/fetch-compiler.sh 3.9.0 cp lib
scripts/build-native.sh --cp-dir cp --lib-dir lib --out-dir bundle --xmx 12g
scripts/smoke-test.sh --bundle bundle
```

`.github/workflows/release.yml` runs exactly that on macOS and Windows, and
builds Linux through the Dockerfile so the published binary is the same one that
is inside the published image. Platform coverage:

| target | how | note |
| --- | --- | --- |
| Linux x86_64 | Dockerfile on `ubuntu-24.04` | also the `linux/amd64` image |
| Linux aarch64 | Dockerfile on `ubuntu-24.04-arm` | also the `linux/arm64` image |
| macOS arm64 | scripts on `macos-15` | slim only: a 7 GB runner, and macros peaks near 10.4 GiB |
| Windows x86_64 | scripts on `windows-2025` | needs the MSVC toolchain for linking |
| macOS x86_64 | not built | GraalVM Community dropped `macos-x64` at JDK 25 |
| Windows arm64 | not built | no GraalVM Community `windows-aarch64` build exists |

Do not build the arm64 image with QEMU emulation on an x86 runner. native-image
under emulation is extremely slow and unreliable; use the native arm64 runner,
which is free for public repositories.

Peak native-image heap, which is what decides whether a runner is big enough:

| flavour | peak heap | build time (96-core host) |
| --- | ---: | ---: |
| slim | 4.2 GiB | 1 min 35 s |
| macros | 10.4 GiB | 5 min 03 s |

## Why there is a wrapper main class

A native image has no `jrt:/` filesystem and no `java.home`, so dotc finds zero
JDK classes and dies with `asTerm called on not-a-Term val <none>`
(oracle/graal#8371). The fix is to hand it JDK classes via `-bootclasspath`.
`ScalacMain` locates `java.base.jar` and `lib/` next to the executable using
`ProcessProperties.getExecutableName()`, so the binary stays self-contained and
works from any working directory -- no launcher script, no `ENV` juggling.

Use a **jar**, not the `jimage`-extracted directory: dotc rescans that 250 MB
tree on every invocation, costing a flat ~0.14 s, which is two thirds of a
hello-world compile.

## The `MACROS` build arg

Macro expansion loads and runs the macro implementation's class file, which a
closed-world image cannot do. `MACROS=true` turns on three things together --
all three are required, and each one only reveals the next failure if missing:

1. `-H:+RuntimeClassLoading` -- lets the image load and interpret class files at
   run time (implies open world).
2. every compiler/library class registered for reflection
   (`gen-reflect-metadata.py`, ~9200 entries). Without it
   `Class.forName("scala.quoted.Quotes")` throws inside the image, parent
   delegation falls through, the macro class loader defines a *second* `Quotes`,
   and macros die with `AbstractMethodError`.
3. `-H:Preserve=...` -- registering types is not enough; members must be
   preserved or the interpreter fails with `Cannot load undefined field:
   scala/quoted/Expr$.MODULE$` or `Unable to call AOT method:
   ConcurrentHashMap.<init>`.

Measured cost (best of 3 cold runs, byte-identical output in every case):

| benchmark | jvm | `:slim` | `:macros` |
| --- | ---: | ---: | ---: |
| helloWorld | 1.60 s | 0.06 s | 0.10 s |
| dottyUtil | 4.91 s | 0.55 s | 0.78 s |
| re2s | 4.90 s | 0.88 s | 1.24 s |
| tastyQuery | 8.99 s | 2.61 s | 3.64 s |
| sourcecode (macros) | 4.40 s | **broken** | 0.71 s |

`:slim` does not fail loudly on macro code -- it emits the macro-*defining*
class files and then errors on every use site, with the misleading message
`Cyclic macro dependencies in <file>` even when the macro is defined in a
separate file or on the classpath. If your users compile anything with macros,
ship `:macros`.

**The `-H:Preserve` set is hand-tuned** to what the macro libraries tested so far
happen to touch. A macro reaching into an unpreserved package will still hit
`Unable to call AOT method`. `-H:Preserve=all` is the principled fix; it is much
slower to build and was not measured here.

## `COMPILER_SOURCE`: published artifacts vs building dotty

- `maven` (default) -- `cs fetch org.scala-lang:scala3-compiler_3:$SCALA_VERSION`.
  Seconds, and the layer caches on the version string alone.
- `git` -- clones scala3 and runs `sbt dist/Universal/stage`, then collects the
  jars that the staged `bin/scala` launcher's manifest points at (the
  `dist/pack` task no longer exists). Slow (bootstrap), needs a lot of memory,
  and the sbt/coursier caches are kept via BuildKit cache mounts so rebuilds
  are not catastrophic. Use for testing an unreleased compiler:

```bash
docker build -t scalac-native:dev \
  --build-arg COMPILER_SOURCE=git --build-arg DOTTY_REF=main .
```

## Do not publish an image built with `-march=native`

`NI_OPT` defaults to `-O3`, which targets `x86-64-v3` (Haswell, 2013+). Adding
`-march=native` is worth ~10-20% but bakes in the *build machine's* CPU features,
so the published image dies with SIGILL on anything older. Only use it for images
you build and run on the same machine:

```bash
docker build --build-arg NI_OPT="-O3 -march=native" -t scalac-native:local .
```

`NI_XMX` (default `16g`) and `NI_PARALLELISM` (default `8`) bound the builder;
raise them on a big machine, lower them in CI.

## Layers, and what actually caches

Stages are ordered so the expensive work is reused:

1. `graalvm` -- base + GraalVM tarball. Changes only when the version args change.
2. `compiler-maven` / `compiler-git` -- the compiler classpath.
3. `jdkclasses` -- `jimage extract` + `jar`. Independent of the compiler, so it
   is built once and reused across both flavours, and in parallel with stage 2.
4. `nativebuild` -- agent training run, then `native-image`. Always the long pole
   (~1 min slim, ~3 min macros).
5. `artifact` (`scratch`, the exportable files) and `runtime`
   (`debian:trixie-slim` + `zlib1g`). Both copy the same `/out` directory, so
   the exported binary and the one in the image are the same bytes.

For a smaller runtime, `--static --libc=musl` produces a binary that runs on
`scratch`, at the cost of installing musl and a musl build of zlib in the
builder. Not done here.
