# Reproducing oracle/graal#8371 on GraalVM 25 + Scala 3.9.0

Date: 2026-09-08. GraalVM CE 25.3.4.1 (JDK 25.0.4.1), `native-image` 25.0.4.1,
Scala 3.9.0 (latest stable; 3.10.0-RC1 is the newest RC).

## Result: still reproduces, identically

`./build.sh` builds the image fine (40 s, 61 MiB). Running it fails exactly as
in the 2024 report:

```
$ ./scalac-native -classpath "$(cat cp.txt)" -d out-native hello.scala
Exception in thread "main" java.lang.AssertionError: assertion failed: asTerm called on not-a-Term val <none>
	at dotty.tools.dotc.core.Symbols$Symbol.asTerm(Symbols.scala:190)
	at dotty.tools.dotc.core.Definitions.ObjectClass(Definitions.scala:327)
	...
	at dotty.tools.dotc.core.Definitions.init(Definitions.scala:2236)
```

## Root cause: dotc gets no JDK classpath in a native image

`probe/JrtProbe.java`, built as a native image, shows:

```
java.home           = null
provider            : file / resource / jar        (no jrt)
jrt:/ FAILED        = java.nio.file.ProviderNotFoundException: Provider "jrt" not found
```

`PathResolver.basis` (compiler/src/dotty/tools/dotc/config/PathResolver.scala)
sources JDK classes from only two places, and both are empty here:

1. `JrtClassPath(release)` — the `jrt:/` filesystem, or `ct.sym` when `-release`
   is given. `DirectoryClassPath.scala:125-140` catches `ProviderNotFoundException`
   and returns `None`; the `ct.sym` branch needs `Properties.javaHome`, which is
   `null`.
2. `classesInPath(javaBootClassPath)` — `sun.boot.class.path`, gone since JDK 9.

So the compiler starts with zero JDK entries, cannot find `java.lang.Object`,
and `defn.ObjectClass` is `NoSymbol`. The assertion is just a poor error message
for "no JDK on the classpath" — not a GraalVM bug.

## Workarounds (both work, verified)

A. Supply the JDK classes explicitly:

```bash
jimage extract --dir=jdk-classes $JAVA_HOME/lib/modules   # 250 MB, or:
jar --create --file java.base.jar -C jdk-classes/java.base .   # 14 MB
./scalac-native -bootclasspath java.base.jar -classpath "$LIBCP" -d out hello.scala
```

Output is **byte-for-byte identical** to the JVM compiler's. Add further
`jdk-classes/java.<module>` entries for code that needs more than `java.base`.

B. Re-enable the `ct.sym` path by setting `java.home` at runtime (native images
do parse `-D`), with any `-release` below the image's JDK feature version:

```bash
./scalac-native -Djava.home=$JAVA_HOME -release 21 -classpath "$LIBCP" -d out hello.scala
```

### Comment #4's "corrupted bytecode": missing reachability metadata

It does not reproduce in any build here - but only because every build here
passed `-H:ConfigurationFileDirectories`. Building the *same* image without
agent-recorded metadata reproduces it exactly:

```
$ ./scalac -d out hi.scala        # image built with no -H:ConfigurationFileDirectories
$ java -cp out hi
java.lang.VerifyError: Constructor must call super() or this() before return
  Location: hi.<init>()V @0: return
```

Rebuild with `-H:ConfigurationFileDirectories=ni-config` (recorded by running
dotc once under `-agentlib:native-image-agent`) and the output is byte-identical
to the JVM compiler's. The agent registers the backend's reflectively-accessed
lazy-val fields (`BCodeSkelBuilder$PlainSkelBuilder.bc$lzy1`, `locals$lzy1`,
`BackendUtils.*`, ...); without them the emitter runs with uninitialised state
and writes invalid constructors.

So comment #4 was not a deeper bug, and comment #6 - which reported success
using `-H:ConfigurationFileDirectories=native-image-config` - was the fix all
along. **The tracing-agent run is not optional.**

## Benchmarks (scala3-benchmarks, same flags as its build.sbt)

