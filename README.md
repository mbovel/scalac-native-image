# scalac-native-image

The Scala 3 compiler (`dotty.tools.dotc.Main`) built into a native executable with GraalVM
native-image, published as a Docker image and as standalone binaries for Linux, macOS and Windows.

The point is start-up time. `scalac` on the JVM spends over a second loading and JIT-compiling itself
before it looks at your code, which is most of the cost of compiling anything small.

Two flavours, because macros are the hard part:

| tag | native-image build | binary | macros |
| --- | --- | ---: | --- |
| `:slim` | `-O3`, closed world | 113 MB | no |
| `:macros` | `-O3` plus `-H:+RuntimeClassLoading` | 452 MB | yes |

> [!NOTE]
> This repository is a proof of concept, vibe-coded end to end with Claude Code — the build
> scripts, the Dockerfile, the CI workflows, the evaluation harness and this README. The
> measurements below are real and reproducible with `bench/eval.sh`, and the compiler's output is
> checked byte-for-byte against the JVM's on every run; the code around them has had far less
> human review than its volume suggests. Read it with that in mind.

## Results

Scala 3.9.0 and GraalVM CE 25.3.4.1, on an otherwise idle 96-core Linux x86_64 machine; the JVM
configurations run on Temurin 25.0.3 at default heap. The corpus is
[scala3-benchmarks](https://github.com/lampepfl/scala3-benchmarks) at `99ac20c5476e`, compiled
with the same flags its own `build.sbt` uses.

The four configurations are `jvm` (`dotty.tools.dotc.Main` on the JVM), `jvm-aot` (the same with
a JDK 25 AOT cache trained per benchmark), and the two published images: `native-O3` is `:slim`,
built closed-world, and `native-rcl-O3` is `:macros`, built with **rcl** — GraalVM's *runtime
class loading*, `-H:+RuntimeClassLoading` — which is what lets it expand macros.

Every number below is a compile whose class files and TASTy came out byte-for-byte identical to
the JVM compiler's. `bench/eval.sh` reports no time for anything else, which matters more than it
sounds — see [step 1](#1-record-reachability-metadata-with-the-tracing-agent).

### Cold — best of 3 fresh processes

| benchmark | LOC | jvm | jvm-aot | native-O3 | native-rcl-O3 |
| --- | ---: | ---: | ---: | ---: | ---: |
| helloWorld | 5 | 1.50 s | 0.71 s | **0.07 s** | 0.10 s |
| dottyUtil | 3'119 | 4.45 s | 2.55 s | **0.55 s** | 0.77 s |
| areWeFastYet | 4'590 | 4.52 s | 2.70 s | **0.82 s** | 1.06 s |
| re2s | 11'027 | 4.41 s | 2.50 s | **0.89 s** | 1.25 s |
| tastyQuery | 18'912 | 8.41 s | 5.13 s | **2.59 s** | 3.62 s |
| scalaz | 40'633 | 19.04 s | **13.40 s** | 19.73 s | 27.55 s |
| sourcecode (macros) | 807 | 4.09 s | 2.33 s | cannot | **0.69 s** |

### Warm — min of the last 5 of 20 compiles in one process

| benchmark | jvm | jvm-aot | native-O3 | native-rcl-O3 |
| --- | ---: | ---: | ---: | ---: |
| helloWorld | 73 ms | 84 ms | **33 ms** | 44 ms |
| dottyUtil | **394 ms** | 534 ms | 463 ms | 662 ms |
| areWeFastYet | **457 ms** | 569 ms | 810 ms | 958 ms |
| re2s | **518 ms** | 583 ms | 860 ms | 1151 ms |
| tastyQuery | **1571 ms** | 1817 ms | 2684 ms | 3588 ms |
| scalaz | **8784 ms** | 9209 ms | 15902 ms | 25452 ms |
| sourcecode (macros) | **373 ms** | 462 ms | cannot | 583 ms |

Reading:

- **Cold, the native image wins until the compile gets big.** 21x on hello world, 8.1x on
  `dottyUtil`, 3.2x on `tastyQuery` — the advantage tracks how much of the run is start-up, so it
  shrinks as the compile grows. On `scalaz`, at 40'000 lines, it runs out: 19.73 s against the
  JVM's 19.04 s. The crossover sits between `tastyQuery` and `scalaz`, and past it the AOT-cached
  JVM is the fastest thing here at 13.40 s.
- **Warm, the JVM wins everything except hello world.** Give the JIT 20 compiles in one process
  and it beats the native image by 1.2x on `dottyUtil` and 1.7-1.8x on the larger benchmarks. Only
  hello world stays native's (2.2x), because it is too small for the JIT to ever pay itself off.
- **So this is a start-up tool.** It is the right thing for short compiles, one-shot invocations,
  CI and editor round-trips, and the wrong thing for a long-lived compile server, where a warm JVM
  is faster and a warm JVM is what you have.
- **The AOT cache is the JVM's best answer cold, and does nothing warm.** It takes 1.4-2.1x off
  cold time, enough to win `scalaz` outright. At peak it is *slower* than the plain JVM on all
  seven benchmarks — it buys class loading and linking, not throughput.
- **Runtime class loading costs 1.3-1.4x** cold, steady across benchmarks. That is the price of
  the only configuration that compiles macro code at all, and on `sourcecode` it is still 5.9x
  faster cold than the JVM that can.

The dry-run workflow re-runs a subset of this on every change; its timings are not comparable, and
it exists to catch the script breaking and the output diverging. See [bench/](bench/README.md).

## Using it

```bash
docker run --rm -v "$PWD:/src" -w /src mbovel/scalac-native-image:slim -d out hello.scala
```

The images are published to Docker Hub as
[`mbovel/scalac-native-image`](https://hub.docker.com/r/mbovel/scalac-native-image), tagged
`:slim`, `:macros`, `:<scala-version>-<flavour>` and `:latest`, for `linux/amd64` and
`linux/arm64`.

No flags needed: the entry point supplies `-bootclasspath` and a default `-classpath` itself.
Both are only defaults — pass either flag and yours wins.

Standalone binaries for Linux x86_64/aarch64 and macOS arm64 are attached to each release.
Windows is not currently built: native-image cannot link its own query code on the GitHub runners
(`LNK1104: cannot open file 'LIBCMT.lib'`), on both the VS 2022 and VS 2026 images. The job is
disabled rather than removed, in `.github/workflows/release.yml`. Unpack the directory and keep it together: the executable looks for `java.base.jar` and
`lib/` next to itself.

If the code you compile uses macros — most Scala libraries do somewhere — use `:macros`. `:slim`
does not fail loudly on macro code: it emits the macro-*defining* class files and then errors on
every use site, with the misleading message `Cyclic macro dependencies`.

## Layout

| path | what |
| --- | --- |
| [docker/](docker/README.md) | the image, the standalone bundles, and the shared build scripts |
| [bench/](bench/README.md) | the four-configuration evaluation |
| [.github/workflows/release.yml](.github/workflows/release.yml) | multi-platform binaries and multi-arch images |
| [.github/workflows/bench.yml](.github/workflows/bench.yml) | the evaluation dry run |
| [.devcontainer/](.devcontainer/devcontainer.json) | the development container |

## How it works

Three build-time measures turn `dotty.tools.dotc.Main` into a working native executable. They
address different failures and are needed together — a build can have two of the three and still
be badly wrong, because the first one below fails silently.

### 1. Record reachability metadata with the tracing agent

dotc leans on reflection throughout — it loads classes and plugins by name, reads resources like
`compiler.properties`, and reaches into its own backend's fields. Closed-world analysis sees none
of that. The loud failures are easy; the dangerous one is silent. The image builds, runs, exits
zero, and writes class files that are wrong in a way that only surfaces when you run them:

```
java.lang.VerifyError: Constructor must call super() or this() before return
```

The culprits are the lazy-val holders in `BCodeSkelBuilder`, `BackendUtils` and friends. With
those fields dropped, the bytecode emitter runs with uninitialised state and writes malformed
constructors.

So compile something once under `-agentlib:native-image-agent` and build with
`-H:ConfigurationFileDirectories`. The tracing-agent run is not optional.

Thanks to [@mukel](https://github.com/mukel), who worked out the tracing and reflection
configuration, and to [@KomOnni](https://github.com/KomOnni), who spotted on the issue that the
missing piece was `-H:ConfigurationFileDirectories`.

This failure mode is why the evaluation diffs every configuration's output against the JVM's
rather than trusting an exit code: an image with this bug still "succeeds" at everything a
smoke test would check, and would benchmark beautifully.

### 2. Supply the JDK classes on `-bootclasspath`

With the metadata in place the image builds and runs, and then dies before compiling anything:

```
java.lang.AssertionError: assertion failed: asTerm called on not-a-Term val <none>
	at dotty.tools.dotc.core.Definitions.ObjectClass(Definitions.scala:327)
```

This is [oracle/graal#8371](https://github.com/oracle/graal/issues/8371), and it is not a GraalVM
bug. `PathResolver.basis` sources JDK classes from exactly two places: the `jrt:/` filesystem, and
`sun.boot.class.path`. A native image has no `jrt:/` and no `java.home`, and `sun.boot.class.path`
has been gone since JDK 9. So dotc starts with an empty JDK classpath, cannot find
`java.lang.Object`, and `defn.ObjectClass` is `NoSymbol`. The assertion is a poor error message
for "no JDK on the classpath".

So `jimage extract` the JDK, package `java.base` as a jar, and pass it as `-bootclasspath`.
[`ScalacMain`](docker/ScalacMain.java) locates that jar next to the executable via
`ProcessProperties.getExecutableName()`, so the binary stays self-contained and works from any
directory. Use a **jar**, not the extracted 250 MB tree — dotc rescans the tree on every
invocation, a flat ~0.14 s, which is two thirds of a hello-world compile.

Thanks to [@sjrd](https://github.com/sjrd), who worked out that this was what the native image was
missing. The first build that compiled hello world used the jar produced by tasty-query's
[`javalibEntry`](https://github.com/scalacenter/tasty-query/blob/main/build.sbt#L176-L206) task
([issue comment](https://github.com/oracle/graal/issues/8371#issuecomment-1944311407));
`docker/scripts/jdk-classes.sh` does the same thing with `jimage` and `jar`.

### 3. Enable runtime class loading, for macros

Macro expansion loads the macro implementation's class file and runs it. Those class files are
produced after image build time, which a closed-world image cannot do at all — so `:slim` compiles
the macro *definitions*, then fails on every use site.

Three things together get macros working, and all three are required:

1. `-H:+RuntimeClassLoading`, which lets the image load and interpret class files at run time and
   implies an open world.
2. Every compiler and library class registered for reflection (~9200 entries). Without it,
   `Class.forName("scala.quoted.Quotes")` throws inside the image, parent delegation falls
   through, the macro class loader defines a *second* `Quotes`, and macros die with
   `AbstractMethodError`.
3. `-H:Preserve=...`, because registering types is not enough — members must be preserved too, or
   the interpreter fails with `Cannot load undefined field: scala/quoted/Expr$.MODULE$`.

Each of the three only reveals the next failure if it is missing, which is what makes this one
hard to arrive at incrementally. [docker/README.md](docker/README.md) has the exact flags.

## Run the benchmarks

```bash
bench/eval.sh              # builds both images, runs everything
bench/eval.sh --quick      # a few minutes, what CI runs
bench/eval.sh --help
```

[bench/README.md](bench/README.md) documents the methodology: cold is the best of 3 fresh
processes, warm is the min of the last 5 of 12 compilations in one process, the corpus is pinned
to a commit, and every configuration's output is diffed against the JVM's — a time is only
reported for a run that both exited zero and matched.

## Building

```bash
cd docker
docker build -t scalac-native-image:slim .
docker build -t scalac-native-image:macros --build-arg MACROS=true .
```

The build flow lives in `docker/scripts/`, which the Dockerfile calls and which also runs
directly on machines without Docker. That is how
[.github/workflows/release.yml](.github/workflows/release.yml) builds the macOS and Windows
binaries: native-image only ever targets the machine it runs on, so those platforms cannot go
through a Linux container. Linux goes through the Dockerfile, so the published binary is
byte-for-byte the one inside the published image.

Publishing a GitHub Release runs that workflow, which pushes the images and attaches the binaries
to the release once the builds finish — so a freshly published release has no assets for the
first quarter of an hour. `workflow_dispatch` runs it by hand. Either way it needs a
`DOCKERHUB_TOKEN` secret (a Docker Hub access token with Read & Write on the repository); without
one, run it with `publish-images` off.

## Development container

[.devcontainer/](.devcontainer/devcontainer.json) is a VS Code dev container with GraalVM CE 25
(`native-image`, `native-image-agent`), sbt, coursier and scala-cli, for working on this
repository or on the compiler itself. Open the folder and choose **Reopen in Container**; the
first build downloads about 400 MB.

It also keeps Claude Code's sign-in in the project-scoped Docker volume
`scala3-graal-claude-config`, so the account used here is independent from the host's and from
other projects. `docker volume rm scala3-graal-claude-config` forgets it. Dependency caches live
in `scala3-graal-{coursier-cache,sbt,ivy2}` and survive rebuilds.

To work on the compiler, clone it into the workspace (bind-mounted from the host, so the clone
persists) and build with sbt; `sbt buildQuick` writes a compiler classpath to `bin/.cp` that can
be handed to `docker/scripts/build-native.sh --cp-dir`.
