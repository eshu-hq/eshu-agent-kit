#!/usr/bin/env bash
# Install eshu-agent-kit skills and agents into a harness or a repo checkout.
# Usage:
#   ./install.sh --global | ./install.sh --repo /path/to/repo
#   ./install.sh --agents --global | ./install.sh --agents --repo /path/to/repo
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

link_files() {
  local pattern="$1" dest="$2"
  mkdir -p "$dest"
  for f in $pattern; do
    [ -f "$f" ] || continue
    ln -sfn "$f" "$dest/$(basename "$f")"
  done
}

install_agents_global() {
  link_files "$KIT_DIR/agents/*.md" "$HOME/.agents/agents"
  link_files "$KIT_DIR/.claude/agents/*.md" "$HOME/.claude/agents"
  link_files "$KIT_DIR/.codex/agents/*.toml" "$HOME/.codex/agents"
  echo "installed kit agents globally from $KIT_DIR"
}

install_agents_repo() {
  local target="$1"
  link_files "$KIT_DIR/agents/*.md" "$target/.agents/agents"
  link_files "$KIT_DIR/.claude/agents/*.md" "$target/.claude/agents"
  link_files "$KIT_DIR/.codex/agents/*.toml" "$target/.codex/agents"
  link_files "$KIT_DIR/.opencode/agent/*.md" "$target/.opencode/agent"
  link_files "$KIT_DIR/.cursor/agents/*.md" "$target/.cursor/agents"
  echo "installed kit agents into $target"
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
  --agents)
    SCOPE="${2:-}"
    case "$SCOPE" in
      --global)
        install_agents_global
        ;;
      --repo)
        TARGET="${3:-}"
        [ -n "$TARGET" ] || { echo "usage: ./install.sh --agents --repo /path/to/repo" >&2; exit 1; }
        install_agents_repo "$TARGET"
        ;;
      *)
        echo "usage: ./install.sh --agents --global | ./install.sh --agents --repo /path/to/repo" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "usage: ./install.sh --global | ./install.sh --repo /path/to/repo | ./install.sh --agents (--global | --repo /path/to/repo)" >&2
    exit 1
    ;;
esac