Best of 3 cold runs per cell, JVM with `-Xms8G -Xmx8G` as its JMH config uses,
native with `-bootclasspath java.base.jar`. `native-O3` is the image built with
`-O3 -march=native` (113 MB vs 64 MB). "output" compares the emitted class files
and TASTy against the JVM compiler's, recursively.

| benchmark  | files |    jvm | native | native -O3 | output    |
|------------|------:|-------:|-------:|-----------:|-----------|
| helloWorld |     1 |  1.55s |  0.07s |      0.06s | identical |
| dottyUtil  |    34 |  4.84s |  0.60s |      0.53s | identical |
| re2s       |    17 |  4.87s |  1.03s |      0.86s | identical |
| sourcecode |    20 |  4.31s |   FAIL |       FAIL | macro CNFE (below) |
| tastyQuery |    49 |  9.42s |  2.98s |      2.62s | identical |
| scalaz     |   292 | 19.69s | 22.42s |     19.66s | identical |

All 20 single-file benchmarks in `bench-sources/small`, jvm vs native-O3:

| benchmark | jvm | native-O3 | speedup | | benchmark | jvm | native-O3 | speedup |
|---|---:|---:|---:|---|---|---:|---:|---:|
| exhaustivityI | 2.16s | 0.14s | 15.4x | | implicitScopeLoop | 1.71s | 0.09s | 19.0x |
| exhaustivityS | 1.87s | 0.08s | 23.4x | | matchTypeSort | 2.33s | 0.31s | 7.5x |
| exhaustivityT | 1.87s | 0.07s | 26.7x | | patmatexhaust | 2.62s | 0.20s | 13.1x |
| exhaustivityV | 1.81s | 0.07s | 25.9x | | tuple | 1.91s | 0.09s | 21.2x |
| findRef | 1.52s | 0.05s | 30.4x | | tuple22Apply | 1.77s | 0.07s | 25.3x |
| helloWorld | 1.55s | 0.06s | 25.8x | | tuple22Cons | 1.81s | 0.09s | 20.1x |
| i1535 | 1.97s | 0.09s | 21.9x | | tuple22Creation | 1.62s | 0.06s | 27.0x |
| i1687 | 1.54s | 0.06s | 25.7x | | tuple22Size | 1.67s | 0.07s | 23.9x |
| implicitCache | 1.70s | 0.09s | 18.9x | | tuple22Tails | 1.80s | 0.08s | 22.5x |
| implicitInductive | 2.55s | 0.56s | 4.6x | | implicitNums | 2.57s | 0.20s | 12.8x |

Every one is byte-identical to the JVM compiler's output.

So the speedup tracks compile size, and the crossover sits between tastyQuery
(13'482 LOC, native 3.2x faster) and scalaz (27'757 LOC, native 14% slower,
back to par with -O3). The two small benchmarks that gain least
(`implicitInductive` 4.6x, `matchTypeSort` 7.5x) are the type-level-computation
ones, where throughput of the compiler's own code matters more than startup.

Warm-up curves (`Loop.java`, 12 iterations of the same compile in one process)
explain the shape - native is flat, the JIT converges below it:

```
dottyUtil   jvm    5274 1666 1282 878 814 844 742 813 611 548 514 518 ms
dottyUtil   native  714  883 1072 921 770 821 687 643 662 667 664 646 ms
tastyQuery  jvm    9393 3722 2645 2425 2253 2263 2228 2177 1990 1820 1935 1931 ms
tastyQuery  native 3598 3145 3686 3588 3188 3481 3381 3592 3563 3899 3667 3882 ms
helloWorld  jvm    1443  194  147 145 130 113 110 103 101  99  97  90 ms
helloWorld  native   72   71   41  73  41  59  41  55  40  55  40  53 ms
```

Note hello world is the one case where native stays ahead even warm (~40-55 ms
vs ~90-100 ms): the compile is too small for the JVM to ever amortize.

Peak RSS is 4-6x lower for the native image (measured with the directory
bootclasspath: dottyUtil 781 -> 135 MB, tastyQuery 1071 -> 235 MB,
scalaz 2093 -> 882 MB). `-Xmx8g` at runtime does not help; serial GC is the
only GC in GraalVM CE.

### Comparison with the JDK 25 AOT cache (JEP 483/514/515)

