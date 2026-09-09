import scala.quoted.*

object M:
  inline def dbg(inline e: Any): String = ${ dbgImpl('e) }
  def dbgImpl(e: Expr[Any])(using Quotes): Expr[String] =
    e match
      case '{ ($a: Int) + ($b: Int) } => Expr(s"add(${a.show}, ${b.show})")
      case _                          => Expr(e.show)

  inline def fields[T]: List[String] = ${ fieldsImpl[T] }
  def fieldsImpl[T: Type](using Quotes): Expr[List[String]] =
    import quotes.reflect.*
    Expr(TypeRepr.of[T].typeSymbol.caseFields.map(_.name))
