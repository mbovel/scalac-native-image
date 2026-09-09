# Evaluation

[`eval.sh`](eval.sh) measures cold and warm compile time for four configurations of the same
Scala 3 compiler, and checks that all four emit the same bytes.

| configuration | what it is |
| --- | --- |
| `jvm` | `java -cp <compiler jars> dotty.tools.dotc.Main` |
| `jvm-aot` | the same, with a JDK 25 AOT cache (JEP 483/514/515) trained per benchmark |
| `native-O3` | the `:slim` image — `native-image -O3`, closed world |
| `native-rcl-O3` | the `:macros` image — `-O3` plus **rcl**, runtime class loading (`-H:+RuntimeClassLoading`) |

```bash
bench/eval.sh                        # builds both images, runs everything, ~1 h
bench/eval.sh --quick                # helloWorld and sourcecode, 1 rep: a few minutes
bench/eval.sh --slim DIR --rcl DIR   # reuse bundles exported earlier
bench/eval.sh --help
```

It needs `java` (JDK 24+ for the AOT cache — without it `jvm-aot` is skipped and said so),
`bash` 5+ (for `$EPOCHREALTIME`), and either Docker or a pair of bundles from a previous
`docker build --target artifact`. The compiler jars come from coursier unless `--cp-dir` points at them.

## What it measures

- **Cold** is the best of `--reps` fresh processes (default 3). Best-of, not mean: the fastest
  run is the one least perturbed by whatever else the machine was doing.
- **Warm** is the min of the last `--warm-tail` of `--iterations` compiles in a single process
  (default: last 5 of 20), the same on both sides.

  20 is not generous. The JVM is warming a JIT and takes a long time about it: at 20 iterations
  `dottyUtil`, `helloWorld` and `areWeFastYet` were still gaining 9-11% between the mean of
  iterations 8-13 and that of 14-19, with their minima landing at iteration 17-19. `tastyQuery`,
  `re2s`, `scalaz` and `sourcecode` were converged (0-3%).

  The images have no JIT, and it is tempting to conclude they need only a handful of compiles.
  That was measured and it is false. What they do gain is dotc's own caches filling, the
  `java.base.jar` zip index being read once, and the heap growing so the serial GC runs less --
  small on the large benchmarks, but on `dottyUtil` the native image improves until iteration 9
  and on `re2s` until iteration 11. Cutting them to 4 compiles made those two look 43% and 27%
  slower than they are. So both sides get the same count.

  "Warm" therefore means the steady state of a resident compiler process, which is a fair
  question to ask of either. Just do not assume the native side is flat: check the curve in
  `logs/warm-<benchmark>-<config>.log` before trusting a number.

> [!WARNING]
> 20 compiles is still not enough for the smaller benchmarks. Between the mean of iterations
> 8-13 and that of 14-19, `dottyUtil`, `helloWorld` and `areWeFastYet` were still gaining 9-11%,
> with their minima at iteration 17-19, so their warm numbers are upper bounds rather than steady
> state. `tastyQuery`, `re2s`, `scalaz` and `sourcecode` are converged at 0-3%.
>
> scala3-benchmarks itself uses a per-benchmark iteration count -- 180 for hello world. Using one
> count for everything is the simplification made here, and the small and mid-sized benchmarks are
> exactly where both of the surprises above turned up.

The JVM half of the warm loop is [`Loop.java`](Loop.java). The native half is built into the
shipped binary: `SCALAC_BENCH_ITERATIONS=N` makes it compile its arguments N times in one
process, printing `iter i: T ms`. That hook exists so the warm number describes the executable
people actually download, rather than a second image built only for benchmarking.

## Why the output diff is the real test

A native image built without the tracing agent's reachability metadata still builds, still exits
zero, and still writes class files — that fail verification when you run them, because the
backend's reflectively-accessed lazy-val fields were never initialised. Timing such an image
would produce a very impressive and completely meaningless number.

So `eval.sh` diffs every configuration's class files and TASTy against the JVM's, reports the
result in the `output` column, and exits non-zero if any of them differ. A time is only printed
for a run that both exited zero and matched.

## Reproducing the numbers in the README

The corpus is [scala3-benchmarks](https://github.com/lampepfl/scala3-benchmarks) pinned to
`99ac20c5476e`, with the same source selections and compiler flags its own `build.sbt` uses:
`-feature -Werror -deprecation` throughout, plus the per-project flags in `extra_of` for
`tastyQuery`, `scalaz` and `areWeFastYet`.

The seven benchmarks span four orders of magnitude, from one file to `scalaz`'s 40'633 lines.
Two are there for a specific reason: `sourcecode` is a macro library, the one case that separates
the two native builds, and `scalaz` is large enough that the native image's cold advantage runs
out — the rest of the corpus only shows that advantage shrinking.

Adding another is usually two lines, a `find` in `srcs_of` and any flags in `extra_of`, as long as
the benchmark compiles against the standard library alone. `parserCombinators`, `scalaYaml`,
`fansi`, `caskApp`, `scalaToday`, `tictactoe` and `indigo` need third-party jars, which would have
to be fetched and appended to the `-classpath` in `ARGS`.

The README's table was produced on an otherwise idle 96-core Ubuntu machine with GraalVM CE
25.3.4.1 (JDK 25.0.4.1) and Scala 3.9.0, at default heap. Expect different absolute numbers
elsewhere; the ratios are the portable part.

The `Evaluation dry run` workflow runs `--quick` on every change to `bench/` or `docker/`. Its
timings are not comparable to the above — a shared 4-core runner is fine for "the script still
works and the output still matches" and useless for anything else.

## Gotchas worth knowing before you change this

- The AOT cache refuses a classpath containing a non-empty **directory** (`Cannot have non-empty
  directory in paths`), which is why the loop harness is packaged as a jar.
- `-XX:AOTCacheOutput` only writes the cache if the training run exits normally.
- With `-H:+RuntimeClassLoading` the real module system is active at run time, so a jar in the
  working directory whose classes are in the default package breaks startup with `Unable to
  derive module descriptor`. `eval.sh` runs from a clean directory and keeps `loop.jar`
  elsewhere for exactly this reason.
- `docker build --output type=local` does not preserve the executable bit; `chmod +x` the
  exported `scalac` before passing it to `--slim`/`--rcl`.
