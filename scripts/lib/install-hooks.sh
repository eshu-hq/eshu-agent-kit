# Hook script delivery for repo installs. Sourced by install.sh; extracted
# to keep the entrypoint under the 500-line cap, like install-aliases.sh.
# shellcheck shell=bash

# Muse delivery: thin wrappers under .muse/hooks delegate to the
# .claude/hooks siblings linked in the same run, and .muse/hooks.json is
# the registration Muse reads at session start (project hooks run
# only after the folder is trusted, so an installed file is inert until
# then). An existing hooks.json is consumer-owned -- eshu's carries router
# and dispatch-guard entries the generic file must never clobber -- so it
# is preserved and reported, like check-docs-stale.sh below.
install_muse_hooks() {
	local target="$1"
	mkdir -p "$target/.muse/hooks/lib"
	link_files "$KIT_DIR/hooks/muse/*.sh" "$target/.muse/hooks"
	link_files "$KIT_DIR/hooks/muse/lib/*" "$target/.muse/hooks/lib"
	if [ -e "$target/.muse/hooks.json" ] || [ -L "$target/.muse/hooks.json" ]; then
		echo "preserving existing file: $target/.muse/hooks.json" >&2
	else
		cp "$KIT_DIR/hooks/muse/hooks.json" "$target/.muse/hooks.json"
		echo "wrote $target/.muse/hooks.json (Muse runs project hooks after you trust the folder)"
	fi
}

install_hooks_repo() {
	local target="$1"
	mkdir -p "$target/.claude/hooks/lib" "$target/scripts"
	link_files "$KIT_DIR/hooks/*.sh" "$target/.claude/hooks"
	link_files "$KIT_DIR/hooks/lib/*" "$target/.claude/hooks/lib"
	link_files "$KIT_DIR/hooks/codex/*.sh" "$target/.codex/hooks"
	install_muse_hooks "$target"
	prune_dir "$target/.claude/hooks" "$KIT_DIR/hooks/*.sh"
	prune_dir "$target/.claude/hooks/lib" "$KIT_DIR/hooks/lib/*"
	prune_dir "$target/.codex/hooks" "$KIT_DIR/hooks/codex/*.sh"
	prune_dir "$target/.muse/hooks" "$KIT_DIR/hooks/muse/*.sh"
	prune_dir "$target/.muse/hooks/lib" "$KIT_DIR/hooks/muse/lib/*"
	# A consuming repo may already track its own copy of the staleness
	# checker, and that copy can be newer than this kit's: the eshu repo
	# carries a GNU-stat fix this kit does not have. Overwriting a tracked
	# file with a symlink into the kit would silently regress it, so an
	# existing regular file is preserved and reported, the same way the
	# skill installer preserves an existing skill directory.
	if [ -e "$target/scripts/check-docs-stale.sh" ] && [ ! -L "$target/scripts/check-docs-stale.sh" ]; then
		echo "preserving existing script: $target/scripts/check-docs-stale.sh" >&2
	else
		ln -sfn "$KIT_DIR/scripts/check-docs-stale.sh" "$target/scripts/check-docs-stale.sh"
	fi
	echo "installed kit hook scripts into $target/.claude/hooks (+ Codex and Muse adapters)"
	echo "wire the Claude/Codex hooks in settings.json (see hooks/README.md); Muse reads .muse/hooks.json"
}

install_hooks_mode() {
	local scope="${1:-}"
	shift || true
	case "$scope" in
	--repo)
		[ -n "${1:-}" ] || {
			echo "usage: ./install.sh --hooks --repo /path/to/repo" >&2
			return 1
		}
		install_hooks_repo "$1"
		stamp_version_pin "$1"
		;;
	--global)
		# Machine-wide hooks execute outside the harness sandbox in every
		# workspace, so this is an explicit per-harness opt-in, never a
		# default or part of plain --global.
		case "${1:-}/${2:-}" in
		muse/) install_hooks_global_muse ;;
		claude/) install_hooks_global_claude ;;
		*)
			echo "usage: ./install.sh --hooks --global (muse|claude)" >&2
			return 1
			;;
		esac
		;;
	*)
		echo "usage: ./install.sh --hooks --repo /path/to/repo | ./install.sh --hooks --global (muse|claude)" >&2
		return 1
		;;
	esac
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
	prune_dir "$target/.claude/rules" "$KIT_DIR/rules/*.md" '!README.md'
	echo "installed kit rules into $target/.claude/rules (+ scripts/claude-rules-lint.sh)"
	echo "run scripts/claude-rules-lint.sh in the repo after moving rules or their targets"
}
