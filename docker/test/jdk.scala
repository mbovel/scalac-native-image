// Leans on the JDK rather than the Scala library: these classes only exist in
// the image because java.base.jar is on the -bootclasspath.
import java.util.concurrent.ConcurrentHashMap
import scala.jdk.CollectionConverters.*

@main def jdk =
  val m = new ConcurrentHashMap[String, Int]()
  m.put("a", 1)
  println(s"${m.asScala.toMap} ${java.time.LocalDate.of(2026, 9, 9).getDayOfWeek}")