The AOT cache works on dotc. Caches are trained per benchmark on that same
benchmark (the best case for the JVM), one step with JEP 514 ergonomics:

```bash
java -XX:AOTCacheOutput=dotc.aot -cp "$CP" dotty.tools.dotc.Main <args>   # train + create
java -XX:AOTCache=dotc.aot      -cp "$CP" dotty.tools.dotc.Main <args>    # use
```

Caches are 49-54 MB and serve ~4100 classes (`-Xlog:class+load` counts
"shared objects file"). Two gotchas: the classpath may contain **only jars** -
a non-empty directory fails with "Cannot have non-empty directory in paths" -
and `-XX:AOTCacheOutput` needs the training run to exit normally.

Cold, best of 3 fresh processes:

| benchmark  | native-O3 |    jvm | jvm-aot | aot gain | native vs aot |
|------------|----------:|-------:|--------:|---------:|--------------:|
| helloWorld |     0.06s |  1.64s |   1.02s |    1.61x |         17.0x |
| dottyUtil  |     0.55s |  5.12s |   4.51s |    1.14x |          8.2x |
| re2s       |     0.91s |  5.09s |   4.70s |    1.08x |          5.2x |
| tastyQuery |     2.77s | 10.09s |   8.88s |    1.14x |          3.2x |

Warm, min of the last 5 of 12 in-process iterations:

| benchmark  | native-O3 |    jvm | jvm-aot | iter 0 native/jvm/aot |
|------------|----------:|-------:|--------:|-----------------------|
| helloWorld |      32ms |   84ms |    70ms | 60 / 1388 / 931 ms    |
| dottyUtil  |     404ms |  477ms |   529ms | 530 / 4823 / 4209 ms  |
| re2s       |     723ms |  672ms |   588ms | 870 / 5022 / 4287 ms  |
| tastyQuery |    2757ms | 1595ms |  1964ms | 2631 / 8843 / 8636 ms |

Reading:

- The AOT cache buys back a **fixed** cost (class loading and linking, ~0.6s),
  not a proportional one: 1.61x on hello world, 8-14% once real compilation
  dominates. It closes about a quarter of the gap to native on hello world and
  almost none on tastyQuery.
- It does **not** improve peak throughput and can perturb it (warm: better on
  helloWorld and re2s, worse on dottyUtil and tastyQuery). Where it helps
  consistently is in-process iteration 0, which is JEP 515 profile priming
  showing up and then washing out.
- Native's warm crossover is earlier than its cold one. Cold it wins all four;
  warm it wins helloWorld (2.2-2.6x) and dottyUtil, ties re2s, and loses
  tastyQuery by 1.7x.

The JVM here is GraalVM CE's default **Graal JIT** (`UseJVMCICompiler=true`),
not stock C2. Checked, and it does not change the conclusions - C2 is within
~6% cold and *slower* at peak on tastyQuery, so the numbers above are the
stronger JVM case:

| config | helloWorld cold / warm | tastyQuery cold / warm |
|---|---|---|
| Graal JIT | 1.58s / 89ms | 9.57s / 1681ms |
| C2        | 1.51s / 84ms | 9.00s / 2070ms |

### Memory

Peak RSS (`/usr/bin/time %M`), median of 3. "cold" is one compile per process,
"warm" is the peak over 12 in-process iterations. `-Xmx8G` is what the JMH
config in scala3-benchmarks uses; the unlabelled jvm columns are default heap.

| benchmark  | native-O3 |   jvm | jvm-aot | jvm -Xmx8G | jvm-aot -Xmx8G |
|------------|----------:|------:|--------:|-----------:|---------------:|
| helloWorld |  92 MB    | 512MB |  444 MB |    668 MB  |        514 MB  |
| dottyUtil  | 167 MB    | 647MB |  664 MB |    798 MB  |        798 MB  |
| re2s       | 185 MB    | 771MB |  836 MB |    975 MB  |        948 MB  |
| tastyQuery | 261 MB    | 869MB |  887 MB |   1077 MB  |       1043 MB  |

Warm (peak over 12 iterations):

