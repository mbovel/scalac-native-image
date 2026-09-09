# shellcheck shell=bash
#
# Portability helpers shared by the build scripts. Sourced, not executed.
#
# The same scripts run in three places: the Dockerfile's build stages, a plain
# Linux/macOS CI runner, and Git Bash on a Windows runner. Windows is the only
# awkward one -- the JDK there is a native Windows program, so it wants
# semicolon-separated classpaths and drive-letter paths, not the POSIX paths
# Git Bash hands out.

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1 ;;
  *)                    IS_WINDOWS=0 ;;
esac

if [ "$IS_WINDOWS" = 1 ]; then
  CPSEP=';'
  EXE_SUFFIX='.exe'
  # Git Bash cannot exec a bare `native-image`; the launcher is a .cmd file, so
  # its arguments travel through cmd.exe. The MSYS runtime quotes arguments
  # containing a semicolon, which is what a Windows classpath is made of. If a
  # long classpath ever does get split there, native-image also accepts an
  # `@argfile`, which sidesteps cmd.exe quoting entirely.
  NATIVE_IMAGE_CMD='native-image.cmd'
else
  CPSEP=':'
  EXE_SUFFIX=''
  NATIVE_IMAGE_CMD='native-image'
fi

# python3 is the name everywhere except some Windows installs, which only have python.
if command -v python3 >/dev/null 2>&1; then
  PYTHON=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON=python
else
  PYTHON=
fi

# Path in the form the JDK tools expect: C:/foo/bar on Windows, unchanged elsewhere.
# `cygpath -m` gives forward slashes, which avoids a second round of shell escaping.
jpath() {
  if [ "$IS_WINDOWS" = 1 ]; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# The reverse of jpath: a path *emitted* by a Windows-native tool (coursier prints
# C:\Users\...) turned into something the shell's own utilities can open.
spath() {
  if [ "$IS_WINDOWS" = 1 ]; then cygpath -u "$1"; else printf '%s' "$1"; fi
}

# Every jar in a directory, sorted, joined into one classpath.
jars_cp() {
  local dir="$1" first=1 out='' jar
  while IFS= read -r jar; do
    [ -n "$jar" ] || continue
    if [ "$first" = 1 ]; then out="$(jpath "$jar")"; first=0
    else out="$out$CPSEP$(jpath "$jar")"; fi
  done <<EOF
$(find "$dir" -name '*.jar' | sort)
EOF
  [ "$first" = 0 ] || { echo "no jars in $dir" >&2; return 1; }
  printf '%s' "$out"
}

# CPU count, for --parallelism. Falls back to 1 rather than failing the build.
cpu_count() {
  if command -v nproc >/dev/null 2>&1; then nproc
  elif [ "$(uname -s)" = Darwin ]; then sysctl -n hw.ncpu
  elif [ -n "${NUMBER_OF_PROCESSORS:-}" ]; then printf '%s' "$NUMBER_OF_PROCESSORS"
  else echo 1; fi
}

log() { printf '\n==> %s\n' "$*" >&2; }
