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
