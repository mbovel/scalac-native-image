import scala.compiletime.*
import scala.deriving.Mirror
import scala.collection.mutable

enum Color(val rgb: Int):
  case Red   extends Color(0xff0000)
  case Green extends Color(0x00ff00)
  case Blue  extends Color(0x0000ff)

sealed trait Shape
case class Circle(r: Double) extends Shape
case class Rect(w: Double, h: Double) extends Shape

trait Show[A]:
  extension (a: A) def show: String

object Show:
  given Show[Int] with
    extension (a: Int) def show = s"Int($a)"
  given [A](using s: Show[A]): Show[List[A]] with
    extension (a: List[A]) def show = a.map(_.show).mkString("[", ", ", "]")

inline def labelsOf[A](using m: Mirror.Of[A]): List[String] =
  constValueTuple[m.MirroredElemLabels].toList.map(_.toString)

def area(s: Shape): Double = s match
  case Circle(r)  => math.Pi * r * r
  case Rect(w, h) => w * h

opaque type Meters = Double
object Meters:
  def apply(d: Double): Meters = d
  extension (m: Meters) def toDouble: Double = m

type Elem[X] = X match
  case List[t] => t
  case _       => X

@main def features =
  import Show.given
  val cache = mutable.Map.empty[Color, Double]
  Color.values.foreach(c => cache(c) = c.rgb.toDouble)
  println(List(1, 2, 3).show)
  println(labelsOf[Rect])
  println(f"${area(Circle(1.0))}%.3f ${area(Rect(2, 3))}%.1f")
  println(Meters(5.0).toDouble)
  println(summon[Elem[List[Int]] =:= Int] != null)
  println(cache.toSeq.sortBy(_._2).map(_._1).mkString(","))
  val fut = for i <- List(1, 2); j <- List(10, 20) yield i * j
  println(fut)
