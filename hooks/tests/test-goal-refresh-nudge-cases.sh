#!/usr/bin/env bash
# Behavioural mirror for the skill-nudge scan in hooks/goal-refresh.sh.
#
# The scan is the part of the refresher a reader cannot check by eye: the
# directories it walks decide whether a goal that names a skill ever gets the
# "load `x` now" line, and an existence-only assertion would stay green with
# the wrong census. The census is the CONSUMER's harness trees, because those
# hold the names a goal can actually name -- the installer renames kit skills
# into them (skills/eshu/code-review -> .claude/skills/eshu-code-review), so
# the kit's own skills/eshu and skills/core are the source, not the census.
# Each case below therefore pins one property of the scan by its output text:
# which tree supplied the id, whether the walk-up found the root, and when the
# nudge is deliberately absent.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${repo_root}/goal-refresh.sh"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/tmp"
# The nudge markers are the shared convention skill-nudge.sh owns
# (/tmp/claude-skill-loaded-<sid12>-<id>), and the python in
# lib/skill-nudge-lib.sh writes them there literally. Every case uses its own
# session id, so nothing from an earlier run can be read as a loaded marker,
# and the cases that plant a marker remove it again.
nudge_marker_dir="/tmp"
export TMPDIR="${work}/tmp"
# Hermeticity: the hook resolves $HOME/.claude/active-goal and honours
# $CLAUDE_GOAL_FILE, so ambient session state would skew the expectations.
mkdir -p "${work}/home/.claude"
export HOME="${work}/home"
unset CLAUDE_GOAL_FILE CLAUDE_GOAL_OFF CLAUDE_GOAL_CONSENT CLAUDE_GOAL_MAX_NUDGES

passed=0
failed=0
ok() {
	printf 'ok - %s\n' "$1"
	passed=$((passed + 1))
}
no() {
	printf 'not ok - %s\n' "$1"
	failed=$((failed + 1))
}

sid_n=0
new_sid() {
	sid_n=$((sid_n + 1))
	printf 'nudge-%s-%s' "$$" "${sid_n}"
}

# run_hook <cwd> <prompt> -> the hook's additionalContext JSON, or nothing
run_hook() {
	local cwd="$1" prompt="$2" sid
	sid="$(new_sid)"
	printf '{"session_id":"%s","prompt_id":"1","cwd":"%s","prompt":"%s","hook_event_name":"UserPromptSubmit"}' \
		"${sid}" "${cwd}" "${prompt}" |
		bash "${HOOK}" 2>/dev/null
}

# has / hasnt: substring tests on the emitted note.
has() {
	case "$1" in
	*"$2"*) ok "$3" ;;
	*) no "$3" ;;
	esac
}
hasnt() {
	case "$1" in
	*"$2"*) no "$3" ;;
	*) ok "$3" ;;
	esac
}

# ── 1. the consumer's .claude/skills tree is the census ────────────────────
# The PR's central scan change: harness tree, not the kit's source dirs.
c1="${work}/consumer-claude"
mkdir -p "${c1}/.claude/skills/eshu-code-review"
printf '1.0.0\n' >"${c1}/.agent-kit-version"
printf '%s\n' '# skill' >"${c1}/.claude/skills/eshu-code-review/SKILL.md"
out="$(run_hook "${c1}" '/goal Run the eshu-code-review skill on the diff')"
has "${out}" 'ACTIVE GOAL' 'a pinned consumer goal is restated'
has "${out}" 'load `eshu-code-review` now' '.claude/skills ids produce a nudge'

# ── 2. .agents/skills is scanned too, and is not shadowed by .claude ───────
# The alias manifest renames most skills into the harness tree but not all of
# them, so the two trees together are the census. A scan of only the first
# would miss an un-renamed id, and a scan that stopped at the first existing
# directory would too.
c2="${work}/consumer-agents"
mkdir -p "${c2}/.claude/skills/eshu-code-review" "${c2}/.agents/skills/diagnostic-rigor"
printf '1.0.0\n' >"${c2}/.agent-kit-version"
printf '%s\n' '# skill' >"${c2}/.claude/skills/eshu-code-review/SKILL.md"
printf '%s\n' '# skill' >"${c2}/.agents/skills/diagnostic-rigor/SKILL.md"
out="$(run_hook "${c2}" '/goal Use diagnostic-rigor and eshu-code-review')"
has "${out}" 'load `diagnostic-rigor` now' '.agents/skills ids produce a nudge'
has "${out}" 'load `eshu-code-review` now' 'both trees are scanned in one pass'

# ── 3. a deeper cwd still finds the pinned root (the walk-up) ──────────────
# Worktrees and package directories are the normal cwd, so a scan keyed on the
# cwd itself would find no skills and stay silent forever.
out="$(run_hook "${c2}/.claude/skills" '/goal Use diagnostic-rigor')"
has "${out}" 'load `diagnostic-rigor` now' 'a deeper cwd still resolves the kit root'

