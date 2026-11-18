#!/usr/bin/env bash
# Install eshu-agent-kit skills, agents, hooks, and rules into a harness or a repo checkout.
# Usage: ./install.sh --help for the full reference. Common forms:
#   ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv]
#   ./install.sh --agents --hooks --repo /path/to/repo   (one call, several parts)
#   ./install.sh --pick [--repo DIR | --global [harness...]]   (choose parts interactively)
# Harness names for the global modes: claude, codex, opencode, muse, cursor, or all.
# No harness name means all. The global modes ask a model ID per agent; the
# default is the kit value from agents/roles.json, so plain Enter keeps it.
# Piped or empty stdin also keeps every default. Repo modes never prompt.
# Every mode prunes stale kit-owned artifacts it manages (printed per file);
# pass --no-prune after the mode to keep them.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"
HARNESSES=(claude codex opencode muse cursor)
selected=()

link_dir() {
	local src="$1" dest="$2"
	mkdir -p "$dest"
	for skill in "$src"/*/; do
		[ -d "$skill" ] || continue
		local name
		name="$(basename "$skill")"
		if [ -e "$dest/$name" ] && [ ! -L "$dest/$name" ]; then
			echo "preserving existing skill: $dest/$name" >&2
			continue
		fi
		ln -sfn "$skill" "$dest/$name"
	done
}

link_files() {
	local pattern="$1" dest="$2" mode="${3:-link}"
	mkdir -p "$dest"
	for f in $pattern; do
		[ -f "$f" ] || continue
		if [ "$mode" = copy ]; then
			rm -f "$dest/$(basename "$f")" && cp "$f" "$dest/$(basename "$f")" # rm first: cp would write through an old symlink into the kit source
		else
			ln -sfn "$f" "$dest/$(basename "$f")"
		fi
	done
}

resolve_harnesses() {
	local h
	selected=()
	for h in "$@"; do
		case "$h" in
		all | claude | codex | opencode | muse | cursor) : ;;
		*)
			printf 'unknown harness: %s (choose: claude, codex, opencode, muse, cursor, all)\n' "$h" >&2
			return 1
			;;
		esac
	done
	if [ "$#" -eq 0 ]; then
		selected=("${HARNESSES[@]}")
		return 0
	fi
	for h in "$@"; do
		if [ "$h" = all ]; then
			selected=("${HARNESSES[@]}")
			return 0
		fi
		case " ${selected[*]-} " in
		*" $h "*) : ;;
		*) selected+=("$h") ;;
		esac
	done
}

skills_dir_for() {
	case "$1" in
	claude) printf '%s\n' "$HOME/.claude/skills" ;;
	codex) printf '%s\n' "$HOME/.codex/skills" ;;
	opencode) printf '%s\n' "$HOME/.config/opencode/skill" ;;
	muse) printf '%s\n' "$HOME/.agents/skills" ;;
	cursor) printf '%s\n' "$HOME/.cursor/skills" ;;
	esac
}

agents_src_for() {
	case "$1" in
	claude) printf '%s\n' "$KIT_DIR/.claude/agents/*.md" ;;
	codex) printf '%s\n' "$KIT_DIR/.codex/agents/*.toml" ;;
	opencode) printf '%s\n' "$KIT_DIR/.opencode/agent/*.md" ;;
	muse) printf '%s\n' "$KIT_DIR/agents/*.md" ;;
	cursor) printf '%s\n' "$KIT_DIR/.cursor/agents/*.md" ;;
	esac
}

agents_dir_for() {
	case "$1" in
	claude) printf '%s\n' "$HOME/.claude/agents" ;;
	codex) printf '%s\n' "$HOME/.codex/agents" ;;
	opencode) printf '%s\n' "$HOME/.config/opencode/agents" ;;
	muse) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/muse/agents" ;;
	cursor) printf '%s\n' "$HOME/.cursor/agents" ;;
	esac
}

# Kit default model for one role, read from that harness's own mirror file.
agent_model_default() {
	local harness="$1" role="$2" f
	for f in $(agents_src_for "$harness"); do
		case "$f" in
		*/"$role".md | */"$role".toml)
			sed -n 's/^model[ ]*[:=][ ]*"\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -1
			return 0
			;;
		esac
	done
	printf 'inherit\n'
}

# One prompt line; EOF or empty input keeps the default, so it is scriptable.
ask_model() {
	local label="$1" def="$2" ans=""
	printf '%s [%s]: ' "$label" "$def" >&2
	read -r ans || true
	printf '%s\n' "${ans:-$def}"
}

# Rewrite the model line of one agent file into the global directory.
write_agent_file() {
	local src="$1" dest="$2" model="$3"
	# Never write an empty or model-less agent file: an empty source (or
	# a broken checkout) must fail loudly instead of installing 0-byte
	# agents, and an empty model would write a blank `model:` line.
	if [ ! -s "$src" ]; then
		echo "error: refusing to install from empty agent file: $src" >&2
		return 1
	fi
	if [ -z "$model" ]; then
		echo "error: refusing to write an agent file with no model: $src" >&2
		return 1
	fi
	mkdir -p "$dest"
	awk -v m="$model" '
	!done && /^model = / { printf "model = \"%s\"\n", m; done=1; next }
	!done && /^model: /  { printf "model: %s\n", m;      done=1; next }
	{ print }
	' "$src" >"$dest/$(basename "$src")"
}

