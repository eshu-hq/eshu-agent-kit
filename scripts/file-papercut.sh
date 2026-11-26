#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 eshu-hq
#
# file-papercut.sh - file, deduplicate, and snapshot papercut issues.
# Usage:
#   scripts/file-papercut.sh file --skill <name> [--title <summary>] \
#     --tried <text> --expected <text> --happened <text> --fix <text> \
#     [--repo <owner/repo>] [--dry-run] [--dedupe-file <json>] [--no-dedupe]
#   scripts/file-papercut.sh snapshot --out <file> [--repo <owner/repo>] [--limit <N>]
set -euo pipefail
export LC_ALL=C

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || {
	echo "file-papercut: python3 is required" >&2
	exit 1
}

exec python3 -B - "${KIT_DIR}" "$@" <<'PYEOF'
import argparse, json, os, re, subprocess, sys, tempfile

KIT_DIR, ARGV = sys.argv[1], sys.argv[2:]
DEFAULT_REPO = "eshu-hq/eshu-agent-kit"
STOPWORDS = frozenset({
    "the", "and", "for", "with", "from", "that", "this", "into", "when", "not",
    "are", "was", "has", "have", "but", "use", "using", "does", "did", "can",
    "all", "one", "per", "out", "its", "via", "you", "your", "our", "instead",
})
GENERIC_WORDS = frozenset({
    "error", "fail", "fails", "failed", "issue", "bug", "missing", "broken",
    "wrong", "skill", "papercut",
})
SKILL_RE = re.compile(r"^\s*skill\s*:\s*[`'\"]?([A-Za-z0-9_.:-]+)", re.IGNORECASE | re.MULTILINE)

sys.path.insert(0, os.path.join(KIT_DIR, "scripts", "lib"))
try:
    from debrief_common import ALIASES as _RAW_ALIASES, canon_skill as _debrief_canon
except ImportError:
    _RAW_ALIASES, _debrief_canon = {}, None
ALIASES = {k.lower(): v.lower() for k, v in _RAW_ALIASES.items()}


def die(code, msg):
    sys.stderr.write(f"file-papercut: {msg}\n")
    sys.exit(code)


def canon_skill(raw):
    s = str(raw or "").strip().lower().split(":")[-1].strip(".,;:!?`'\" \t")
    s = _debrief_canon(s).lower() if _debrief_canon else re.sub(r"[^a-z0-9._-]", "", s)[:40]
    s = ALIASES.get(s.rstrip(".,;:!?"), s.rstrip(".,;:!?"))
    if s.startswith("eshu-") and len(s) > 5:
        s = s[5:]
    return ALIASES.get(s, s)


def detect_repo():
    try:
        res = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=False)
    except OSError:
        return DEFAULT_REPO
    url = (res.stdout or "").strip() if res.returncode == 0 else ""
    for pat in (
        r"^git@github\.com:([^/]+/[^/]+?)(?:\.git)?$",
        r"^ssh://git@github\.com/([^/]+/[^/]+?)(?:\.git)?$",
        r"^https?://github\.com/([^/]+/[^/]+?)(?:\.git)?$",
    ):
        m = re.match(pat, url)
        if m:
            return m.group(1)
    return DEFAULT_REPO


def run_gh(args):
    try:
        res = subprocess.run(["gh", *args], capture_output=True, text=True, check=False)
    except FileNotFoundError:
        die(1, "gh CLI not found; rerun with --dry-run --no-dedupe to print the formatted report")
    if res.returncode != 0:
        die(1, f"gh {' '.join(args[:2])} failed (exit {res.returncode}): {(res.stderr or res.stdout or '').strip()}")
    return res.stdout


def format_title(skill, raw_title, happened):
    summary = re.sub(r"\s+", " ", str(raw_title or "")).strip()
    if not summary:
        lines = str(happened or "").strip().splitlines()
        summary = re.sub(r"\s+", " ", lines[0]).strip()[:72] if lines else ""
    summary = re.sub(r"^\[papercut\]\s*", "", summary, flags=re.IGNORECASE).strip()
    if summary.lower().startswith(f"{skill}:"):
        summary = summary[len(skill) + 1:].strip()
    return f"[papercut] {skill}: {summary}" if summary else f"[papercut] {skill}"


def format_body(skill, tried, expected, happened, fix):
    return (
        f"skill: {skill}\n\n"
        f"### What the agent tried\n\n{tried.strip()}\n\n"
        f"### What was expected\n\n{expected.strip()}\n\n"
        f"### What happened instead\n\n{happened.strip()}\n\n"
        f"### What would fix it\n\n{fix.strip()}\n"
    )


def norm_title(title, skill):
    t = re.sub(r"^\[papercut\]\s*", "", str(title or "").strip(), flags=re.IGNORECASE)
    if skill:
        t = re.sub(rf"^{re.escape(skill)}\s*:\s*", "", t, flags=re.IGNORECASE)
    return re.sub(r"[^a-z0-9]+", " ", t.lower()).strip()


def find_duplicate(issues, skill, new_title):
    if isinstance(issues, dict):
        issues = next((issues[k] for k in ("issues", "papercuts") if isinstance(issues.get(k), list)), None)
    if not isinstance(issues, list):
        die(1, "dedupe JSON must be a list of issues")
    want_norm = norm_title(new_title, skill)
    want_tok = {w for w in want_norm.split() if len(w) >= 3 and w not in STOPWORDS}
    matches = []
    for rec in issues:
        if not isinstance(rec, dict) or str(rec.get("state") or "OPEN").upper() != "OPEN":
            continue
        m = SKILL_RE.search(str(rec.get("body") or ""))
        if not m or canon_skill(m.group(1)) != skill:
            continue
        cand_title = str(rec.get("title") or "")
        cand_norm = norm_title(cand_title, skill)
        cand_tok = {w for w in cand_norm.split() if len(w) >= 3 and w not in STOPWORDS}
        inter = want_tok & cand_tok
        exact = bool(want_norm and cand_norm and want_norm == cand_norm)
        overlap = len(inter) >= 2 or (len(inter) == 1 and min(len(want_tok), len(cand_tok)) == 1 and not (inter <= GENERIC_WORDS))
        if (exact or overlap) and rec.get("number") is not None:
            matches.append((int(rec["number"]), cand_title))
    return sorted(matches, key=lambda item: item[0])[0] if matches else None


