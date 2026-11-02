#!/usr/bin/env bash
# Behavioural mirror for the harness-selected global modes.
#
# The plain global path is covered by test-global-install.sh. This suite pins
# what the selection adds: --global also lands agents, a harness list limits
# the written directories, an unknown name fails with the pick list, and a
# piped model answer rewrites both the agent files and the OpenCode config.
set -euo pipefail
kit=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# 1. --global installs skills and agents for every harness by default.
home1="$work/home1"
HOME="$home1" "$kit/install.sh" --global </dev/null >/dev/null
[ -e "$home1/.claude/skills" ]
[ -e "$home1/.codex/agents/develop-eshu.toml" ]
[ -e "$home1/.config/opencode/agents/develop-eshu.md" ]
[ -e "$home1/.agents/agents/scan-eshu.md" ]
[ -e "$home1/.cursor/agents/review-eshu.md" ]

# 2. One harness name writes only its directories.
home2="$work/home2"
HOME="$home2" "$kit/install.sh" --global claude </dev/null >/dev/null
[ -e "$home2/.claude/skills" ]
[ -e "$home2/.claude/agents/develop-eshu.md" ]
[ ! -e "$home2/.codex/skills" ]
[ ! -e "$home2/.config/opencode/agents" ]
[ ! -e "$home2/.agents/agents" ]
[ ! -e "$home2/.cursor/agents" ]

# 3. An unknown harness fails and prints the pick list.
if out="$(HOME="$work/home3" "$kit/install.sh" --global nope 2>&1)"; then
	printf 'not ok - unknown harness fails\n' >&2
	exit 1
fi
case "$out" in
*claude*codex*opencode*muse*cursor*) : ;;
*) printf 'not ok - pick list missing: %s\n' "$out" >&2; exit 1 ;;
esac

# 4. A piped answer overrides the OpenCode agent model and the config entry.
home4="$work/home4"
model="clankerbox/qwen3.8-flash-next"
answers="$model\n"
for _ in 1 2 3 4 5 6 7 8 9 10; do answers="$answers$model\n"; done
# shellcheck disable=SC2059  # \n separators are the point here.
printf "$answers" | HOME="$home4" "$kit/install.sh" --agents --global opencode >/dev/null
grep -q "^model: $model$" "$home4/.config/opencode/agents/scan-eshu.md"
grep -q "\"model\": \"$model\"" "$home4/.config/opencode/opencode.jsonc"

# 5. No answers piped: kit defaults survive a rerun.
HOME="$home4" "$kit/install.sh" --agents --global opencode </dev/null >/dev/null
grep -q "^model: deepseek/deepseek-flash#low$" "$home4/.config/opencode/agents/scan-eshu.md"

echo 'global harness selection passed'
