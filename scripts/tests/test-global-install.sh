#!/usr/bin/env bash
set -euo pipefail
kit=$(cd "$(dirname "$0")/../.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf "$test_home"' EXIT
mkdir -p "$test_home/.codex/skills/golang-engineering"
printf 'existing\n' > "$test_home/.codex/skills/golang-engineering/SKILL.md"
HOME="$test_home" "$kit/install.sh" --global
for skill in "$kit"/skills/eshu/*/; do
  name=$(basename "$skill")
  [ -e "$test_home/.claude/skills/$name/SKILL.md" ]
  if [ "$name" != golang-engineering ]; then
    [ "$(readlink "$test_home/.codex/skills/$name")" = "$skill" ]
  fi
done
[ "$(cat "$test_home/.codex/skills/golang-engineering/SKILL.md")" = existing ]
[ ! -e "$test_home/.codex/skills/golang-engineering/golang-engineering" ]
HOME="$test_home" "$kit/install.sh" --global
HOME="$test_home" "$kit/install.sh" --agents --global
[ -e "$test_home/.codex/agents/develop-eshu.toml" ]
echo 'global installation passed'