# ── 4. the old kit-source layout is NOT the census ─────────────────────────
# The seeded RED for the reverted scan: with only skills/eshu and skills/core
# present, the nudge must be absent. If the loop is ever changed back to walk
# the kit's own source dirs, this case goes GREEN-on-the-wrong-string because
# those ids are not what a consumer's goal names -- so it is asserted both ways.
c3="${work}/consumer-source-only"
mkdir -p "${c3}/skills/eshu/code-review" "${c3}/skills/core"
printf '1.0.0\n' >"${c3}/.agent-kit-version"
printf '%s\n' '# skill' >"${c3}/skills/eshu/code-review/SKILL.md"
out="$(run_hook "${c3}" '/goal Use the code-review skill')"
has "${out}" 'ACTIVE GOAL' 'the source-only layout still restates the goal'
hasnt "${out}" 'load `' 'kit source dirs are not the nudge census'

# ── 5. an already-loaded skill is not nudged again ─────────────────────────
# The marker is the whole de-duplication mechanism, shared with
# skill-nudge.sh. Sid and its 12-character prefix must agree with what the
# hook computes, or the case passes for the wrong reason.
c4="${work}/consumer-loaded"
mkdir -p "${c4}/.claude/skills/eshu-code-review"
printf '1.0.0\n' >"${c4}/.agent-kit-version"
printf '%s\n' '# skill' >"${c4}/.claude/skills/eshu-code-review/SKILL.md"
sid="$(new_sid)"
sid12="$(printf '%s' "${sid}" | cut -c1-12)"
marker="${nudge_marker_dir}/claude-skill-loaded-${sid12}-eshu-code-review"
printf '1\n' >"${marker}"
printf '{"session_id":"%s","prompt_id":"1","cwd":"%s","prompt":"/goal Use the eshu-code-review skill","hook_event_name":"UserPromptSubmit"}' \
	"${sid}" "${c4}" |
	bash "${HOOK}" 2>/dev/null >"${TMPDIR}/loaded.out"
out="$(cat "${TMPDIR}/loaded.out")"
has "${out}" 'ACTIVE GOAL' 'a loaded-marker goal is still restated'
hasnt "${out}" 'load `eshu-code-review` now' 'a loaded skill is not nudged again'
rm -f "${marker}" "${TMPDIR}/loaded.out"
canon_marker="${nudge_marker_dir}/claude-skill-loaded-${sid12}-code-review"
printf '1\n' >"${canon_marker}"
printf '{"session_id":"%s","prompt_id":"1","cwd":"%s","prompt":"/goal Use the eshu-code-review skill","hook_event_name":"UserPromptSubmit"}' \
	"${sid}" "${c4}" |
	bash "${HOOK}" 2>/dev/null >"${TMPDIR}/loaded-canon.out"
out="$(cat "${TMPDIR}/loaded-canon.out")"
hasnt "${out}" 'load `eshu-code-review` now' 'a canonical marker satisfies an eshu-* goal nudge'
rm -f "${canon_marker}" "${TMPDIR}/loaded-canon.out"

# ── 6. an unpinned directory is silent, not an error ───────────────────────
# No .agent-kit-version anywhere: the walk-up finds nothing and the hook must
# still emit the restatement and exit 0. A missing root is a legitimate
# "nothing to nudge", so this is the fail-open path.
c5="${work}/unpinned"
mkdir -p "${c5}/.claude/skills/eshu-code-review"
out="$(run_hook "${c5}" '/goal Use the eshu-code-review skill')"
has "${out}" 'ACTIVE GOAL' 'an unpinned cwd still restates the goal'
hasnt "${out}" 'load `eshu-code-review` now' 'an unpinned cwd emits no nudge'

# ── 7. word-bounded matching ───────────────────────────────────────────────
# A goal naming a longer id must not fire the shorter skill's nudge: both ids
# are absent from the tree here except the shorter one, so a prefix match would
# be visible as an extra nudge.
c6="${work}/consumer-wordbound"
mkdir -p "${c6}/.claude/skills/golang-engineering"
printf '1.0.0\n' >"${c6}/.agent-kit-version"
printf '%s\n' '# skill' >"${c6}/.claude/skills/golang-engineering/SKILL.md"
out="$(run_hook "${c6}" '/goal Update golang-engineering-notes in the fixture')"
hasnt "${out}" 'load `golang-engineering` now' 'a longer id does not fire the prefix nudge'
out="$(run_hook "${c6}" '/goal Use golang-engineering here')"
has "${out}" 'load `golang-engineering` now' 'the exact id does fire it'

# ── 8. the nudge survives the consent and issue notes ──────────────────────
# Ordering: the nudge is appended after the consent note, so a goal carrying a
# CONSENT grant must keep both. A one-line-consent form is the path most likely
# to short-circuit before the scan.
c7="${work}/consumer-consent"
mkdir -p "${c7}/.claude/skills/publish"
printf '1.0.0\n' >"${c7}/.agent-kit-version"
printf '%s\n' '# skill' >"${c7}/.claude/skills/publish/SKILL.md"
out="$(run_hook "${c7}" '/goal consent all -- Use the publish skill')"
has "${out}" 'OWNER CONSENT ALREADY GRANTED' 'the consent note is emitted'
has "${out}" 'load `publish` now' 'the nudge follows the consent note'

printf '\ngoal-refresh nudge cases: %s passed, %s failed\n' "${passed}" "${failed}"
[[ "${failed}" -eq 0 ]]
