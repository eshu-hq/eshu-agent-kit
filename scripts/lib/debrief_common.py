#!/usr/bin/env python3
"""Shared utilities, constants, and facet validation for the /debrief v2 pipeline."""
import datetime
import json
import math
import os
import re
import tempfile

META_SCHEMA_VERSION = 4
FIXTURE_SESSIONS = frozenset({"abcdefghijkl", "ses9"})
FIXTURE_SESSION_RE = re.compile(r"^t[0-9]{4,}$")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")

EXT_LANG = {
    ".go": "Go", ".md": "Markdown", ".mdx": "Markdown", ".sh": "Shell",
    ".bash": "Shell", ".zsh": "Shell", ".yml": "YAML", ".yaml": "YAML",
    ".py": "Python", ".ts": "TypeScript", ".tsx": "TypeScript",
    ".js": "JavaScript", ".jsx": "JavaScript", ".mjs": "JavaScript",
    ".json": "JSON", ".sql": "SQL", ".tf": "Terraform", ".tfvars": "Terraform",
    ".hcl": "Terraform", ".html": "HTML", ".htm": "HTML", ".css": "CSS",
    ".rs": "Rust", ".proto": "Protobuf", ".toml": "TOML", ".rb": "Ruby",
    ".java": "Java", ".c": "C", ".h": "C", ".cpp": "C++", ".cs": "C#",
}

VALID_OUTCOMES = frozenset({
    "fully_achieved", "mostly_achieved", "partially_achieved",
    "not_achieved", "unclear",
})
VALID_SESSION_TYPES = frozenset({
    "single_task", "multi_task", "iterative_refinement",
    "exploration", "delegated_subagent", "quick_question",
})
VALID_SATISFACTION = frozenset({
    "satisfied", "likely_satisfied", "unsure", "dissatisfied", "frustrated",
})
VALID_FRICTION = frozenset({
    "buggy_code", "wrong_approach", "hook_or_env_retry",
    "stale_status", "tool_failure", "misunderstood_request",
    "missing_path_probe", "excessive_changes", "context_loss",
    "user_rejected_action",
})
VALID_SUCCESS = frozenset({
    "good_debugging", "multi_file_changes", "correct_code_edits",
    "hostile_review", "red_first_tests", "good_explanations",
    "fast_accurate_search", "proactive_help", "clean_orchestration",
    "none",
})


def xdg_data_home():
    return os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")


def default_data_dir():
    override = (os.environ.get("DEBRIEF_DATA_DIR") or "").strip()
    if override:
        return os.path.expanduser(override)
    app = (os.environ.get("DEBRIEF_APP_NAME") or "eshu-agent-kit").strip() or "eshu-agent-kit"
    return os.path.join(xdg_data_home(), app)


def default_cache_dir():
    return os.path.join(default_data_dir(), "debrief-cache")


def default_reports_dir():
    return os.path.join(default_data_dir(), "debrief-reports")


def default_eval_history():
    return os.path.join(default_data_dir(), "replay-eval-history.jsonl")


def default_usage_log():
    return os.path.join(default_data_dir(), "skills-usage.jsonl")


def is_fixture_session(sid):
    s = str(sid or "").strip()
    return s in FIXTURE_SESSIONS or bool(FIXTURE_SESSION_RE.match(s))


def load_aliases(path=None):
    target = (path or os.environ.get("DEBRIEF_ALIASES_FILE") or "").strip()
    if not target:
        target = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "..", "..", "templates", "repo-overlay", "eshu-aliases.tsv")
    try:
        with open(target, encoding="utf-8") as fh:
            out = {}
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#"):
                    continue
                parts = s.split("\t")
                if len(parts) >= 2 and parts[0].strip() and parts[1].strip():
                    out[parts[0].strip()] = parts[1].strip()
            return out
    except OSError:
        return {}


ALIASES = load_aliases()


def configure_aliases(path):
    """Reload global ALIASES from an explicit TSV path (for standalone / repo-agnostic use)."""
    global ALIASES
    if path:
        ALIASES = load_aliases(path)
    return ALIASES


def canon_skill(name):
    bare = str(name or "").strip().split(":")[-1]
    bare = re.sub(r"[^A-Za-z0-9._-]", "", bare)[:40]
    return ALIASES.get(bare, bare)


def safe_int(val, default=0):
    if isinstance(val, bool) or val is None:
        return default
    try:
        return int(val)
    except (TypeError, ValueError):
        return default


def safe_float(val, default=0.0):
    if isinstance(val, bool) or val is None:
        return default
    try:
        num = float(val)
    except (TypeError, ValueError):
        return default
    return num if math.isfinite(num) else default