install_agents_for() {
	local harness="$1" f role model
	[ "$harness" = muse ] && [ -d "$HOME/.agents/agents" ] && printf 'note: muse agents now install to %s; model choices under ~/.agents/agents are no longer read\n' "$(agents_dir_for muse)" >&2
	for f in $(agents_src_for "$harness"); do
		[ -f "$f" ] || continue
		role="$(basename "$f")"
		role="${role%.*}"
		model="$(agent_model_default "$harness" "$role")"
		model="$(ask_model "$role" "$model")"
		write_agent_file "$f" "$(agents_dir_for "$harness")" "$model"
	done
	prune_dir "$(agents_dir_for "$harness")" "$(agents_src_for "$harness")"
	echo "installed kit agents for $harness"
}

install_agents_global() {
	local harness
	for harness in "${selected[@]}"; do
		if [ "$harness" = opencode ]; then
			install_opencode_agents
		else
			install_agents_for "$harness"
		fi
	done
}

# stamp_version_pin <target> — record the kit version this repo installs.
#
# The pin is not only a version marker: the role launcher resolves the
# workspace it runs in by walking up to the nearest ancestor carrying
# .agent-kit-version. A partial-mode install (--agents, --hooks, --rules)
# that did not stamp it left the launcher resolving to this kit instead of
# the consuming repo -- the exact bug the launcher fix addressed.
stamp_version_pin() {
	local target="$1"
	mkdir -p "$target"
	cat "$KIT_DIR/VERSION" >"$target/.agent-kit-version"
}

install_agents_repo() {
	local target="$1"
	# The manifest is the role binding of record: a consuming repo's router
	# reads .agents/roles.json to pick a role's tier and model, and its
	# drift check compares that file against the kit. Install it alongside
	# the shims that were generated from it.
	mkdir -p "$target/.agents"
	ln -sfn "$KIT_DIR/agents/roles.json" "$target/.agents/roles.json"
	link_files "$KIT_DIR/agents/*.md" "$target/.agents/agents" copy # Muse rejects symlinked project definitions
	link_files "$KIT_DIR/.claude/agents/*.md" "$target/.claude/agents"
	link_files "$KIT_DIR/.codex/agents/*.toml" "$target/.codex/agents"
	link_files "$KIT_DIR/.opencode/agent/*.md" "$target/.opencode/agent"
	link_files "$KIT_DIR/.cursor/agents/*.md" "$target/.cursor/agents"
	prune_dir "$target/.agents/agents" "$KIT_DIR/agents/*.md"
	prune_dir "$target/.claude/agents" "$KIT_DIR/.claude/agents/*.md"
	prune_dir "$target/.codex/agents" "$KIT_DIR/.codex/agents/*.toml"
	prune_dir "$target/.opencode/agent" "$KIT_DIR/.opencode/agent/*.md"
	prune_dir "$target/.cursor/agents" "$KIT_DIR/.cursor/agents/*.md"
	# The launcher belongs in the consuming repo: scripts/goal-role-router.py
	# tells the coordinator to run `scripts/agent-roles.py muse-exec ROLE
	# TASK` and `codex-exec ROLE TASK`, so a repo that does not have it
	# loses the documented fallback for harnesses whose spawn tool cannot
	# select a custom role.
	mkdir -p "$target/scripts"
	ln -sfn "$KIT_DIR/agents/agent-roles.py" "$target/scripts/agent-roles.py"
	echo "installed kit agents into $target"
}

# Skill alias wrappers live in scripts/lib/install-aliases.sh to keep
# this entrypoint under the 500-line cap.
# shellcheck source=scripts/lib/install-aliases.sh
source "$KIT_DIR/scripts/lib/install-aliases.sh"
# shellcheck source=scripts/lib/install-hooks.sh
source "$KIT_DIR/scripts/lib/install-hooks.sh"
# shellcheck source=scripts/lib/install-prune.sh
source "$KIT_DIR/scripts/lib/install-prune.sh"
# shellcheck source=scripts/lib/install-hooks-global.sh
source "$KIT_DIR/scripts/lib/install-hooks-global.sh"
# shellcheck source=scripts/lib/install-hooks-global-claude.sh
source "$KIT_DIR/scripts/lib/install-hooks-global-claude.sh"
# shellcheck source=scripts/lib/install-hooks-global-opencode.sh
source "$KIT_DIR/scripts/lib/install-hooks-global-opencode.sh"
# shellcheck source=scripts/lib/install-uninstall.sh
source "$KIT_DIR/scripts/lib/install-uninstall.sh"
# shellcheck source=scripts/lib/install-select.sh
source "$KIT_DIR/scripts/lib/install-select.sh"
# shellcheck source=scripts/lib/install-opencode.sh
source "$KIT_DIR/scripts/lib/install-opencode.sh"

