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
    dotty.tools.dotc.Main.main(out.toArray(new String[0]));
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
