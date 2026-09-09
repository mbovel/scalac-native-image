@main def hello = println("hi " + List(1, 2, 3).map(_ * 2).mkString(","))
