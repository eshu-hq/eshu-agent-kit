# install-uninstall.sh — sourced by install.sh (not run on its own).
# --uninstall removes what the kit provably owns and prints every removal.
# Requires KIT_DIR from the caller, install-prune.sh (the ownership proof
# prune_owns_entry both modes share), install-hooks-global.sh (the Muse
# tree layout), and the harness mappers from install.sh.
# shellcheck shell=bash
#
# Removal rule: only kit-owned entries go away, and only with proof --
#   - symlinks resolving into this kit (or dangling links naming an
#     eshu-agent-kit* path), via prune_owns_entry;
#   - regular files carrying the Generated-by marker, via prune_owns_entry;
#   - repo agent copies and .muse/hooks.json: plain copies with no marker,
#     so ownership is proved by byte-identity with the kit source;
#   - .agent-kit-version: removed only when it stamps this kit's VERSION.
# Never removed: unmarked user files, modified copies, symlinks pointing
# outside the kit, and real directories -- except alias wrappers (real
# dirs carrying .kit-alias), which go only with --force. The superseded
# ~/.agents/agents is never managed and never touched. Settings keys that
# hold merged user choices (opencode.jsonc, Muse settings.json) have no
# safe inverse, so uninstall prints the manual undo instead of editing
# them. Removals print `removed <path>` on stdout; keeps worth knowing
# about print `keeping <path> (<reason>)` on stderr.
UNINSTALL_REMOVED=0

uninstall_remove() {
	rm -f "$1"
	UNINSTALL_REMOVED=$((UNINSTALL_REMOVED + 1))
	printf 'removed %s\n' "$1"
}

uninstall_keeping() {
	printf 'keeping %s (%s)\n' "$1" "$2" >&2
}

# uninstall_alias_dir <dir> -- true when dir is a kit alias wrapper:
# a real directory whose .kit-alias marker names this exact alias AND a
# real kit skill source, exactly as materialize_alias writes it. Presence
# alone is not enough: --force deletes, so a stray marker file must never
# qualify a user directory -- not even one that shares the alias-name
# prefix with an empty source.
uninstall_alias_dir() {
	local marker="$1/.kit-alias" line want src
	[ -d "$1" ] && [ ! -L "$1" ] && [ -f "$marker" ] || return 1
	line="$(cat "$marker")"
	want="alias=$(basename "$1") source="
	case "$line" in
	"$want"?*) src="${line#$want}" ;;
	*) return 1 ;;
	esac
	[ -d "$KIT_DIR/skills/eshu/$src" ] || [ -d "$KIT_DIR/skills/core/$src" ] || return 1
	return 0
}

