#!/usr/bin/env bash
# Install eshu-agent-kit skills, agents, hooks, and rules into a harness or a repo checkout.
# Usage:
#   ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv]
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
	echo "installed kit agents for opencode (model choices recorded in $config)"
}

install_agents_for() {
	local harness="$1" f role model
	for f in $(agents_src_for "$harness"); do
		[ -f "$f" ] || continue
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
	local target="$1" f
	mkdir -p "$target/.claude/rules" "$target/scripts"
	# rules/README.md is the index, not a rule: it has no `paths:`
	# frontmatter, so installing it would load index prose at launch and
	# trip claude-rules-lint in every consumer. Link the rules only.
	for f in "$KIT_DIR"/rules/*.md; do
		[ -f "$f" ] || continue
		[ "$(basename "$f")" = README.md ] && continue
		ln -sfn "$f" "$target/.claude/rules/$(basename "$f")"
	done
	link_files "$KIT_DIR/scripts/claude-rules-lint.sh" "$target/scripts"
	echo "installed kit rules into $target/.claude/rules (+ scripts/claude-rules-lint.sh)"
	echo "run scripts/claude-rules-lint.sh in the repo after moving rules or their targets"
}

# Resolve one alias-manifest source to its kit directory, or fail.
alias_src_dir() {
	local src="$1"
	case "$src" in "" | */*)
		echo "bad skill source in alias manifest: $src" >&2
		return 1
		;;
	esac
	if [ -d "$KIT_DIR/skills/eshu/$src" ]; then
		printf '%s\n' "$KIT_DIR/skills/eshu/$src"
	elif [ -d "$KIT_DIR/skills/core/$src" ]; then
		printf '%s\n' "$KIT_DIR/skills/core/$src"
	else
		echo "unknown skill source in alias manifest: $src" >&2
		return 1
	fi
}

# Validate an alias manifest; print normalized "alias<TAB>source" rows.
# Format: "<alias><TAB><source>" per line; '#' comments, blanks skipped.
parse_alias_manifest() {
	local manifest="$1" line alias src seen_aliases="" seen_sources=""
	[ -f "$manifest" ] || {
		echo "alias manifest not found: $manifest" >&2
		return 1
	}
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '' | '#'*) continue ;; esac
		alias="${line%%$'\t'*}"
		src="${line#*$'\t'}"
		[ -n "$alias" ] && [ -n "$src" ] && [ "$line" = "$alias"$'\t'"$src" ] || {
			echo "bad alias row (want alias<TAB>source): $line" >&2
			return 1
		}
		case "$alias" in *[!a-z0-9-]* | "")
			echo "bad alias name: $alias" >&2
			return 1
			;;
		esac
		case " $seen_aliases " in *" $alias "*)
			echo "duplicate alias: $alias" >&2
			return 1
			;;
		esac
		alias_src_dir "$src" >/dev/null || return 1
		case " $seen_sources " in *" $src "*)
			echo "duplicate source: $src" >&2
			return 1
			;;
		esac
		if [ "$alias" != "$src" ]; then
			if [ -d "$KIT_DIR/skills/eshu/$alias" ] || [ -d "$KIT_DIR/skills/core/$alias" ]; then
				echo "alias shadows a kit skill: $alias" >&2
				return 1
			fi
		fi
		seen_aliases="$seen_aliases $alias"
		seen_sources="$seen_sources $src"
		printf '%s\t%s\n' "$alias" "$src"
	done <"$manifest"
}

# Link rewrite list: one literal sed expression per line, no regex
# groups, so BSD and GNU sed behave identically. Depths ../ and
# ../../ cover every cross-skill link in the kit; the resolve probe in
# test-repo-alias-install.sh fails the install if a new depth appears.
build_alias_link_sed() {
	local out="$1"
	shift
	: >"$out"
	local pair msrc malias
	for pair in "$@"; do
		msrc="${pair%% *}"
		malias="${pair#* }"
		[ "$msrc" = "$malias" ] && continue
		{
			echo "s|](../$msrc/|](../$malias/|g"
			echo "s|](../$msrc)|](../$malias)|g"
			echo "s|](../$msrc#|](../$malias#|g"
			echo "s|](../../$msrc/|](../../$malias/|g"
			echo "s|](../../$msrc)|](../../$malias)|g"
			echo "s|](../../$msrc#|](../../$malias#|g"
		} >>"$out"
	done
}

