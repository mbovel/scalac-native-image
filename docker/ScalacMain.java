import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import org.graalvm.nativeimage.ProcessProperties;

/**
 * Entry point for the native scalac.
 *
 * A native image has no {@code jrt:/} filesystem and no {@code java.home}, so dotc finds no JDK
 * classes and dies with "asTerm called on not-a-Term val <none>" (oracle/graal#8371). We hand it
 * a jar of JDK classes via -bootclasspath instead. The jar and the Scala library ship next to the
 * executable, and ProcessProperties.getExecutableName() locates them wherever the image is
 * installed or invoked from, so no launcher script is needed.
 *
 * Both defaults are only applied when the user did not pass the corresponding flag.
 */
public final class ScalacMain {

  public static void main(String[] args) {
    Path home = imageDir();
    List<String> out = new ArrayList<>();

    if (!hasFlag(args, "-bootclasspath")) {
      String boot = firstExisting(System.getenv("SCALAC_BOOTCLASSPATH"),
                                  home == null ? null : home.resolve("java.base.jar").toString());
      if (boot != null) { out.add("-bootclasspath"); out.add(boot); }
    }

    if (!hasFlag(args, "-classpath", "-cp", "--class-path", "-usejavacp")) {
      String lib = bundledLibrary(home);
      if (lib != null) { out.add("-classpath"); out.add(lib); }
    }

    out.addAll(Arrays.asList(args));
    String[] full = out.toArray(new String[0]);

    int iterations = benchIterations();
    if (iterations > 0) bench(iterations, full);
    else dotty.tools.dotc.Main.main(full);
  }

  /**
   * SCALAC_BENCH_ITERATIONS=N compiles the same arguments N times in one process, printing
   * "iter i: T ms" for each. That is how bench/eval.sh measures warm time against the shipped
   * binary instead of a purpose-built one -- a native image has no JIT to warm up, but it does
   * pay startup and JDK-classpath scanning once, and this separates the two.
   *
   * Unset or unparseable means normal single-shot operation, so nothing changes for real use.
   */
  private static int benchIterations() {
    String v = System.getenv("SCALAC_BENCH_ITERATIONS");
    if (v == null || v.isBlank()) return 0;
    try {
      return Math.max(0, Integer.parseInt(v.trim()));
    } catch (NumberFormatException e) {
      return 0;
    }
  }

  /** Driver.process, not Main.main: the latter calls System.exit on the first failed compile. */
  private static void bench(int iterations, String[] args) {
    boolean errors = false;
    for (int i = 0; i < iterations; i++) {
      long t0 = System.nanoTime();
      dotty.tools.dotc.reporting.Reporter reporter = new dotty.tools.dotc.Driver().process(args);
      long ms = (System.nanoTime() - t0) / 1_000_000;
      errors |= reporter.hasErrors();
      System.out.println("iter " + i + ": " + ms + " ms" + (reporter.hasErrors() ? "  [ERRORS]" : ""));
    }
    if (errors) System.exit(1);
  }

  private static Path imageDir() {
    try {
      Path exe = Paths.get(ProcessProperties.getExecutableName());
      return exe.getParent();
    } catch (Throwable t) {
      return null; // running on the JVM, or the platform will not tell us
    }
  }

  private static boolean hasFlag(String[] args, String... flags) {
    for (String a : args)
      for (String f : flags)
        if (a.equals(f)) return true;
    return false;
  }

  private static String firstExisting(String... candidates) {
    for (String c : candidates)
      if (c != null && Files.exists(Paths.get(c))) return c;
    return null;
  }

  /** Every jar in <image dir>/lib, which is where the Dockerfile puts the Scala library. */
  private static String bundledLibrary(Path home) {
    if (home == null) return null;
    Path lib = home.resolve("lib");
    if (!Files.isDirectory(lib)) return null;
    try (Stream<Path> s = Files.list(lib)) {
      String cp = s.filter(p -> p.getFileName().toString().endsWith(".jar"))
                   .sorted()
                   .map(Path::toString)
                   .collect(Collectors.joining(java.io.File.pathSeparator));
      return cp.isEmpty() ? null : cp;
    } catch (Exception e) {
      return null;
    }
  }
}
