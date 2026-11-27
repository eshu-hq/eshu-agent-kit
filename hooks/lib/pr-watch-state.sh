#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# hooks/lib/pr-watch-state.sh - Shared session PR-watch tracking helpers.
# Sourced by hooks/pr-watch-nudge.sh and hooks/pr-watch-guard.sh.
# Fail-open contract: never exit non-zero or corrupt a session on I/O errors.

prw_sid12() {
	printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-12
}

prw_state_file() { # <session_id>
	local sid12
	sid12="$(prw_sid12 "$1")"
	[ -n "${sid12}" ] || return 1
	printf '%s/kit-pr-watch-%s.tsv\n' "${TMPDIR:-/tmp}" "${sid12}"
}

# Resolve the real path to scripts/watch-pr.sh through any hook symlinks so both
# repo installs and global pseudo-root installs emit an executable path.
prw_watch_script() {
	python3 - "${BASH_SOURCE[0]}" <<'PY' 2>/dev/null || printf 'scripts/watch-pr.sh\n'
import os, sys
here = os.path.realpath(sys.argv[1])
kit = os.path.dirname(os.path.dirname(os.path.dirname(here)))
cand = os.path.join(kit, "scripts", "watch-pr.sh")
print(cand if os.path.isfile(cand) else "scripts/watch-pr.sh")
PY
}

# Record <repo> <pr> as opened (armed=0 unless already armed=1).
prw_record_open() { # <session_id> <repo> <pr>
	local sf
	sf="$(prw_state_file "$1")" || return 0
	PRW_FILE="${sf}" PRW_REPO="$2" PRW_PR="$3" python3 - <<'PY' 2>/dev/null || true
import os, tempfile, time
sf, repo, pr = os.environ["PRW_FILE"], os.environ["PRW_REPO"], os.environ["PRW_PR"]
rows = {}
order = []
if os.path.isfile(sf):
    for line in open(sf, encoding="utf-8", errors="replace"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            k = (parts[0], parts[1])
            if k not in rows:
                order.append(k)
            rows[k] = parts[2]
key = (repo, pr)
if key not in rows:
    order.append(key)
    rows[key] = "0"
d = os.path.dirname(sf) or "/tmp"
fd, tmp = tempfile.mkstemp(dir=d, prefix=".prw-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for k in order:
            fh.write(f"{k[0]}\t{k[1]}\t{rows[k]}\t{int(time.time())}\n")
    os.replace(tmp, sf)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
PY
}

# Mark PR(s) named in a watcher command as armed=1 (or all open session PRs when
# the command uses a shell variable instead of literal PR numbers).
prw_mark_armed() { # <session_id> <command>
	local sf
	sf="$(prw_state_file "$1")" || return 0
	[ -f "${sf}" ] || return 0
	PRW_FILE="${sf}" PRW_CMD="$2" python3 - <<'PY' 2>/dev/null || true
import os, re, tempfile, time
sf, cmd = os.environ["PRW_FILE"], os.environ["PRW_CMD"]
nums = set(re.findall(r"(?:^|[\s,=])([0-9]{1,7})(?=$|[\s,;|&])", cmd))
rows = []
for line in open(sf, encoding="utf-8", errors="replace"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3:
        repo, pr, armed = parts[0], parts[1], parts[2]
        if not nums or pr in nums:
            armed = "1"
        rows.append((repo, pr, armed))
d = os.path.dirname(sf) or "/tmp"
fd, tmp = tempfile.mkstemp(dir=d, prefix=".prw-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        for repo, pr, armed in rows:
            fh.write(f"{repo}\t{pr}\t{armed}\t{int(time.time())}\n")
    os.replace(tmp, sf)
except OSError:
    try:
        os.unlink(tmp)
    except OSError:
        pass
PY
}

# Print "repo\tpr" lines for PRs opened in this session with armed=0.
prw_list_unwatched() { # <session_id>
	local sf
	sf="$(prw_state_file "$1")" || return 0
	[ -f "${sf}" ] || return 0
	awk -F'\t' '$3 == "0" { print $1 "\t" $2 }' "${sf}" 2>/dev/null || true
}

# Classify a command: prints "valid", "oneshot", or "other".
prw_classify_cmd() { # <command>
	PRW_CMD="$1" python3 - <<'PY' 2>/dev/null || printf 'other\n'
import os, re
cmd = os.environ.get("PRW_CMD", "")
if re.search(r"(?:^|[\s/\"'])watch-pr\.sh\b", cmd) or re.search(r"(?:^|[\s/\"'])pr-watch\b", cmd):
    print("valid")
    raise SystemExit(0)
has_gh_pr = bool(re.search(r"\bgh\s+pr\s+(view|checks|status)\b", cmd))
has_loop = bool(re.search(r"\b(while|until)\b", cmd))
if has_gh_pr and has_loop:
    print("valid")
elif has_gh_pr:
    print("oneshot")
else:
    print("other")
PY
}

# Build harness-specific watcher guidance for one or more "repo\tpr" lines.
prw_guidance() { # <harness> <watch_script> <repo> <pr>
	local harness="$1" ws="$2" repo="$3" pr="$4"
	case "${harness}" in
	muse)
		printf 'PR %s#%s is open without a live PR watcher. Arm one IN THIS SAME TURN using Muse `monitor` with `persistent: true` running:\n  bash %s --repo %s %s\n(In the Eshu repo you may run `/tmp/pr-watch -dir <worktree> %s` instead.) Do NOT pass a one-shot `gh pr view` command to `monitor` (it exits after 1 second and leaves you blind), and do NOT snooze via `report_progress(snooze_minutes=...)` without a live PR monitor covering this PR.' \
			"${repo}" "${pr}" "${ws}" "${repo}" "${pr}" "${pr}"
		;;
	claude)
		printf 'PR %s#%s is open without a live PR watcher. Arm one IN THIS SAME TURN in the background (`run_in_background: true` / Monitor):\n  bash %s --repo %s %s\n(Add `--exit-on-event` if running a non-streaming background shell.)' \
			"${repo}" "${pr}" "${ws}" "${repo}" "${pr}"
		;;
	*)
		printf 'PR %s#%s is open without a live PR watcher. Arm a background PR watcher IN THIS SAME TURN:\n  bash %s --repo %s --exit-on-event %s\nIt wakes you on merge, conflict, CI failure, review/thread, or 2-read green.' \
			"${repo}" "${pr}" "${ws}" "${repo}" "${pr}"
		;;
	esac
}