# Materialize one alias wrapper dir. Generated output: every .md is a copy
# with the alias frontmatter and alias cross-links, every other entry is a
# symlink, and .kit-alias records what generated it. Refuses to touch a
# real path it did not generate.
materialize_alias() { # $1 dest $2 srcdir $3 alias $4 srcbase $5 link-sed
	local dest="$1" srcdir="$2" alias="$3" srcbase="$4" link_sed="$5"
	if [ -L "$dest" ]; then
		rm -f "$dest"
	elif [ -e "$dest" ]; then
		if [ -f "$dest/.kit-alias" ] && [ "$(cat "$dest/.kit-alias")" = "alias=$alias source=$srcbase" ]; then
			rm -rf "$dest"
		else
			echo "refusing to overwrite real path: $dest" >&2
			return 1
		fi
	fi
	mkdir -p "$dest" || return 1
	local rel
	while IFS= read -r rel || [ -n "$rel" ]; do
		rel="${rel#./}"
		[ -n "$rel" ] || continue
		if [ -d "$srcdir/$rel" ]; then
			mkdir -p "$dest/$rel" || return 1
		elif [ "${rel##*.}" = md ]; then
			if [ "$(basename "$rel")" = SKILL.md ]; then
				sed -e "s/^name: $srcbase\$/name: $alias/" -f "$link_sed" "$srcdir/$rel" >"$dest/$rel" || return 1
			else
				sed -f "$link_sed" "$srcdir/$rel" >"$dest/$rel" || return 1
			fi
		else
			ln -sfn "$srcdir/$rel" "$dest/$rel" || return 1
		fi
	done < <(cd "$srcdir" && find . -mindepth 1 -print | LC_ALL=C sort) || return 1
	grep -q "^name: $alias\$" "$dest/SKILL.md" || {
		echo "alias frontmatter missing for: $alias" >&2
		return 1
	}
	printf 'alias=%s source=%s\n' "$alias" "$srcbase" >"$dest/.kit-alias" || return 1
}

# Install alias wrappers from a manifest into the repo harness skill trees.
install_aliases_repo() {
	local target="$1" manifest="$2"
	local rows row alias src srcdir tree link_sed tmpdir pairs
	tmpdir="$(mktemp -d)" || return 1
	rows="$(parse_alias_manifest "$manifest")"
	if [ -z "$rows" ]; then
		rm -rf "$tmpdir"
		echo "alias manifest is empty or invalid: $manifest" >&2
		return 1
	fi
	link_sed="$tmpdir/links.sed"
	pairs=()
	while IFS= read -r row || [ -n "$row" ]; do
		src="${row%% *}"
		alias="${row#* }"
		[ "$src" = "$alias" ] && continue
		pairs+=("$src $alias")
	done < <(printf '%s\n' "$rows" | awk -F'\t' '{print length($2), $2, $1}' | LC_ALL=C sort -rn | cut -d' ' -f2-)
	build_alias_link_sed "$link_sed" ${pairs[@]+"${pairs[@]}"} || {
		rm -rf "$tmpdir"
		return 1
	}
	for tree in "$target/.claude/skills" "$target/.codex/skills"; do
		mkdir -p "$tree" || {
			rm -rf "$tmpdir"
			return 1
		}
		while IFS= read -r row || [ -n "$row" ]; do
			alias="${row%%$'\t'*}"
			src="${row#*$'\t'}"
			srcdir="$(alias_src_dir "$src")" || {
				rm -rf "$tmpdir"
				return 1
			}
			materialize_alias "$tree/$alias" "$srcdir" "$alias" "$src" "$link_sed" || {
				rm -rf "$tmpdir"
				return 1
			}
		done < <(printf '%s\n' "$rows")
	done
	rm -rf "$tmpdir"
	echo "installed kit skill aliases into $target/.claude/skills and $target/.codex/skills"
}

# Link every kit skill except manifest-listed sources (those arrive as
# aliases instead, so no generic twin is ever discoverable).
link_skills_except() { # $1 dest $2 manifest-rows("alias<TAB>source")
	local dest="$1" rows="$2" skill name skip
	for skill in "$KIT_DIR"/skills/eshu/*/ "$KIT_DIR"/skills/core/*/; do
		[ -d "$skill" ] || continue
		name="$(basename "$skill")"
		skip=0
		while IFS= read -r row || [ -n "$row" ]; do
			[ "${row#*$'\t'}" = "$name" ] && skip=1 && break
		done < <(printf '%s\n' "$rows")
		[ "$skip" = 1 ] && continue
		if [ -e "$dest/$name" ] && [ ! -L "$dest/$name" ]; then
			echo "preserving existing skill: $dest/$name" >&2
			continue
		fi
		ln -sfn "$skill" "$dest/$name"
	done
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
	echo "usage: ./install.sh --global [harness...] | ./install.sh --repo /path/to/repo [--aliases manifest.tsv] | ./install.sh --agents (--global [harness...] | --repo /path/to/repo) | ./install.sh --hooks --repo /path/to/repo | ./install.sh --rules --repo /path/to/repo  (harnesses: claude, codex, opencode, muse, cursor, all)" >&2
	exit 1
	;;
esac
