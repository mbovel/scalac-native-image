import java.util.Arrays;

/** Runs the same compilation N times in one process, to separate JIT warm-up from cold start. */
public class Loop {
  public static void main(String[] a) throws Exception {
    int n = Integer.parseInt(a[0]);
    String[] args = Arrays.copyOfRange(a, 1, a.length);
    for (int i = 0; i < n; i++) {
      long t0 = System.nanoTime();
      Object r = new dotty.tools.dotc.Driver().process(args);
      long ms = (System.nanoTime() - t0) / 1000000;
      System.out.println("iter " + i + ": " + ms + " ms" +
          (((dotty.tools.dotc.reporting.Reporter) r).hasErrors() ? "  [ERRORS]" : ""));
    }
  }
}
