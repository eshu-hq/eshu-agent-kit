#!/usr/bin/env bash
# install-aliases.sh — sourced by install.sh (not run on its own).
# Repo-mode skill alias wrappers: manifest parsing, wrapper
# materialization, and manifest-filtered skill linking. Requires
# KIT_DIR from the caller.

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
