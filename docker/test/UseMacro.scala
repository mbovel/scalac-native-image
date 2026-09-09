case class P(x: Int, y: String, z: List[Double])

@main def useMacro =
  val n = 5
  println(s"${M.dbg(n + 1)} ${M.fields[P]}")
