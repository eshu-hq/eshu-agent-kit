#!/usr/bin/env bash
# Install eshu-agent-kit skills into a harness or a repo checkout.
# Usage: ./install.sh --global | ./install.sh --repo /path/to/repo
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"

link_dir() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  for skill in "$src"/*/; do
    [ -d "$skill" ] || continue
    local name; name="$(basename "$skill")"
    ln -sfn "$skill" "$dest/$name"
  done
}

case "$MODE" in
  --global)
    link_dir "$KIT_DIR/skills/core" "$HOME/.claude/skills"
    link_dir "$KIT_DIR/skills/eshu" "$HOME/.claude/skills"
    link_dir "$KIT_DIR/skills/core" "$HOME/.codex/skills"
    echo "installed kit skills globally from $KIT_DIR"
    ;;
  --repo)
    TARGET="${2:-}"
    [ -n "$TARGET" ] || { echo "usage: ./install.sh --repo /path/to/repo" >&2; exit 1; }
    mkdir -p "$TARGET/.agents/skills"
    link_dir "$KIT_DIR/skills/core" "$TARGET/.agents/skills"
    link_dir "$KIT_DIR/skills/eshu" "$TARGET/.agents/skills"
    echo "v0.1.0" > "$TARGET/.agent-kit-version"
    echo "installed kit skills into $TARGET/.agents/skills"
    ;;
  *)
    echo "usage: ./install.sh --global | ./install.sh --repo /path/to/repo" >&2
    exit 1
    ;;
esac
