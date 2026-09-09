import java.util.Arrays;

/**
 * Compiles the same arguments N times in one JVM, printing "iter i: T ms" for each, so that
 * warm (post-JIT) time can be separated from cold start.
 *
 * This is the JVM half of the harness. The native binary does the same thing itself, under
 * SCALAC_BENCH_ITERATIONS, so that the warm measurement runs against the shipped executable
 * rather than a purpose-built one -- see docker/ScalacMain.java.
 *
 * Driver.process, not Main.main: the latter calls System.exit on the first failed compile,
 * which would end the loop.
 */
public final class Loop {
  public static void main(String[] args) {
    int n = Integer.parseInt(args[0]);
    String[] rest = Arrays.copyOfRange(args, 1, args.length);
    boolean errors = false;
    for (int i = 0; i < n; i++) {
      long t0 = System.nanoTime();
      dotty.tools.dotc.reporting.Reporter reporter = new dotty.tools.dotc.Driver().process(rest);
      long ms = (System.nanoTime() - t0) / 1_000_000;
      errors |= reporter.hasErrors();
      System.out.println("iter " + i + ": " + ms + " ms" + (reporter.hasErrors() ? "  [ERRORS]" : ""));
    }
    if (errors) System.exit(1);
  }
}
