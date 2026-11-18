# Install-mode selection: --help, composable part flags, and the --pick
# multi-select. Sourced by install.sh; extracted to keep the entrypoint
# under the 500-line cap.
# shellcheck shell=bash

# Canonical part orders. install_parts and the picker both iterate these
# so the run order never depends on flag order.
DEFAULT_REPO_PART_ORDER="skills agents hooks rules"
DEFAULT_GLOBAL_PART_ORDER="skills agents hooks"

print_install_help() {
	cat <<'HELP'
Usage: ./install.sh [PARTS...] [--repo DIR [--aliases FILE] | --global [HARNESS...]]
       ./install.sh --pick [--repo DIR | --global [HARNESS...]]
       ./install.sh --uninstall ... (see --uninstall usage)
       ./install.sh (-h|--help)

Parts (pick any; repeatable; order does not matter):
  --skills    shared skill library
  --agents    subagent role definitions and their models
  --hooks     lifecycle hook scripts (repo: registration file written;
              global: explicit opt-in, runs outside any sandbox)
  --rules     path-scoped review rules (repo checkouts only)

Scopes:
  --repo DIR           install into one repo checkout (stamps the kit pin)
  --global [HARNESS]   install machine-wide; one or more of
                       claude codex opencode muse cursor, or all (default)

With no PARTS the installer keeps its historical defaults: bare --repo
installs skills, bare --global installs skills and agents. --rules only
works with --repo. --hooks --global needs exactly one harness
(muse|claude|opencode). --uninstall stays exclusive and cannot be combined.

Flags:
  --force      uninstall only: also remove kit alias wrappers
  --no-prune   keep stale kit-owned artifacts instead of removing them
               (may appear anywhere; uninstall ignores it)

Examples:
  ./install.sh --agents --hooks --repo ~/myrepo      one call, two parts
  ./install.sh --agents --hooks --global muse        agents and hooks, one call
  ./install.sh --pick --repo ~/myrepo                choose parts interactively
  printf '1 3\n' | ./install.sh --pick --repo ~/myrepo
                                                     script the choice:
                                                     1=skills 2=agents
                                                     3=hooks 4=rules

--pick asks which parts to install. With no terminal on stdin it keeps
the displayed defaults (every repo part; skills and agents globally --
global hooks are never a default) and prints the equivalent explicit
command so the run stays reproducible. Without a scope it needs a
terminal; otherwise it prints the explicit command to run instead.
HELP
}

# install_parts <"p1 p2..."> -- <scope args...> -- run one install per
# selected part in canonical order. Part names are bare
# (skills|agents|hooks|rules).
install_parts() {
	local parts="$1"
	[ $# -ge 2 ] && [ "$2" = "--" ] || {
		echo "usage: ./install.sh [PARTS...] --repo DIR | ./install.sh [PARTS...] --global [HARNESS...]" >&2
		return 1
	}
	shift 2
	case "${1:-}" in
	--repo) install_parts_repo "$parts" "${@:2}" ;;
	--global) install_parts_global "$parts" "${@:2}" ;;
	*)
		echo "usage: ./install.sh [PARTS...] --repo DIR [--aliases FILE] | ./install.sh [PARTS...] --global [HARNESS...]" >&2
		echo "run ./install.sh --help for the full reference" >&2
		return 1
		;;
	esac
}

# install_parts_repo <parts> <target> [--aliases FILE]
install_parts_repo() {
	local parts="$1" target="${2:-}" manifest=""
	[ -n "$target" ] || {
		echo "usage: ./install.sh [PARTS...] --repo DIR [--aliases FILE]" >&2
		return 1
	}
	if [ "${3:-}" = "--aliases" ]; then
		[ -n "${4:-}" ] && [ $# -eq 4 ] || {
			echo "usage: ./install.sh --repo DIR --aliases FILE" >&2
			return 1
		}
		manifest="$4"
	elif [ $# -gt 2 ]; then
		echo "usage: ./install.sh [PARTS...] --repo DIR [--aliases FILE]" >&2
		return 1
	fi
	if [ -n "$manifest" ]; then
		case " $parts " in
		*" skills "*) : ;;
		*)
			echo "error: --aliases only applies to the skills part" >&2
			return 1
			;;
		esac
	fi
	local part
	# shellcheck disable=SC2086 # order constants are kit-built word lists
	for part in $DEFAULT_REPO_PART_ORDER; do
		case " $parts " in
		*" $part "*) install_repo_part "$part" "$target" "$manifest" ;;
		esac
	done
	stamp_version_pin "$target"
}