def resolve_since(since_str="", days=30):
    """Return (since_date_yyyy_mm_dd, since_epoch_float)."""
    s = (since_str or "").strip()
    if s:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            raise SystemExit(f"debrief: invalid --since date (expected YYYY-MM-DD): {s!r}")
        try:
            dt = datetime.datetime.fromisoformat(s + "T00:00:00+00:00")
        except ValueError as exc:
            raise SystemExit(f"debrief: invalid --since calendar date {s!r}: {exc}") from exc
        return s, dt.timestamp()
    d = max(1, safe_int(days, 30))
    dt = (datetime.datetime.now(datetime.timezone.utc)
          - datetime.timedelta(days=d)).replace(hour=0, minute=0, second=0, microsecond=0)
    return dt.date().isoformat(), dt.timestamp()


def ts_to_epoch(val):
    if isinstance(val, bool):
        return None
    if isinstance(val, (int, float)) and val > 0:
        if val > 1e17:
            return val / 1_000_000_000.0
        if val > 1e14:
            return val / 1_000_000.0
        if val > 1e11:
            return val / 1_000.0
        return float(val)
    if isinstance(val, str) and val:
        try:
            dt = datetime.datetime.fromisoformat(val.replace("Z", "+00:00"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return dt.timestamp()
        except ValueError:
            return None
    return None


def epoch_to_iso(ep):
    if ep is None:
        return None
    try:
        return datetime.datetime.fromtimestamp(ep, tz=datetime.timezone.utc).isoformat()
    except (OSError, OverflowError, ValueError):
        return None


def epoch_to_utc_hour(ep):
    if ep is None:
        return None
    try:
        return datetime.datetime.fromtimestamp(ep, tz=datetime.timezone.utc).hour
    except (OSError, OverflowError, ValueError):
        return None


def gap_bucket(sec):
    if sec < 10:
        return "2-10s"
    if sec < 30:
        return "10-30s"
    if sec < 60:
        return "30s-1m"
    if sec < 120:
        return "1-2m"
    if sec < 300:
        return "2-5m"
    if sec < 900:
        return "5-15m"
    return ">15m"


def lang_from_path(path):
    if not isinstance(path, str) or not path.strip():
        return ""
    base = os.path.basename(path.strip().rstrip("/"))
    if base in ("Dockerfile", "Containerfile") or base.startswith("Dockerfile."):
        return "Dockerfile"
    if base == "Makefile" or base.endswith(".mk"):
        return "Makefile"
    _, ext = os.path.splitext(base.lower())
    return EXT_LANG.get(ext, "")


def categorize_error(tool_name, text=""):
    t = str(tool_name or "").lower()
    s = str(text or "").lower()
    if any(k in s for k in ("skill-nudge", "load skill", "blocked by hook", "hook blocked", "pretooluse")):
        return "Hook Blocked"
    if any(k in s for k in ("rejected by user", "user rejected", "denied by user")):
        return "User Rejected"
    if any(k in s for k in ("no such file", "does not exist", "file not found", "enoent")):
        return "File Not Found"
    if any(k in s for k in ("timeout", "timed out", "deadline exceeded")):
        return "Timeout"
    if any(k in s for k in ("permission denied", "read-only", "sandbox", "outside workspace")):
        return "Permission/Sandbox"
    if "mcp" in t or "jira" in t or "github" in t or "http 5" in s or "rate limit" in s:
        return "MCP/API Error"
    if t in ("edit", "edit_file", "write", "write_file") or "not found in file" in s or "multiple occurrences" in s:
        return "Edit Failed"
    if t in ("bash", "run_command", "shell") or "exit status" in s or "exited with code" in s:
        return "Command Failed"
    return "Other"


def truncate_text(val, limit=240):
    s = re.sub(r"\s+", " ", str(val or "")).strip()
    if len(s) <= limit:
        return s
    return s[: limit - 1] + "…"


def load_json_lines(path):
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                yield rec


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def atomic_write_json(path, obj):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def safe_key(harness, session_id):
    h = re.sub(r"[^a-z0-9_-]", "", str(harness or "unknown").lower())[:20] or "unknown"
    s = re.sub(r"[^A-Za-z0-9._-]", "_", str(session_id or ""))[:80]
    return f"{h}__{s}"


def normalize_friction_key(raw):
    k = re.sub(r"[^a-z0-9_]+", "_", str(raw or "").strip().lower()).strip("_")
    mapping = {
        "environment_issue": "hook_or_env_retry",
        "environment_issues": "hook_or_env_retry",
        "tool_environment_issue": "hook_or_env_retry",
        "tool_or_env_error": "hook_or_env_retry",
        "hook_block": "hook_or_env_retry",
        "hook_or_gate_block": "hook_or_env_retry",
        "file_not_found": "missing_path_probe",
        "stale_pr_status": "stale_status",
        "stale_context_or_branch": "stale_status",
        "passive_waiting": "stale_status",
    }
    k = mapping.get(k, k)
    return k if k in VALID_FRICTION else "tool_failure"


VALID_HARNESSES = ("muse", "agy", "claude", "codex", "opencode")


def validate_facet(raw):
    """Validate and normalize one Stage 2 facet dict; returns (facet, err)."""
    if not isinstance(raw, dict):
        return None, "facet must be a JSON object"
    sid = str(raw.get("session_id") or "").strip()
    harness = str(raw.get("harness") or "").strip().lower()
    if not sid or harness not in VALID_HARNESSES:
        return None, f"missing/invalid session_id ({sid!r}) or harness ({harness!r})"
    outcome = str(raw.get("outcome") or "unclear").strip().lower()
    if outcome not in VALID_OUTCOMES:
        outcome = "unclear"
    stype = str(raw.get("session_type") or "single_task").strip().lower()
    if stype not in VALID_SESSION_TYPES:
        stype = "single_task"
    sat_raw = str(raw.get("satisfaction") or "likely_satisfied").strip().lower()
    sat_alias = {"happy": "satisfied", "very_satisfied": "satisfied"}
    sat = sat_alias.get(sat_raw, sat_raw)
    if sat not in VALID_SATISFACTION:
        sat = "unsure"
    ps = str(raw.get("primary_success") or "none").strip().lower()
    if ps not in VALID_SUCCESS:
        ps = "none"
    gmap = {}
    raw_gc = raw.get("goal_categories")
    if isinstance(raw_gc, dict):
        for k, v in raw_gc.items():
            ck = re.sub(r"[^a-z0-9_]+", "_", str(k).strip().lower()).strip("_")[:48]
            if ck:
                n = safe_int(v, 1)
                if n > 0:
                    gmap[ck] = gmap.get(ck, 0) + n
    elif isinstance(raw_gc, list):
        for item in raw_gc[:6]:
            ck = re.sub(r"[^a-z0-9_]+", "_", str(item).strip().lower()).strip("_")[:48]
            if ck:
                gmap[ck] = gmap.get(ck, 0) + 1
    fmap = {}
    raw_fc = raw.get("friction_counts")
    if isinstance(raw_fc, dict):
        for k, v in raw_fc.items():
            fk = normalize_friction_key(k)
            n = safe_int(v, 1)
            if n > 0:
                fmap[fk] = fmap.get(fk, 0) + n
    return {
        "session_id": sid,
        "harness": harness,
        "source_mtime": safe_float(raw.get("source_mtime"), 0.0),
        "underlying_goal": truncate_text(raw.get("underlying_goal") or "", 240),
        "goal_categories": gmap,
        "outcome": outcome,
        "session_type": stype,
        "friction_counts": fmap,
        "friction_detail": truncate_text(raw.get("friction_detail") or "", 400),
        "primary_success": ps,
        "satisfaction": sat,
        "brief_summary": truncate_text(raw.get("brief_summary") or "", 400),
        "imported_from": str(raw.get("imported_from") or ""),
    }, None


_AFFIRM = r"(?:yes|yep|yeah|yup|ok|okay|sure|lgtm|looks good|sounds good|go ahead|proceed|do it|ship it|merge|approved|great|thanks|thank you|perfect|nice|cool|awesome|good|fine|continue|please)"
_APPROVAL_RE = re.compile(rf"^{_AFFIRM}(?:[\s,!.-]+{_AFFIRM})*[\s!.,]*$", re.IGNORECASE)
_REDIRECT_RE = re.compile(
    r"\b(stop|wait|hold on|don'?t|do not|you forgot|forgot to|you missed|missed the|remember to|follow the|refollow|re-?read|stick to|back to|finish|keep going|not done|still haven'?t|still need|didn'?t finish|make sure you|focus on|wrong file|wrong branch|don'?t skip|never skip)\b",
    re.IGNORECASE,
)
_DEBUG_RE = re.compile(
    r"\b(error|errors|fail|failed|failing|failure|broken|bug|crash|traceback|exception|panic|exit code|doesn'?t work|didn'?t work|not working|still failing|stuck|hang|hanging|timeout|timed out|fix this|fix it|why is it failing|why did it fail|stack trace|503|500|404|403|segfault)\b",
    re.IGNORECASE,
)
_THOUGHT_RE = re.compile(
    r"(\?|\b(why |how does|how do|what does|what is|what if|should we|would it|could we|can we|compare|tradeoff|trade-off|explain|make sense|what do you think|opinion|thoughts|curious|wondering)\b)",
    re.IGNORECASE,
)
_SCOPE_RE = re.compile(
    r"\b(also|another thing|next[, ]|now add|let'?s add|can you add|one more|in addition|after that|plus |and also|also add|would be nice)\b",
    re.IGNORECASE,
)


def classify_interjection(text):
    """Classify a follow-up user prompt into an intent category (content-free)."""
    s = re.sub(r"\s+", " ", str(text or "")).strip()
    if not s:
        return "clarification"
    if len(s) <= 60 and "?" not in s and _APPROVAL_RE.match(s):
        return "approval"
    if _REDIRECT_RE.search(s):
        return "redirect_goal"
    if _DEBUG_RE.search(s):
        return "debugging"
    if _THOUGHT_RE.search(s):
        return "thought_process"
    if _SCOPE_RE.search(s):
        return "new_scope"
    return "clarification"
