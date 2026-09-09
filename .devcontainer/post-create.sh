#!/usr/bin/env bash
# postCreateCommand: runs once inside the container after it is created.
set -euo pipefail

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Named volumes can come up root-owned the first time Docker mounts them.
# Hand them to the dev user: top-level only for the (large) dependency caches,
# recursively for the small Claude Code state directory.
for dir in "$HOME/.cache/coursier" "$HOME/.sbt" "$HOME/.ivy2" "$claude_dir"; do
  sudo mkdir -p "$dir"
  if [ "$(stat -c %u "$dir")" != "$(id -u)" ]; then
    if [ "$dir" = "$claude_dir" ]; then
      sudo chown -R "$(id -u):$(id -g)" "$dir"
    else
      sudo chown "$(id -u):$(id -g)" "$dir"
    fi
  fi
done

echo "== Claude Code =="
if [ -f "$claude_dir/.credentials.json" ]; then
  echo "CLAUDE_CONFIG_DIR=$claude_dir (named volume, credentials present)"
else
  echo "CLAUDE_CONFIG_DIR=$claude_dir (named volume, not signed in yet: run 'claude')"
fi

echo "== Toolchain =="
java -version 2>&1 | head -n 1
native-image --version | head -n 1
echo "sbt launcher $(sbt --script-version)"
echo "coursier $(cs version)"
echo "scala-cli $(scala-cli --version | head -n 1)"
gcc --version | head -n 1
if command -v claude >/dev/null 2>&1; then
  echo "claude $(claude --version)"
else
  echo "claude: not on PATH (was the claude-code feature installed?)" >&2
fi
