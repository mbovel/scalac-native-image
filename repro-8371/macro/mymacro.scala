import scala.quoted.*

object MyMacro:
  inline def showExpr(inline x: Any): String = ${ showExprImpl('x) }
  private def showExprImpl(x: Expr[Any])(using Quotes): Expr[String] =
    Expr(x.show)