install_skills_global() {
	local harness dir
	for harness in "${selected[@]}"; do
		dir="$(skills_dir_for "$harness")"
		link_dir "$KIT_DIR/skills/core" "$dir"
		link_dir "$KIT_DIR/skills/eshu" "$dir"
		prune_dir "$dir" "$KIT_DIR/skills/core/*" "$KIT_DIR/skills/eshu/*"
	done
}

install_global() {
	install_skills_global
	install_agents_global
	echo "installed kit skills and agents globally from $KIT_DIR for: ${selected[*]}"
}

case "${1:-}" in
-h | --help)
	print_install_help
	;;
--pick)
	shift || true
	install_pick "$@"
	;;
--uninstall)
	uninstall_main "${@:2}" || exit 1
	;;
*)
	PARTS=""
	REST=()
	for _part_arg in "$@"; do
		case "$_part_arg" in
		--agents | --hooks | --rules | --skills)
			case " $PARTS " in
			*" ${_part_arg#--} "*) ;;
			*) PARTS="$PARTS ${_part_arg#--}" ;;
			esac
			;;
		--force)
			echo "error: --force is an uninstall-only flag" >&2
			exit 1
			;;
		*)
			REST+=("$_part_arg")
			;;
		esac
	done
	unset _part_arg
	if [ -n "${PARTS// /}" ]; then
		install_parts "$PARTS" -- ${REST[@]+"${REST[@]}"}
	else
		set -- ${REST[@]+"${REST[@]}"}
		MODE="${1:-}"
		case "$MODE" in
		--global)
			resolve_harnesses "${@:2}" || exit 1
			install_global
			;;
		--repo)
			TARGET="${2:-}"
			MANIFEST=""
			if [ "${3:-}" = "--aliases" ]; then
				if [ $# -ne 4 ] || [ -z "${4:-}" ]; then
					echo "usage: ./install.sh --repo /path/to/repo [--aliases manifest.tsv]" >&2
					exit 1
				fi
				MANIFEST="$4"
			elif [ $# -ne 2 ]; then
				echo "usage: ./install.sh --repo /path/to/repo [--aliases manifest.tsv]" >&2
				exit 1
			fi
			[ -n "$TARGET" ] || {
				echo "usage: ./install.sh --repo /path/to/repo [--aliases manifest.tsv]" >&2
				exit 1
			}
			mkdir -p "$TARGET/.agents/skills"
			if [ -n "$MANIFEST" ]; then
				ROWS="$(parse_alias_manifest "$MANIFEST")" || exit 1
				[ -n "$ROWS" ] || {
					echo "alias manifest is empty: $MANIFEST" >&2
					exit 1
				}
				link_skills_except "$TARGET/.agents/skills" "$ROWS"
				install_aliases_repo "$TARGET" "$MANIFEST" || exit 1
			else
				link_dir "$KIT_DIR/skills/core" "$TARGET/.agents/skills"
				link_dir "$KIT_DIR/skills/eshu" "$TARGET/.agents/skills"
			fi
			prune_dir "$TARGET/.agents/skills" "$KIT_DIR/skills/core/*" "$KIT_DIR/skills/eshu/*"
			stamp_version_pin "$TARGET"
			echo "installed kit skills into $TARGET/.agents/skills"
			;;
		--agents)
			SCOPE="${2:-}"
			case "$SCOPE" in
			--global)
				resolve_harnesses "${@:3}" || exit 1
				install_agents_global
				;;
			--repo)
				TARGET="${3:-}"
				[ -n "$TARGET" ] || {
					echo "usage: ./install.sh --agents --repo /path/to/repo" >&2
					exit 1
				}
				install_agents_repo "$TARGET"
				stamp_version_pin "$TARGET"
				;;
			*)
				echo "usage: ./install.sh --agents --global [harness...] | ./install.sh --agents --repo /path/to/repo" >&2
				exit 1
				;;
			esac
			;;
		--hooks)
			install_hooks_mode "${@:2}" || exit 1
			;;
		--rules)
			SCOPE="${2:-}"
			case "$SCOPE" in
			--repo)
				TARGET="${3:-}"
				[ -n "$TARGET" ] || {
					echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
					exit 1
				}
				install_rules_repo "$TARGET"
				stamp_version_pin "$TARGET"
				;;
			*)
				echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
				exit 1
				;;
			esac
			;;
		*)
			echo "usage: ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv] | ./install.sh --agents (--global [harness...] | --repo /path/to/repo) | ./install.sh --hooks (--repo /path/to/repo | --global (muse|claude|opencode)) | ./install.sh --rules --repo /path/to/repo | ./install.sh --uninstall (--repo | --agents --repo | --hooks --repo | --rules --repo /path/to/repo | --global [harness...] | --agents --global [harness...] | --hooks --global (muse|claude|opencode)) [--force]  (harnesses: claude, codex, opencode, muse, cursor, all)" >&2
			echo "run ./install.sh --help for the full reference" >&2
			exit 1
			;;
		esac
	fi
	;;
esac