| benchmark  | native-O3 |    jvm | jvm-aot | jvm -Xmx8G |
|------------|----------:|-------:|--------:|-----------:|
| helloWorld |    148 MB |  853MB |  858 MB |    1105 MB |
| dottyUtil  |    257 MB | 1037MB | 1099 MB |    1409 MB |
| re2s       |    313 MB | 1251MB | 1301 MB |    2576 MB |
| tastyQuery |    416 MB | 1972MB | 1572 MB |    4042 MB |

So native uses 3.3-5.6x less cold and 4.7-6.2x less warm, and the gap widens
with warm-up because the JVM heap grows to whatever it is allowed while the
SVM serial GC stays frugal.

**But most of that is GC laziness, not need.** Bisecting the smallest `-Xmx`
at which each configuration still completes the compile, with the wall time of
that run in parentheses:

| benchmark  |  native-O3 |         jvm |     jvm-aot |
|------------|-----------:|------------:|------------:|
| helloWorld | 24m (0.16s)| 24m (2.66s) | 24m (1.35s) |
| dottyUtil  | 48m (1.20s)| 64m (5.69s) | 64m (4.45s) |
| re2s       | 64m (1.70s)| 96m (5.04s) | 96m (4.38s) |
| tastyQuery |128m (3.90s)|128m (9.57s) |128m (8.52s) |

Everything fits in <=128 MB, and on the largest benchmark all three converge on
the same 128m floor - tastyQuery shows 869-1077 MB RSS at default heap but
needs 128 MB. Native's memory advantage is therefore about *defaults*, not
capability: it is frugal without being asked, the JVM needs an explicit `-Xmx`.

Squeezing to the floor is also cheaper than expected - no serious thrashing.
The JVM pays 5-14% on the three real benchmarks (dottyUtil 5.69s vs 4.98s at
default heap), and native actually pays *more* in relative terms (dottyUtil
1.20s vs 0.55s, 2.2x). Native still wins on time at every configuration's own
minimum, by 2.2x (tastyQuery) to 8.4x (helloWorld) against jvm-aot.

The AOT cache does not change the minimum at all: its 49-54 MB lives in mapped
file pages outside the Java heap that `-Xmx` bounds. Its effect on RSS is
roughly neutral rather than additive (-68 MB on helloWorld, +65 MB on re2s,
-400 MB on tastyQuery warm), because cached class metadata is mapped read-only
from the file instead of being built on the heap.

Finally, `-Xms8G -Xmx8G` from the JMH config costs memory and buys nothing:
at default heap the JVM is both smaller and slightly faster (tastyQuery cold
8.81s vs 10.09s, jvm-aot 8.31s vs 8.88s). Default-heap cold times:

| benchmark  | native-O3 |   jvm | jvm-aot |
|------------|----------:|------:|--------:|
| helloWorld |     0.06s | 1.60s |   1.02s |
| dottyUtil  |     0.55s | 4.98s |   4.27s |
| re2s       |     0.88s | 4.82s |   4.27s |
| tastyQuery |     2.62s | 8.81s |   8.31s |

### Use a jar for -bootclasspath, not the extracted directory

`-bootclasspath jdk-classes/java.base` (250 MB tree) costs a constant ~0.14s
over `-bootclasspath java.base.jar` (14 MB, one zip index), which dominates a
small compile:

| bootclasspath | helloWorld | dottyUtil | tastyQuery |
|---|---:|---:|---:|
| `jdk-classes/java.base` (dir) | 0.21s | 0.69s | 3.35s |
| `java.base.jar` | 0.07s | 0.60s | 3.09s |

## Remaining real blocker: macros

`sourcecode` (a macro library, compiled with its tests as the benchmark does)
fails with 72 errors of the form:

```
Failed to evaluate macro.
  Caused by class java.lang.ClassNotFoundException: sourcecode.Macros$
    dotty.tools.dotc.quoted.Interpreter.loadClass(Interpreter.scala:212)
    dotty.tools.dotc.transform.Splicer$SpliceInterpreter.interpretTree(Splicer.scala:265)
```

Macro expansion loads and runs the macro implementation's class file, which a
closed-world native image cannot do for classes produced after build time.

