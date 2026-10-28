#!/usr/bin/env bash
# Install eshu-agent-kit skills, agents, hooks, and rules into a harness or a repo checkout.
# Usage:
#   ./install.sh --global | ./install.sh --repo /path/to/repo
#   ./install.sh --agents --global | ./install.sh --agents --repo /path/to/repo
#   ./install.sh --hooks --repo /path/to/repo   (scripts only; wire them per hooks/README.md)
#   ./install.sh --rules --repo /path/to/repo   (Claude Code path-scoped rules + rules lint script)
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"

link_dir() {
  local src="$1" dest="$2"
  mkdir -p "$dest"
  for skill in "$src"/*/; do
    [ -d "$skill" ] || continue
    local name; name="$(basename "$skill")"
    if [ -e "$dest/$name" ] && [ ! -L "$dest/$name" ]; then
      echo "preserving existing skill: $dest/$name" >&2
      continue
    fi
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

install_hooks_repo() {
  local target="$1"
  mkdir -p "$target/.claude/hooks/lib" "$target/scripts"
  link_files "$KIT_DIR/hooks/*.sh" "$target/.claude/hooks"
  link_files "$KIT_DIR/hooks/lib/*" "$target/.claude/hooks/lib"
  link_files "$KIT_DIR/hooks/codex/*.sh" "$target/.codex/hooks"
  link_files "$KIT_DIR/scripts/check-docs-stale.sh" "$target/scripts"
  echo "installed kit hook scripts into $target/.claude/hooks (+ Codex adapter)"
  echo "wire them in settings.json (see hooks/README.md#wiring); registration stays explicit"
}

install_rules_repo() {
  local target="$1"
  mkdir -p "$target/.claude/rules" "$target/scripts"
  link_files "$KIT_DIR/rules/*.md" "$target/.claude/rules"
  link_files "$KIT_DIR/scripts/claude-rules-lint.sh" "$target/scripts"
  echo "installed kit rules into $target/.claude/rules (+ scripts/claude-rules-lint.sh)"
  echo "run scripts/claude-rules-lint.sh in the repo after moving rules or their targets"
}

case "$MODE" in
  --global)
    link_dir "$KIT_DIR/skills/core" "$HOME/.claude/skills"
    link_dir "$KIT_DIR/skills/eshu" "$HOME/.claude/skills"
    link_dir "$KIT_DIR/skills/core" "$HOME/.codex/skills"
    link_dir "$KIT_DIR/skills/eshu" "$HOME/.codex/skills"
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
  --hooks)
    SCOPE="${2:-}"
    case "$SCOPE" in
      --repo)
        TARGET="${3:-}"
        [ -n "$TARGET" ] || { echo "usage: ./install.sh --hooks --repo /path/to/repo" >&2; exit 1; }
        install_hooks_repo "$TARGET"
        ;;
      *)
        echo "usage: ./install.sh --hooks --repo /path/to/repo" >&2
        exit 1
        ;;
    esac
    ;;
  --rules)
    SCOPE="${2:-}"
    case "$SCOPE" in
      --repo)
        TARGET="${3:-}"
        [ -n "$TARGET" ] || { echo "usage: ./install.sh --rules --repo /path/to/repo" >&2; exit 1; }
        install_rules_repo "$TARGET"
        ;;
      *)
        echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "usage: ./install.sh --global | ./install.sh --repo /path/to/repo | ./install.sh --agents (--global | --repo /path/to/repo) | ./install.sh --hooks --repo /path/to/repo | ./install.sh --rules --repo /path/to/repo" >&2
    exit 1
    ;;
esac
