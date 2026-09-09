import java.net.URI;
import java.nio.file.*;
import java.nio.file.spi.FileSystemProvider;

public class JrtProbe {
  public static void main(String[] args) {
    System.out.println("java.home           = " + System.getProperty("java.home"));
    System.out.println("sun.boot.class.path = " + System.getProperty("sun.boot.class.path"));
    System.out.println("java.class.path     = " + System.getProperty("java.class.path"));
    for (FileSystemProvider p : FileSystemProvider.installedProviders())
      System.out.println("provider            : " + p.getScheme() + " (" + p.getClass().getName() + ")");
    try {
      FileSystem fs = FileSystems.getFileSystem(URI.create("jrt:/"));
      System.out.println("jrt:/ filesystem    = " + fs);
      Path p = fs.getPath("/modules/java.base/java/lang/Object.class");
      System.out.println("Object.class exists = " + Files.exists(p));
    } catch (Throwable t) {
      System.out.println("jrt:/ FAILED        = " + t.getClass().getName() + ": " + t.getMessage());
    }
  }
}