Macros *do* work when the implementation is on the native-image build classpath
and in the reachability metadata — `scalac-native-macro` (built with
`mymacro.jar` on the build classpath and agent-recorded config) expands
`macro/usage.scala` correctly. Compiling macro and use site in two separate
runs reports the misleading "Cyclic macro dependencies" error instead of the
`ClassNotFoundException`.

## Can a native image execute classfiles at run time? (macro follow-up)

Yes - GraalVM 25.3 ships an experimental `-H:+RuntimeClassLoading`:

```
-H:?RuntimeClassLoading   Enable support for runtime class loading. This implies
                          open world (-ClosedTypeWorld) and respecting class loader
                          hierarchy (+ClassForNameRespectsClassLoader).
```

Built with it (`scalac-native-rcl`, 150 MB vs 64 MB, build 1m 4s), the image
**does load and execute the macro's classfile**. Compare the same two-step
macro compile:

- plain image: "Macro code depends on object MyMacro in package mymacro found
  on the classpath, but could not be loaded while evaluating the macro" - the
  class never loads.
- RCL image: `java.lang.AbstractMethodError at mymacro.MyMacro$.showExprImpl(mymacro.scala:6)`
  - guest bytecode ran, and failed at the call back into the compiler.

So runtime class loading works; the host<->guest boundary is what is
incomplete. Three macro shapes, all failing differently:

| macro body | result under RCL |
|---|---|
| `'{ $n * 2 }` (quote splice) | `Fatal error: Unable to call AOT method: ...DelegatingMethodHandle$Holder.delegate` |
| `Expr("literal")` (ToExpr) | `AbstractMethodError at scala.quoted.ToExpr$StringToExpr.apply` |
| `Expr(x.asTerm.show)` (reflect) | `AbstractMethodError at showImpl` |

A diagnostic macro that tries to print `classOf[Quotes].isInstance(q)` and the
class loaders crashes the VM outright (SubstrateDiagnostics dump inside
`Interpreter.stopIfRuntimeException`), so the precise mechanism is **not**
established. `AbstractMethodError` at a host interface call is consistent with
runtime-loaded classes not sharing class identity with their AOT counterparts,
but that is a hypothesis, not a measurement. On the JVM the same probe shows
what has to hold: the macro is loaded by a separate `URLClassLoader`, yet
`scala.quoted.Quotes` resolves through delegation to the same class, and
`iface.isInstance(q) = true`.

Caveat found the hard way: with RCL the real module system is active at run
time, so a jar in the working directory whose classes are in the **default
package** breaks startup with `FindException: Unable to derive module
descriptor`. Put macro classes in a named package.

### Macros DO work: RuntimeClassLoading + reflection metadata + -H:Preserve

Three build-time changes, **no dotty source changes**, get real macros working:

1. `-H:+RuntimeClassLoading` (implies open world + `+ClassForNameRespectsClassLoader`)
2. reflection metadata for every class in scala-library + scala3-compiler +
   tasty-core (9108 entries, 596 KB of JSON) - without this, `Class.forName` on
   a built-in class throws CNFE, parent delegation fails, the macro class loader
   defines a *second* copy of `scala.quoted.Quotes`, and you get `AbstractMethodError`
3. `-H:Preserve=path=<scala-library.jar>,package=java.lang.invoke,package=java.util.concurrent,package=java.util,package=java.lang`
   - registering *types* is not enough, members must be preserved too, or the
   interpreter fails with `Cannot load undefined field: scala/quoted/Expr$.MODULE$`
   or `Unable to call AOT method: ConcurrentHashMap.<init>`

With those, `sourcecode` (macro library + its tests, the benchmark that produced
72 errors before) compiles to **108 classfiles byte-identical to the JVM's**.

### What RuntimeClassLoading costs

Best of 3 cold runs, `-bootclasspath java.base.jar`, run from a clean cwd.
The 2x2 grid isolates RCL at each optimization level.

| benchmark  |    jvm | native | native-rcl | native-O3 | native-rcl-O3 |
|------------|-------:|-------:|-----------:|----------:|--------------:|
| helloWorld |  1.60s |  0.07s |      0.11s |     0.06s |         0.10s |
| dottyUtil  |  4.91s |  0.61s |      0.97s |     0.55s |         0.78s |
| re2s       |  4.90s |  1.02s |      1.66s |     0.88s |         1.24s |
| tastyQuery |  8.99s |  2.97s |      4.76s |     2.61s |         3.64s |
| sourcecode |  4.40s | broken |      0.87s |    broken |         0.71s |

