#!/usr/bin/env bash
# Install eshu-agent-kit skills, agents, hooks, and rules into a harness or a repo checkout.
# Usage:
#   ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv]
#   ./install.sh --agents --global [harness...] | ./install.sh --agents --repo /path/to/repo
#   ./install.sh --hooks --repo /path/to/repo   (scripts only; wire them per hooks/README.md)
#   ./install.sh --hooks --global muse         (machine-wide Muse hooks; explicit opt-in)
#   ./install.sh --rules --repo /path/to/repo   (Claude Code path-scoped rules + rules lint script)
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
	mkdir -p "$dest"
	awk -v m="$model" '
	!done && /^model = / { printf "model = \"%s\"\n", m; done=1; next }
	!done && /^model: /  { printf "model: %s\n", m;      done=1; next }
	{ print }
	' "$src" >"$dest/$(basename "$src")"
}

# Shared JSONC reader for the OpenCode config: JSON first, then a tolerant
# pass that strips // and /* comments (string-aware) and trailing commas.
# Modes: model -> print the top-level model; get <role> -> print that agent's
# configured model; merge <main> <role> <model>... -> write the merged file.
OC_PY='
import json, sys

def strip_comments(text):
	out, i, n, in_str = [], 0, len(text), False
	while i < n:
		c = text[i]
		if in_str:
			out.append(c)
			if c == "\\" and i + 1 < n:
				out.append(text[i + 1]); i += 2; continue
			if c == "\"":
				in_str = False
			i += 1
		elif c == "\"":
			in_str = True; out.append(c); i += 1
		elif text.startswith("//", i):
			while i < n and text[i] != "\n":
				i += 1
		elif text.startswith("/*", i):
			j = text.find("*/", i + 2)
			i = n if j < 0 else j + 2
		else:
			out.append(c); i += 1
	return "".join(out)

def drop_trailing_commas(text):
	# Single string-aware pass: a comma whose next non-space char is } or ]
	# is dropped; commas inside string values are copied verbatim.
	out, i, n, in_str = [], 0, len(text), False
	while i < n:
		c = text[i]
		if in_str:
			out.append(c)
			if c == "\\" and i + 1 < n:
				out.append(text[i + 1]); i += 2; continue
			if c == "\"":
				in_str = False
			i += 1
		elif c == "\"":
			in_str = True; out.append(c); i += 1
		elif c == ",":
			j = i + 1
			while j < n and text[j] in " \t\r\n":
				j += 1
			if j < n and text[j] in "}]":
				i += 1
			else:
				out.append(c); i += 1
		else:
			out.append(c); i += 1
	return "".join(out)

def load_jsonc(text):
	try:
		return json.loads(text)
	except Exception:
		pass
	return json.loads(drop_trailing_commas(strip_comments(text)))

def read_config(path):
	raw = ""
	try:
		raw = open(path).read()
	except FileNotFoundError:
		pass
	if not raw.strip():
		return {}
	data = load_jsonc(raw)
	if not isinstance(data, dict):
		raise ValueError("top-level JSON value is not an object")
	return data

path, mode, *rest = sys.argv[1:]
try:
	data = read_config(path)
except Exception as exc:
	print("opencode config not mergeable: %s" % exc, file=sys.stderr)
	sys.exit(1)
if mode == "model":
	m = data.get("model", "")
	print(m if isinstance(m, str) else "")
elif mode == "get":
	for k in ("agents", "agent"):
		sec = data.get(k)
		if isinstance(sec, dict):
			entry = sec.get(rest[0])
			if isinstance(entry, dict) and isinstance(entry.get("model"), str):
				print(entry["model"])
				break
else:
	main = rest[0] if rest else ""
	pairs = rest[1:] if rest else []
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
'

# Merge per-agent model choices (and the optional main model) into the global
# OpenCode config so they win over any stale frontmatter overrides.
merge_opencode_config() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	python3 - "$config" merge "$@" <<<"$OC_PY"
}

# Current value for one prompt default, through the same tolerant parser.
opencode_config_value() { # $1 config path, $2 mode, [$3 role]
	if [ "$2" = get ]; then
		python3 - "$1" get "$3" <<<"$OC_PY" 2>/dev/null || true
	else
		python3 - "$1" model <<<"$OC_PY" 2>/dev/null || true
	fi
}

# Global opencode agents: ask a model per role, then sync the config section.
install_opencode_agents() {
	local config="$HOME/.config/opencode/opencode.jsonc"
	local current_main="" main f role model cfg
	current_main="$(opencode_config_value "$config" model)"
	main="$(ask_model "the main model" "${current_main:-}")"
	local -a pairs=()
	local file
	for file in "$KIT_DIR"/.opencode/agent/*.md; do
		[ -f "$file" ] || continue
		f="$(basename "$file" .md)"
		model="$(agent_model_default opencode "$f")"
		cfg="$(opencode_config_value "$config" get "$f")"
		[ -n "$cfg" ] && model="$cfg"
		model="$(ask_model "$f" "$model")"
		write_agent_file "$file" "$HOME/.config/opencode/agents" "$model"
		pairs+=("$f" "$model")
	done
	merge_opencode_config "$main" "${pairs[@]}"
	prune_dir "$HOME/.config/opencode/agents" "$KIT_DIR/.opencode/agent/*.md"
	echo "installed kit agents for opencode (model choices recorded in $config)"
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

install_global() {
	local harness dir
	for harness in "${selected[@]}"; do
		dir="$(skills_dir_for "$harness")"
		link_dir "$KIT_DIR/skills/core" "$dir"
		link_dir "$KIT_DIR/skills/eshu" "$dir"
		prune_dir "$dir" "$KIT_DIR/skills/core/*" "$KIT_DIR/skills/eshu/*"
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
	MANIFEST=""
	if [ "${3:-}" = "--aliases" ]; then
		MANIFEST="${4:-}"
		[ -n "$MANIFEST" ] || {
			echo "usage: ./install.sh --repo /path/to/repo [--aliases manifest.tsv]" >&2
			exit 1
		}
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
	SCOPE="${2:-}"
	case "$SCOPE" in
	--repo)
		TARGET="${3:-}"
		[ -n "$TARGET" ] || {
			echo "usage: ./install.sh --hooks --repo /path/to/repo" >&2
			exit 1
		}
		install_hooks_repo "$TARGET"
		stamp_version_pin "$TARGET"
		;;
	--global)
		# Machine-wide hooks execute outside the Muse sandbox in every
		# workspace, so this is an explicit muse-only opt-in, never a
		# default or part of plain --global.
		[ "${3:-}" = muse ] && [ -z "${4:-}" ] || {
			echo "usage: ./install.sh --hooks --global muse" >&2
			exit 1
		}
		install_hooks_global_muse
		;;
	*)
		echo "usage: ./install.sh --hooks --repo /path/to/repo | ./install.sh --hooks --global muse" >&2
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
		stamp_version_pin "$TARGET"
		;;
	*)
		echo "usage: ./install.sh --rules --repo /path/to/repo" >&2
		exit 1
		;;
	esac
	;;
*)
	echo "usage: ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv] | ./install.sh --agents (--global [harness...] | --repo /path/to/repo) | ./install.sh --hooks (--repo /path/to/repo | --global muse) | ./install.sh --rules --repo /path/to/repo  (harnesses: claude, codex, opencode, muse, cursor, all)" >&2
	exit 1
	;;
esac
