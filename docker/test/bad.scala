// Must be reported as an error, with a non-zero exit status.
@main def bad = println(undefinedName + 1)