# uninstall_managed_tree <dir> <force> -- drop owned entries and, with
# --force, alias wrapper dirs; everything else stays.
uninstall_managed_tree() {
	local dir="$1" force="$2" e
	[ -d "$dir" ] || return 0
	for e in "$dir"/*; do
		[ -e "$e" ] || [ -L "$e" ] || continue
		if prune_owns_entry "$e"; then
			uninstall_remove "$e"
		elif uninstall_alias_dir "$e"; then
			if [ "$force" = 1 ]; then
				rm -rf "$e"
				UNINSTALL_REMOVED=$((UNINSTALL_REMOVED + 1))
				printf 'removed %s\n' "$e"
			else
				uninstall_keeping "$e" "kit alias wrapper; re-run with --force to remove"
			fi
		fi
	done
}

# uninstall_model_only_diff <file> <source> -- true when the two files
# differ only in their model lines (md `model:` or toml `model =`).
uninstall_model_only_diff() {
	cmp -s "$1" "$2" && return 1
	cmp -s <(grep -v '^model[ :=]' "$1") <(grep -v '^model[ :=]' "$2")
}

# uninstall_copy_tree <dir> <src-glob> <mode> <force> -- drop generated
# copies: owned entries, then files byte-identical to their kit source.
# mode is strict (repo copies: any edit makes them consumer-owned) or
# model (global agent files: a model-line-only diff is the installer's
# own prompt answer, so --force may remove it; deeper edits never go).
uninstall_copy_tree() {
	local dir="$1" srcglob="$2" mode="$3" force="$4"
	[ -d "$dir" ] || return 0
	local e base s src
	for e in "$dir"/*; do
		[ -e "$e" ] || [ -L "$e" ] || continue
		if [ -L "$e" ]; then
			# Links carry no user choices: the ownership proof decides.
			prune_owns_entry "$e" || continue
			uninstall_remove "$e"
			continue
		fi
		[ -f "$e" ] || continue
		base="$(basename "$e")"
		src=""
		for s in $srcglob; do
			[ -f "$s" ] || continue
			if [ "$(basename "$s")" = "$base" ]; then
				src="$s"
				break
			fi
		done
		if [ -n "$src" ] && cmp -s "$e" "$src"; then
			uninstall_remove "$e"
		elif [ "$mode" = model ] && [ -n "$src" ] && uninstall_model_only_diff "$e" "$src"; then
			if [ "$force" = 1 ]; then
				uninstall_remove "$e"
			else
				uninstall_keeping "$e" "carries model choices; re-run with --force to remove"
			fi
		elif [ -n "$src" ]; then
			# An edit keeps the Generated-by marker, so the marker alone
			# never authorizes a delete: only a byte-identical copy goes.
			uninstall_keeping "$e" "modified copy; remove by hand"
		elif prune_owns_entry "$e"; then
			# Kit-owned but no longer shipped: still someone's file until
			# a human says otherwise.
			uninstall_keeping "$e" "stale kit copy, no kit source to compare; remove by hand"
		fi
	done
}

# uninstall_identical_copy <path> <kit-source> <reason> -- drop a plain
# installer copy (hooks.json, managed-hooks.json) only when it still
# matches the kit source byte for byte; a modified copy is consumer-owned.
uninstall_identical_copy() {
	local path="$1" src="$2" reason="$3"
	[ -e "$path" ] || [ -L "$path" ] || return 0
	if [ -L "$path" ]; then
		if prune_owns_entry "$path"; then
			uninstall_remove "$path"
		else
			uninstall_keeping "$path" "link points outside the kit; left in place"
		fi
	elif cmp -s "$path" "$src"; then
		uninstall_remove "$path"
	else
		uninstall_keeping "$path" "$reason"
	fi
}

# uninstall_version_pin <target> -- drop .agent-kit-version only when it
# stamps this kit's VERSION; a foreign value may belong to another
# checkout or to the consumer.
uninstall_version_pin() {
	local pin="$1/.agent-kit-version" want
	[ -e "$pin" ] || [ -L "$pin" ] || return 0
	want="$(cat "$KIT_DIR/VERSION")"
	if [ -f "$pin" ] && [ ! -L "$pin" ] && [ "$(cat "$pin")" = "$want" ]; then
		uninstall_remove "$pin"
	else
		uninstall_keeping "$pin" "does not stamp this kit VERSION; left in place"
	fi
}

# uninstall_rmdir <dir> -- drop a managed dir left empty by the removals.
uninstall_rmdir() {
	[ -d "$1" ] || return 0
	rmdir "$1" 2>/dev/null && printf 'removed empty dir: %s\n' "$1" || true
}

uninstall_repo() {
	local target="$1" scope="$2" force="$3"
	case "$scope" in
	all | agents)
		uninstall_copy_tree "$target/.agents/agents" "$KIT_DIR/agents/*.md" strict "$force"
		uninstall_managed_tree "$target/.claude/agents" "$force"
		uninstall_managed_tree "$target/.codex/agents" "$force"
		uninstall_managed_tree "$target/.opencode/agent" "$force"
		uninstall_managed_tree "$target/.cursor/agents" "$force"
		uninstall_managed_tree "$target/.agy/agents" "$force"
		uninstall_identical_copy "$target/.agents/roles.json" "$KIT_DIR/agents/roles.json" "points outside the kit; left in place"
		uninstall_identical_copy "$target/scripts/agent-roles.py" "$KIT_DIR/agents/agent-roles.py" "points outside the kit; left in place"
		;;
	esac
	case "$scope" in
	all | hooks)
		uninstall_managed_tree "$target/.claude/hooks" "$force"
		uninstall_managed_tree "$target/.claude/hooks/lib" "$force"
		uninstall_managed_tree "$target/.codex/hooks" "$force"
		uninstall_managed_tree "$target/.cursor/hooks" "$force"
		uninstall_managed_tree "$target/.muse/hooks" "$force"
		uninstall_managed_tree "$target/.muse/hooks/lib" "$force"
		uninstall_agy_hooks_repo "$target" "$force"
		uninstall_identical_copy "$target/scripts/check-docs-stale.sh" "$KIT_DIR/scripts/check-docs-stale.sh" "consumer-owned script; left in place"
		uninstall_identical_copy "$target/scripts/watch-pr.sh" "$KIT_DIR/scripts/watch-pr.sh" "consumer-owned script; left in place"
		uninstall_identical_copy "$target/scripts/cross-review.sh" "$KIT_DIR/scripts/cross-review.sh" "consumer-owned script; left in place"
		uninstall_identical_copy "$target/.muse/hooks.json" "$KIT_DIR/hooks/muse/hooks.json" "consumer-owned hooks.json; left in place"
		;;
	esac
	case "$scope" in
	all | rules)
		uninstall_managed_tree "$target/.claude/rules" "$force"
		uninstall_identical_copy "$target/scripts/claude-rules-lint.sh" "$KIT_DIR/scripts/claude-rules-lint.sh" "points outside the kit; left in place"
		;;
	esac
	case "$scope" in
	all)
		uninstall_managed_tree "$target/.agents/skills" "$force"
		uninstall_managed_tree "$target/.claude/skills" "$force"
		uninstall_managed_tree "$target/.codex/skills" "$force"
		;;
	esac
	if [ "$scope" = all ]; then
		uninstall_version_pin "$target"
	fi
	uninstall_rmdir "$target/.agents/skills"
	uninstall_rmdir "$target/.agents/agents"
	uninstall_rmdir "$target/.agents"
	uninstall_rmdir "$target/.claude/skills"
	uninstall_rmdir "$target/.claude/agents"
	uninstall_rmdir "$target/.claude/hooks/lib"
	uninstall_rmdir "$target/.claude/hooks"
	uninstall_rmdir "$target/.claude/rules"
	uninstall_rmdir "$target/.codex/skills"
	uninstall_rmdir "$target/.codex/agents"
	uninstall_rmdir "$target/.codex/hooks"
	uninstall_rmdir "$target/.opencode/agent"
	uninstall_rmdir "$target/.cursor/agents"
	uninstall_rmdir "$target/.cursor/hooks"
	uninstall_rmdir "$target/.agy/agents"
	uninstall_rmdir "$target/.muse/hooks/lib"
	uninstall_rmdir "$target/.muse/hooks"
	uninstall_rmdir "$target/.muse"
	uninstall_rmdir "$target/.claude"
	uninstall_rmdir "$target/.codex"
	uninstall_rmdir "$target/.opencode"
	uninstall_rmdir "$target/.cursor"
	uninstall_rmdir "$target/.agy"
	uninstall_rmdir "$target/scripts"
}

uninstall_global_agents() {
	local force="$1" harness
	for harness in "${selected[@]}"; do
		uninstall_copy_tree "$(agents_dir_for "$harness")" "$(agents_src_for "$harness")" model "$force"
	done
}

uninstall_global_skills() {
	local force="$1" harness
	for harness in "${selected[@]}"; do
		uninstall_managed_tree "$(skills_dir_for "$harness")" "$force"
	done
}

# uninstall_opencode_note -- the model merge has no safe inverse, so the
# config is never edited; print the manual undo when there is one pending.
uninstall_opencode_note() {
	local harness cfg
	for harness in "${selected[@]}"; do
		[ "$harness" = opencode ] || continue
		cfg="$HOME/.config/opencode/opencode.jsonc"
		if [ -e "$cfg" ]; then
			uninstall_keeping "$cfg" "opencode model merge has no safe inverse; remove kit agent entries by hand"
		fi
	done
}

uninstall_hooks_global_muse() {
	local force="${1:-0}" cfg settings tree managed expected val
	cfg="$(muse_config_dir)"
	settings="$cfg/settings.json"
	tree="$cfg/agent-kit-hooks"
	managed="$tree/managed-hooks.json"
	uninstall_managed_tree "$tree/.claude/hooks" "$force"
	uninstall_managed_tree "$tree/.claude/hooks/lib" "$force"
	uninstall_managed_tree "$tree/.muse/hooks" "$force"
	uninstall_managed_tree "$tree/.muse/hooks/lib" "$force"
	if [ -e "$managed" ] || [ -L "$managed" ]; then
		if command -v python3 >/dev/null 2>&1; then
			expected="$(mktemp)" || return 1
			if write_managed_hooks "$expected" "$tree" 2>/dev/null && cmp -s "$managed" "$expected"; then
				uninstall_remove "$managed"
			else
				uninstall_keeping "$managed" "differs from the generated file; remove by hand"
			fi
			rm -f "$expected"
		else
			uninstall_keeping "$managed" "cannot verify without python3; remove by hand"
		fi
	fi
	uninstall_rmdir "$tree/.claude/hooks/lib"
	uninstall_rmdir "$tree/.claude/hooks"
	uninstall_rmdir "$tree/.claude"
	uninstall_rmdir "$tree/.muse/hooks/lib"
	uninstall_rmdir "$tree/.muse/hooks"
	uninstall_rmdir "$tree/.muse"
	uninstall_rmdir "$tree"
	if [ -e "$settings" ]; then
		val="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("managed_hooks_path", ""))' "$settings" 2>/dev/null)" || val="UNREADABLE"
		if [ "$val" = "$managed" ]; then
			uninstall_keeping "$settings" "remove the managed_hooks_path key by hand to finish uninstall"
		elif [ "$val" = "UNREADABLE" ]; then
			uninstall_keeping "$settings" "left untouched; remove kit keys by hand if present"
		else
			uninstall_keeping "$settings" "no kit managed_hooks_path; left untouched"
		fi
	fi
}

# uninstall_hooks_global_claude <force> -- drop the machine-wide Claude
# hook tree. The hook entries live merged inside the user's
# ~/.claude/settings.json hooks block, which uninstall never edits (same
# rule as every other settings key): they are reported with a manual
# undo, and the tree goes only when it holds nothing but kit links.
uninstall_hooks_global_claude() {
	local force="${1:-0}" cfg settings tree
	cfg="$HOME/.claude"
	settings="$cfg/settings.json"
	tree="$cfg/agent-kit-hooks"
	uninstall_managed_tree "$tree/.claude/hooks" "$force"
	uninstall_managed_tree "$tree/.claude/hooks/lib" "$force"
	uninstall_rmdir "$tree/.claude/hooks/lib"
	uninstall_rmdir "$tree/.claude/hooks"
	uninstall_rmdir "$tree/.claude"
	uninstall_rmdir "$tree"
	if [ -e "$settings" ] && rg -q "agent-kit-hooks" "$settings" 2>/dev/null; then
		uninstall_keeping "$settings" "still holds kit hook entries; delete them by hand to finish uninstall (undo: remove the kit entries and $tree)"
	elif [ -e "$settings" ]; then
		uninstall_keeping "$settings" "no kit hook entries; left untouched"
	fi
}

# uninstall_hooks_global_opencode -- drop the machine-wide OpenCode bridge
# file. Ownership is proved by regenerating the expected content to a temp
# file and byte-comparing (the managed-hooks.json precedent): a modified or
# foreign file is reported with a manual undo, never deleted. The shared
# plugins directory is never scanned and user plugins are never touched.
uninstall_hooks_global_opencode() {
	local dir dest expected
	dir="$(opencode_plugin_dir)"
	dest="$dir/eshu-bridge.js"
	if [ ! -e "$dest" ] && [ ! -L "$dest" ]; then
		uninstall_keeping "$dest" "no kit bridge installed; left untouched"
		return 0
	fi
	expected="$(mktemp)" || return 1
	if ! write_opencode_plugin "$expected" >/dev/null 2>&1; then
		rm -f "$expected"
		uninstall_keeping "$dest" "cannot regenerate the kit bridge here; remove by hand if it is yours"
		return 0
	fi
	if cmp -s "$dest" "$expected"; then
		rm -f "$expected"
		uninstall_remove "$dest"
	else
		rm -f "$expected"
		uninstall_keeping "$dest" "differs from the kit bridge; remove by hand to finish uninstall"
	fi
}

uninstall_global() {
	local scope="$1" force="$2" harness tree bridge
	case "$scope" in
	all)
		uninstall_global_skills "$force"
		uninstall_global_agents "$force"
		uninstall_opencode_note
		# Global hooks are sticky on purpose: a broad uninstall never
		# removes them as a side effect, it only points at the explicit
		# --hooks --global undo. The Muse tree already works this way;
		# Claude and OpenCode match it here.
		for harness in "${selected[@]}"; do
			case "$harness" in
			muse)
				tree="$(muse_config_dir)/agent-kit-hooks"
				if [ -e "$tree" ]; then
					uninstall_keeping "$tree" "installed by --hooks --global muse; run --uninstall --hooks --global muse to remove it"
				fi
				;;
			claude)
				tree="$HOME/.claude/agent-kit-hooks"
				if [ -e "$tree" ]; then
					uninstall_keeping "$tree" "installed by --hooks --global claude; run --uninstall --hooks --global claude to remove it"
				fi
				;;
			agy) uninstall_note_global_agy ;;
			opencode)
				bridge="$(opencode_plugin_dir)/eshu-bridge.js"
				if [ -e "$bridge" ] || [ -L "$bridge" ]; then
					uninstall_keeping "$bridge" "installed by --hooks --global opencode; run --uninstall --hooks --global opencode to remove it"
				fi
				;;
			esac
		done
		;;
	agents)
		uninstall_global_agents "$force"
		uninstall_opencode_note
		;;
	esac
}

uninstall_usage() {
	echo "usage: ./install.sh --uninstall --repo /path/to/repo [--force]" >&2
	echo "       ./install.sh --uninstall (--agents|--hooks|--rules) --repo /path/to/repo [--force]" >&2
	echo "       ./install.sh --uninstall --global [harness...] [--force]" >&2
	echo "       ./install.sh --uninstall --agents --global [harness...] [--force]" >&2
	echo "       ./install.sh --uninstall --hooks --global (muse|claude|opencode|agy) [--force]" >&2
}

uninstall_main() {
	local force=0 rest=() a
	for a in "$@"; do
		case "$a" in
		--force) force=1 ;;
		*) rest+=("$a") ;;
		esac
	done
	set -- ${rest[@]+"${rest[@]}"}
	case "${1:-}" in
	--repo)
		[ $# -eq 2 ] && [ -n "${2:-}" ] || {
			uninstall_usage
			return 1
		}
		[ -e "$2" ] || {
			echo "target not found: $2" >&2
			return 1
		}
		uninstall_repo "$2" all "$force"
		;;
	--agents)
		if [ "${2:-}" = --repo ] && [ $# -eq 3 ] && [ -n "${3:-}" ]; then
			[ -e "$3" ] || {
				echo "target not found: $3" >&2
				return 1
			}
			uninstall_repo "$3" agents "$force"
		elif [ "${2:-}" = --global ]; then
			shift 2
			resolve_harnesses "$@" || return 1
			uninstall_global agents "$force"
		else
			uninstall_usage
			return 1
		fi
		;;
	--hooks)
		if [ "${2:-}" = --repo ] && [ $# -eq 3 ] && [ -n "${3:-}" ]; then
			[ -e "$3" ] || {
				echo "target not found: $3" >&2
				return 1
			}
			uninstall_repo "$3" hooks "$force"
		elif [ "${2:-}" = --global ] && [ "${3:-}" = muse ] && [ $# -eq 3 ]; then
			uninstall_hooks_global_muse "$force"
		elif [ "${2:-}" = --global ] && [ "${3:-}" = claude ] && [ $# -eq 3 ]; then
			uninstall_hooks_global_claude "$force"
		elif [ "${2:-}" = --global ] && [ "${3:-}" = opencode ] && [ $# -eq 3 ]; then
			uninstall_hooks_global_opencode
		elif [ "${2:-}" = --global ] && [ "${3:-}" = agy ] && [ $# -eq 3 ]; then
			uninstall_hooks_global_agy "$force"
		else
			uninstall_usage
			return 1
		fi
		;;
	--rules)
		[ "${2:-}" = --repo ] && [ $# -eq 3 ] && [ -n "${3:-}" ] || {
			uninstall_usage
			return 1
		}
		[ -e "$3" ] || {
			echo "target not found: $3" >&2
			return 1
		}
		uninstall_repo "$3" rules "$force"
		;;
	--global)
		shift
		resolve_harnesses "$@" || return 1
		uninstall_global all "$force"
		;;
	*)
		uninstall_usage
		return 1
		;;
	esac
}