# install_repo_part <part> <target> <manifest>
install_repo_part() {
	local part="$1" target="$2" manifest="$3"
	case "$part" in
	skills)
		mkdir -p "$target/.agents/skills"
		if [ -n "$manifest" ]; then
			local rows
			rows="$(parse_alias_manifest "$manifest")" || return 1
			[ -n "$rows" ] || {
				echo "alias manifest is empty: $manifest" >&2
				return 1
			}
			link_skills_except "$target/.agents/skills" "$rows"
			install_aliases_repo "$target" "$manifest" || return 1
		else
			link_dir "$KIT_DIR/skills/core" "$target/.agents/skills"
			link_dir "$KIT_DIR/skills/eshu" "$target/.agents/skills"
		fi
		prune_dir "$target/.agents/skills" "$KIT_DIR/skills/core/*" "$KIT_DIR/skills/eshu/*"
		echo "installed kit skills into $target/.agents/skills"
		;;
	agents)
		install_agents_repo "$target"
		;;
	hooks)
		install_hooks_mode --repo "$target"
		;;
	rules)
		install_rules_repo "$target"
		;;
	esac
}

# install_parts_global <parts> [harness...]
install_parts_global() {
	local parts="$1"
	shift
	case " $parts " in
	*" rules "*)
		echo "error: --rules only works with --repo" >&2
		return 1
		;;
	esac
	resolve_harnesses "$@" || return 1
	local part
	# shellcheck disable=SC2086 # order constants are kit-built word lists
	for part in $DEFAULT_GLOBAL_PART_ORDER; do
		case " $parts " in
		*" $part "*) install_global_part "$part" ;;
		esac
	done
}

# install_global_part <part> -- one part for the resolved harnesses.
install_global_part() {
	case "$1" in
	skills)
		install_skills_global
		echo "installed kit skills globally from $KIT_DIR for: ${selected[*]}"
		;;
	agents)
		install_agents_global
		;;
	hooks)
		[ "${#selected[@]}" -eq 1 ] || {
			echo "usage: ./install.sh --hooks --global (muse|claude|opencode)" >&2
			return 1
		}
		case "${selected[0]}" in
		muse) install_hooks_global_muse ;;
		claude) install_hooks_global_claude ;;
		opencode) install_hooks_global_opencode ;;
		*)
			echo "usage: ./install.sh --hooks --global (muse|claude|opencode)" >&2
			return 1
			;;
		esac
		;;
	esac
}