def cmd_file(ns):
    missing = [f"--{k}" for k in ("skill", "tried", "expected", "happened", "fix") if not str(getattr(ns, k, "") or "").strip()]
    if missing:
        die(2, f"missing required field(s): {' '.join(missing)}")
    skill = canon_skill(ns.skill)
    if not skill:
        die(2, f"--skill {ns.skill!r} produced empty canonical name")
    repo = (ns.repo or "").strip() or detect_repo()
    title = format_title(skill, ns.title, ns.happened)
    body = format_body(skill, ns.tried, ns.expected, ns.happened, ns.fix)

    dup = None
    if ns.dedupe_file:
        try:
            with open(ns.dedupe_file, encoding="utf-8") as fh:
                issues = json.load(fh)
        except (OSError, ValueError) as exc:
            die(1, f"cannot read --dedupe-file {ns.dedupe_file!r}: {exc}")
        dup = find_duplicate(issues, skill, title)
    elif not ns.no_dedupe and not ns.dry_run:
        raw = run_gh(["issue", "list", "--repo", repo, "--label", "papercut", "--state", "open", "--limit", "200", "--json", "number,title,body"])
        try:
            issues = json.loads(raw)
        except ValueError as exc:
            die(1, f"gh issue list returned invalid JSON: {exc}")
        dup = find_duplicate(issues, skill, title)

    if dup is not None:
        num, existing_title = dup
        if ns.dry_run:
            sys.stdout.write(f"duplicate: #{num} ({existing_title})\n")
            return
        sys.stdout.write(f"Duplicate open papercut found: #{num} ({existing_title}) — commenting instead of opening a duplicate.\n")
        out = run_gh(["issue", "comment", str(num), "--repo", repo, "--body", body])
        if out.strip():
            sys.stdout.write(out if out.endswith("\n") else out + "\n")
        return

    if ns.dry_run:
        sys.stdout.write(f"repo: {repo}\ntitle: {title}\nlabels: papercut\n\n{body}")
        return

    out = run_gh(["issue", "create", "--repo", repo, "--label", "papercut", "--title", title, "--body", body])
    if out.strip():
        sys.stdout.write(out if out.endswith("\n") else out + "\n")


def cmd_snapshot(ns):
    out_path = str(ns.out or "").strip()
    if not out_path:
        die(2, "snapshot requires --out <file>")
    if ns.limit <= 0:
        die(2, f"invalid --limit {ns.limit!r} (must be positive)")
    repo = (ns.repo or "").strip() or detect_repo()
    raw = run_gh(["issue", "list", "--repo", repo, "--label", "papercut", "--state", "all", "--limit", str(ns.limit), "--json", "number,title,body,state,stateReason"])
    try:
        data = json.loads(raw)
    except ValueError as exc:
        die(1, f"gh issue list returned invalid JSON: {exc}")
    if not isinstance(data, list):
        die(1, "gh issue list snapshot must be a JSON array")
    out_abs = os.path.abspath(out_path)
    out_dir = os.path.dirname(out_abs)
    os.makedirs(out_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=out_dir, prefix=".papercut-snapshot.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2)
            fh.write("\n")
        os.replace(tmp, out_abs)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    sys.stdout.write(f"snapshot: wrote {len(data)} issues to {out_path}\n")


def build_parser():
    p = argparse.ArgumentParser(prog="file-papercut.sh", description="File, dedupe, and snapshot papercut issues.")
    sub = p.add_subparsers(dest="cmd")
    pf = sub.add_parser("file", help="Format, deduplicate, and file a papercut issue.")
    for opt, hlp in (
        ("--skill", "Skill name (canonicalized for /debrief)."),
        ("--title", "Short summary."),
        ("--tried", "What the agent tried."),
        ("--expected", "What was expected."),
        ("--happened", "What happened instead."),
        ("--fix", "What would fix it."),
        ("--repo", "GitHub owner/repo (default: git origin or eshu-hq/eshu-agent-kit)."),
        ("--dedupe-file", "Offline JSON array of issues for duplicate check."),
    ):
        pf.add_argument(opt, default="", help=hlp)
    pf.add_argument("--dry-run", action="store_true", help="Print formatted issue or duplicate hit without filing.")
    pf.add_argument("--no-dedupe", action="store_true", help="Skip live duplicate lookup.")
    ps = sub.add_parser("snapshot", help="Export papercut issues atomically for /debrief.")
    ps.add_argument("--out", default="", help="Destination JSON file path (required).")
    ps.add_argument("--repo", default="", help="GitHub owner/repo (default: git origin or eshu-hq/eshu-agent-kit).")
    ps.add_argument("--limit", type=int, default=200, help="Maximum issues to fetch (default: 200).")
    return p


parser = build_parser()
ns = parser.parse_args(ARGV) if ARGV else None
if not ns or ns.cmd not in ("file", "snapshot"):
    parser.print_usage(sys.stderr)
    sys.exit(2)
{"file": cmd_file, "snapshot": cmd_snapshot}[ns.cmd](ns)
PYEOF
