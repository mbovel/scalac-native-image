import java.io.File;
import java.net.URL;
import java.net.URLClassLoader;

/** Does parent-first delegation from a runtime URLClassLoader return the image's built-in class? */
public class LoaderProbe {
  public static void main(String[] args) throws Exception {
    // Force these into the image so they are "built in".
    Class<?> q = scala.quoted.Quotes.class;
    Class<?> l = scala.collection.immutable.List.class;
    System.out.println("built-in Quotes loader = " + q.getClassLoader());
    System.out.println("built-in List   loader = " + l.getClassLoader());

    URL[] urls = new URL[args.length];
    for (int i = 0; i < args.length; i++) urls[i] = new File(args[i]).toURI().toURL();
    URLClassLoader ucl = new URLClassLoader(urls, LoaderProbe.class.getClassLoader());
    System.out.println("parent of UCL          = " + ucl.getParent());

    for (String cn : new String[]{"scala.quoted.Quotes", "scala.collection.immutable.List"}) {
      Class<?> builtin = Class.forName(cn);
      Class<?> viaUcl  = ucl.loadClass(cn);
      System.out.println(cn);
      System.out.println("   builtin loader = " + builtin.getClassLoader());
      System.out.println("   viaUCL  loader = " + viaUcl.getClassLoader());
      System.out.println("   SAME CLASS?    = " + (builtin == viaUcl));
    }
  }
}
