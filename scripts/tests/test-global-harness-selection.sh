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
*)
	printf 'not ok - pick list missing: %s\n' "$out" >&2
	exit 1
	;;
esac
# Every name is validated, including after all.
if HOME="$work/home3" "$kit/install.sh" --global all nope >/dev/null 2>&1; then
	printf 'not ok - unknown name after all fails\n' >&2
	exit 1
fi

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

# 6. A JSONC config (comments, trailing commas, unrelated keys) merges without loss.
home5="$work/home5"
mkdir -p "$home5/.config/opencode"
cat >"$home5/.config/opencode/opencode.jsonc" <<'JSONC'
{
  // main model
  "model": "keep-me",
  "compaction": { "auto": true, },
  "custom": 1,
}
JSONC
answers="$model\n"
for _ in 1 2 3 4 5 6 7 8 9 10; do answers="$answers$model\n"; done
# shellcheck disable=SC2059  # \n separators are the point here.
printf "$answers" | HOME="$home5" "$kit/install.sh" --agents --global opencode >/dev/null
seeded="$home5/.config/opencode/opencode.jsonc"
grep -q '"custom": 1' "$seeded"
grep -q '"compaction"' "$seeded"
grep -q "\"model\": \"$model\"" "$seeded"
grep -q '"agents"' "$seeded"

# 7. A broken config exits nonzero and leaves the file untouched.
home6="$work/home6"
mkdir -p "$home6/.config/opencode"
printf '{"model": "x",,,\n' >"$home6/.config/opencode/opencode.jsonc"
before="$(cat "$home6/.config/opencode/opencode.jsonc")"
if HOME="$home6" "$kit/install.sh" --agents --global opencode </dev/null >/dev/null 2>&1; then
	printf 'not ok - broken config must fail the merge\n' >&2
	exit 1
fi
[ "$(cat "$home6/.config/opencode/opencode.jsonc")" = "$before" ]

echo 'global harness selection passed'
