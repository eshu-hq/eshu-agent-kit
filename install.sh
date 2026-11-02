#!/usr/bin/env bash
# Install eshu-agent-kit skills, agents, hooks, and rules into a harness or a repo checkout.
# Usage:
#   ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo
#   ./install.sh --agents --global [harness...] | ./install.sh --agents --repo /path/to/repo
#   ./install.sh --hooks --repo /path/to/repo   (scripts only; wire them per hooks/README.md)
#   ./install.sh --rules --repo /path/to/repo   (Claude Code path-scoped rules + rules lint script)
# Harness names for the global modes: claude, codex, opencode, muse, cursor, or all.
# No harness name means all. The global modes ask a model ID per agent; the
# default is the kit value from agents/roles.json, so plain Enter keeps it.
# Piped or empty stdin also keeps every default. Repo modes never prompt.
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
	local pattern="$1" dest="$2"
	mkdir -p "$dest"
	for f in $pattern; do
		[ -f "$f" ] || continue
		ln -sfn "$f" "$dest/$(basename "$f")"
	done
}

resolve_harnesses() {
	local h
	selected=()
	if [ "$#" -eq 0 ]; then
		selected=("${HARNESSES[@]}")
		return 0
	fi
	for h in "$@"; do
		case "$h" in
		all)
			selected=("${HARNESSES[@]}")
			return 0
			;;
		claude | codex | opencode | muse | cursor) selected+=("$h") ;;
		*)
			printf 'unknown harness: %s (choose: claude, codex, opencode, muse, cursor, all)\n' "$h" >&2
			return 1
			;;
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
	muse) printf '%s\n' "$HOME/.agents/agents" ;;
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
	read -r ans || true
	printf '%s\n' "${ans:-$def}"
}

# Rewrite the model line of one agent file into the global directory.
write_agent_file() {
	local src="$1" dest="$2" model="$3"
	mkdir -p "$dest"
	awk -v m="$model" '
	!done && /^model = / { printf "model = \"%s\"\n", m; done=1; next }
	!done && /^model: /  { printf "model: %s\n", m;      done=1; next }
	{ print }
	' "$src" >"$dest/$(basename "$src")"
}

# Merge per-agent model choices (and the optional main model) into the global
# OpenCode config so they win over any stale frontmatter overrides.
merge_opencode_config() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	python3 - "$config" "$@" <<'PY'
import json, sys

def strip_comments(text):
	out, i, n, in_str = [], 0, len(text), False
	while i < n:
		c = text[i]
		if in_str:
			out.append(c)
			if c == "\\" and i + 1 < n:
				out.append(text[i + 1]); i += 2; continue
			if c == '"':
				in_str = False
			i += 1
		elif text.startswith("//", i):
			while i < n and text[i] != "\n":
				i += 1
		elif text.startswith("/*", i):
			j = text.find("*/", i + 2)
			i = n if j < 0 else j + 2
		else:
			out.append(c); i += 1
	return "".join(out)

path, main, *pairs = sys.argv[1:]
data = {}
try:
	raw = open(path).read()
	data = json.loads(strip_comments(raw)) if raw.strip() else {}
except Exception:
	data = {}
if main:
	data["model"] = main
keys = [k for k in ("agents", "agent") if isinstance(data.get(k), dict)]
if not keys:
	keys = ["agents"]
for k in keys:
	if not isinstance(data.get(k), dict):
		data[k] = {}
for i in range(0, len(pairs), 2):
	role, model = pairs[i], pairs[i + 1]
	for k in keys:
		entry = data[k].get(role)
		data[k][role] = dict(entry, model=model) if isinstance(entry, dict) else {"model": model}
open(path, "w").write(json.dumps(data, indent=2) + "\n")
PY
}

# Global opencode agents: ask a model per role, then sync the config section.
install_opencode_agents() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	local current_main="" main f role model
	current_main="$(python3 -c "import json;print(json.load(open('$config')).get('model',''))" 2>/dev/null || true)"
	main="$(ask_model "the main model" "${current_main:-}")"
	local -a pairs=()
	local file
	for file in "$KIT_DIR"/.opencode/agent/*.md; do
		[ -f "$file" ] || continue
		f="$(basename "$file" .md)"
		model="$(agent_model_default opencode "$f")"
		model="$(ask_model "$f" "$model")"
		write_agent_file "$file" "$HOME/.config/opencode/agents" "$model"
		pairs+=("$f" "$model")
	done
	merge_opencode_config "$main" "${pairs[@]}"
	echo "installed kit agents for opencode (model choices recorded in $config)"
}

install_agents_for() {
	local harness="$1" f role model
	for f in $(agents_src_for "$harness"); do
		role="$(basename "$f")"
		role="${role%.*}"
		model="$(agent_model_default "$harness" "$role")"
		model="$(ask_model "$role" "$model")"
		write_agent_file "$f" "$(agents_dir_for "$harness")" "$model"
	done
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

install_global() {
	local harness dir
	for harness in "${selected[@]}"; do
		dir="$(skills_dir_for "$harness")"
		link_dir "$KIT_DIR/skills/core" "$dir"
		link_dir "$KIT_DIR/skills/eshu" "$dir"
	done
	install_agents_global
	echo "installed kit skills and agents globally from $KIT_DIR for: ${selected[*]}"
}

case "$MODE" in
--global)
	resolve_harnesses "${@:2}" || exit 1
	install_global
	;;
--repo)
	TARGET="${2:-}"
	[ -n "$TARGET" ] || {
		echo "usage: ./install.sh --repo /path/to/repo" >&2
		exit 1
	}
	mkdir -p "$TARGET/.agents/skills"
	link_dir "$KIT_DIR/skills/core" "$TARGET/.agents/skills"
	link_dir "$KIT_DIR/skills/eshu" "$TARGET/.agents/skills"
	cat "$KIT_DIR/VERSION" >"$TARGET/.agent-kit-version"
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
		;;
	*)
		echo "usage: ./install.sh --agents --global [harness...] | ./install.sh --agents --repo /path/to/repo" >&2
		exit 1
		;;
	esac
	;;
--hooks)
	SCOPE="${2:-}"
	case "$SCOPE" in
	--repo)
		TARGET="${3:-}"
		[ -n "$TARGET" ] || {
			echo "usage: ./install.sh --hooks --repo /path/to/repo" >&2
			exit 1
		}
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
		[ -n "$TARGET" ] || {
			echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
			exit 1
		}
		install_rules_repo "$TARGET"
		;;
	*)
		echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "usage: ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo | ./install.sh --agents (--global [harness...] | --repo /path/to/repo) | ./install.sh --hooks --repo /path/to/repo | ./install.sh --rules --repo /path/to/repo  (harnesses: claude, codex, opencode, muse, cursor, all)" >&2
	exit 1
	;;
esac