# install_pick [scope-args] -- interactive multi-select. Scope and target
# may be given (--repo DIR | --global [HARNESS...]); otherwise they are
# asked when stdin is a terminal. Piped answers work the same way.
install_pick() {
	local scope="" target="" harnesses=() a
	for a in "$@"; do
		case "$a" in
		--agents | --hooks | --rules | --skills)
			echo "error: --pick takes no part flags; answer the parts question instead" >&2
			return 1
			;;
		--repo | --global)
			[ -z "$scope" ] || {
				echo "usage: ./install.sh --pick [--repo DIR | --global [HARNESS...]]" >&2
				return 1
			}
			scope="$a"
			;;
		*)
			if [ "$scope" = "--repo" ] && [ -z "$target" ]; then
				target="$a"
			elif [ "$scope" = "--global" ]; then
				harnesses+=("$a")
			else
				echo "usage: ./install.sh --pick [--repo DIR | --global [HARNESS...]]" >&2
				return 1
			fi
			;;
		esac
	done
	if [ -z "$scope" ]; then
		if [ ! -t 0 ]; then
			echo "error: --pick needs a scope without a terminal; run one of:" >&2
			echo "  ./install.sh --pick --repo DIR" >&2
			echo "  ./install.sh --pick --global [HARNESS...]" >&2
			return 1
		fi
		printf 'Install into a repo checkout or machine-wide? [repo/global]: ' >&2
		IFS= read -r scope || scope=""
		case "$scope" in
		global) scope="--global" ;;
		*) scope="--repo" ;;
		esac
	fi
	if [ "$scope" = "--repo" ] && [ -z "$target" ]; then
		if [ ! -t 0 ]; then
			echo "error: --pick --repo needs DIR without a terminal; run:" >&2
			echo "  ./install.sh --pick --repo DIR" >&2
			return 1
		fi
		printf 'Repo checkout path: ' >&2
		IFS= read -r target || target=""
		[ -n "$target" ] || {
			echo "error: --pick --repo needs DIR" >&2
			return 1
		}
	fi
	local picked
	picked="$(pick_parts "$scope")" || return 1
	local cmd="./install.sh" word
	# shellcheck disable=SC2086 # picked is a kit-validated word list
	for word in $picked; do cmd="$cmd --$word"; done
	if [ "$scope" = "--repo" ]; then
		cmd="$cmd --repo $target"
	else
		cmd="$cmd --global"
		for h in ${harnesses[@]+"${harnesses[@]}"}; do cmd="$cmd $h"; done
	fi
	printf 'running the equivalent of: %s\n' "$cmd" >&2
	if [ "$scope" = "--repo" ]; then
		install_parts "$picked" -- --repo "$target"
	else
		# shellcheck disable=SC2086 # harnesses is a kit-validated word list
		install_parts "$picked" -- --global ${harnesses[@]+"${harnesses[@]}"}
	fi
}

# pick_parts <scope> -- print the chosen bare part names. EOF keeps the
# displayed defaults; global hooks are never a default.
pick_parts() {
	local scope="$1" names ans token name picked=""
	if [ "$scope" = "--repo" ]; then
		names="skills agents hooks rules"
	else
		names="skills agents hooks"
	fi
	{
		echo "parts to install (space-separated numbers or names, 'all', empty keeps defaults):"
		local n=0
		# shellcheck disable=SC2086 # names is a kit-built word list
		for token in $names; do
			n=$((n + 1))
			echo "  $n) $token"
		done
		if [ "$scope" = "--repo" ]; then
			echo "  defaults: all four"
		else
			echo "  defaults: skills agents (global hooks are never a default)"
		fi
	} >&2
	printf 'pick: ' >&2
	IFS= read -r ans || ans=""
	if [ -z "$ans" ]; then
		if [ "$scope" = "--repo" ]; then
			echo "skills agents hooks rules"
		else
			echo "skills agents"
		fi
		return 0
	fi
	# shellcheck disable=SC2086 # splitting the answer on purpose
	for token in $ans; do
		case "$token" in
		all)
			if [ "$scope" = "--repo" ]; then
				echo "skills agents hooks rules"
			else
				echo "skills agents hooks"
			fi
			return 0
			;;
		1 | skills) name="skills" ;;
		2 | agents) name="agents" ;;
		3 | hooks) name="hooks" ;;
		4 | rules)
			if [ "$scope" != "--repo" ]; then
				echo "error: --rules only works with --repo" >&2
				return 1
			fi
			name="rules"
			;;
		*)
			echo "error: unknown pick '$token' (use 1-4, names, or all)" >&2
			return 1
			;;
		esac
		case " $picked " in
		*" $name "*) ;;
		*) picked="$picked $name" ;;
		esac
	done
	[ -n "${picked// /}" ] || {
		echo "error: pick at least one part" >&2
		return 1
	}
	printf '%s\n' "$picked"
}