("broken" = compiles only the 54 macro-defining classfiles then errors on the
use sites, so those cells are not valid timings.)

Peak RSS (MB), same order:

| benchmark  | jvm | native | native-rcl | native-O3 | native-rcl-O3 |
|------------|----:|-------:|-----------:|----------:|--------------:|
| helloWorld | 485 |     74 |        154 |        92 |           180 |
| dottyUtil  | 629 |    141 |        230 |       167 |           268 |
| re2s       | 743 |    155 |        239 |       185 |           280 |
| tastyQuery | 906 |    221 |        320 |       257 |           355 |
| sourcecode | 692 |    149 |        279 |       171 |           331 |

Every configuration's output is byte-identical to the JVM compiler's.

Cost of RCL at fixed optimization level: **1.57-1.67x at -O2, 1.39-1.67x at
-O3** - so `-O3 -march=native` recovers part of it. Binary 64 -> 306 MB (-O2)
and 113 -> 451 MB (-O3); build 40s -> 2m37s and 1m1s -> 3m8s; RSS roughly
doubles.

Even paying that, `native-rcl-O3` is still **2.5x (tastyQuery) to 16x
(helloWorld)** faster than the JVM cold, in ~2.5x less memory, and it is the
only native configuration that compiles macro-using code correctly.

### The options, ranked by how practical they are today

1. **Bake macro implementations into the image** - verified working
   (`scalac-native-macro`). Fine for a fixed set (a stdlib's macros); useless
   for arbitrary user macros.
2. **Delegate the whole compilation to a JVM** when a unit needs macro
   expansion. This is the external-process idea, but at *compilation*
   granularity, which avoids the hard part: you hand over the whole job
   instead of proxying anything.
3. **`-H:+RuntimeClassLoading`** - the right shape, in-process, no interop
   layer needed since everything lives in one world. Not usable yet, but it is
   the option to watch.
4. **Espresso** (`org.graalvm.polyglot:java:25.3.4.1` and
   `org.graalvm.espresso:espresso-language:25.3.4.1` are on Maven Central at
   exactly this GraalVM version, with `espresso-runtime-resources-jdk25`).
   A full JVM bytecode interpreter embeddable via the Polyglot API. Not
   attempted here, and not a drop-in: guest classes live in a separate world,
   while a dotty macro must call back into the host compiler's `Quotes` object
   constantly. That needs host<->guest interop across the whole
   `quotes.reflect` surface.

Per-macro out-of-process execution is the option that looks easy and is not:
`Quotes` is a chatty bidirectional interface, so it would mean proxying the
entire reflect API over IPC. Option 2 sidesteps that entirely.

## Files here

- `build.sh` / `build.log` — the plain image; `cp.txt`, `libcp.txt` — classpaths
- `probe/JrtProbe.java` — the `jrt:/` availability probe
- `bench2.sh`, `b2/` — the benchmark tables; `bench.sh`, `bench-out/` — first pass
- `bench3.sh`, `bench3-warm.sh`, `b3/`, `aot/` — the AOT cache comparison
- `bench4.sh` — peak RSS; `bench5.sh`/`bench6.sh` — minimum-heap bisect
- `loop.jar` — `Loop.class` as a jar (the AOT cache rejects classpath directories)
- `Loop.java`, `loop/`, `scalac-native-loop` — warm-up curve harness
- `macro/`, `mymacro.jar`, `scalac-native-macro` — the macro experiments
- `scalac-native-rcl{,2,3}` — RCL attempts; `scalac-native-rcl4{,-O3}` — the working ones
- `ni-config-rcl/` — bulk reflection metadata; `bench7.sh`/`bench7b.sh` — the RCL cost tables
- `hello.scala`, `features.scala` — small correctness checks
- `jdk-classes/`, `java.base.jar` — extracted JDK classes for workaround A

Disk: ~813 MB total, mostly `jdk-classes/` (250 MB), the four images (300 MB) and
the benchmark output dirs (`b2/`, `bench-out/`), which are safe to delete.
