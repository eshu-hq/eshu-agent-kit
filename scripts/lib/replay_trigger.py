#!/usr/bin/env python3
"""Trigger precision/recall evals (issue #117): does a skill's description fire?

Loads Tier-1 metadata only (frontmatter `name` + `description`, never the
body) from repeatable --skills-dir roots, then asks a decider which skills a
prompt should load. Deciders share one payload, {"prompt", "skills": [{"name",
"description"}]}: an offline lexical rubric, a --decider-cmd, or a router
prompt run through claude, agy, or muse in an empty temp directory. Only
labelled cases are scored; errored trials are excluded, never counted as "did
not trigger". Schema and math: docs/guides/trigger-evals.md.
"""
import datetime
import getopt
import hashlib
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import canon_skill, configure_aliases  # noqa: E402
from replay_eval import STOPWORDS  # noqa: E402
from replay_runner import (  # noqa: E402
    build_harness_cmd, isolated_workspace, parse_harness_output,
)

KIT_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LIVE_HARNESSES = ("claude", "agy", "muse")
KINDS = ("positive", "negative", "competing")
DEFAULT_THRESHOLD = 0.25  # swept on evals/triggers.json; see docs/guides/trigger-evals.md
ROUTER_PROMPT = (
    "You are a skill router. The JSON below holds a user prompt and a catalog "
    "of skills (name and description only). Decide which skills an agent "
    "should load for that prompt. Reply with ONLY a JSON object of the form "
    '{"skills": ["name", ...]} using names from the catalog, or {"skills": []} '
    "when none apply. Do not use tools.\n\n"
)


def fail(msg, code=1):
    print("replay-trigger: %s" % msg, file=sys.stderr)
    sys.exit(code)


# --- Catalog: frontmatter name + description only -------------------------

def _unquote_dq(text):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t"}.get(m.group(1), m.group(1)), text)


def _scalar(first, more):
    """Decode one YAML scalar from its first line and any continuation lines."""
    first = first.strip()
    if first[:1] in (">", "|"):
        body = [ln.strip() for ln in more]
        text = ("\n" if first[0] == "|" else " ").join(ln for ln in body if ln)
        return text.strip()
    if first[:1] in ('"', "'"):
        text = " ".join([first] + [ln.strip() for ln in more]).strip()
        quote = text[0]
        end = len(text) - 1
        while end > 0 and text[end] != quote:
            end -= 1
        inner = text[1:end] if end > 0 else text[1:]
        return _unquote_dq(inner) if quote == '"' else inner.replace("''", "'")
    text = re.split(r"\s#", first, maxsplit=1)[0].strip()
    return " ".join([text] + [ln.strip() for ln in more]).strip()


def parse_frontmatter(path):
    """Return {"name", "description"} read from the YAML header only.

    Reading stops at the closing delimiter, so the skill body is never read.
    """
    fields, key, first, more = {}, None, "", []

    def flush():
        if key in ("name", "description"):
            fields[key] = _scalar(first, more)

    with open(path, encoding="utf-8") as fh:
        if fh.readline().strip() != "---":
            return {}
        for raw in fh:
            line = raw.rstrip("\r\n")
            if line.strip() == "---":
                break
            top = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
            if top:
                flush()
                key, first, more = top.group(1), top.group(2), []
            elif key is not None and (line.startswith((" ", "\t")) or not line.strip()):
                more.append(line)
        else:
            return {}
    flush()
    return fields


def _skill_files(root):
    for entry in sorted(os.listdir(root)):
        edir = os.path.join(root, entry)
        if not os.path.isdir(edir):
            continue
        direct = os.path.join(edir, "SKILL.md")
        if os.path.isfile(direct):
            yield entry, direct
            continue
        for sub in sorted(os.listdir(edir)):
            md = os.path.join(edir, sub, "SKILL.md")
            if os.path.isfile(md):
                yield sub, md


def load_catalog(dirs):
    """Map canonical skill name -> {"name", "description"}; later dirs win."""
    catalog = {}
    for root in dirs:
        root = os.path.expanduser(str(root))
        if not os.path.isdir(root):
            continue
        for dirname, md in _skill_files(root):
            try:
                meta = parse_frontmatter(md)
            except (OSError, UnicodeDecodeError):
                continue
            name = meta.get("name") or dirname
            key = canon_skill(name)
            if not key:
                continue
            if key in catalog:
                print("replay-trigger: warning: %r redefined by %s (later dir wins)" % (key, md), file=sys.stderr)
            catalog[key] = {"name": name, "description": meta.get("description", "")}
    return catalog


# --- Suite ------------------------------------------------------------------

def _names(case, field, cid):
    raw = case.get(field, [])
    if not isinstance(raw, list) or not all(isinstance(x, str) and x.strip() for x in raw):
        fail("case %r: %s must be a list of skill names" % (cid, field), 2)
    return [canon_skill(x) if x.strip() != "*" else "*" for x in raw]


def load_suite(path, catalog):
    """Validate a suite and return normalized cases; every problem exits 2."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as exc:
        fail("cannot read suite %s: %s" % (path, exc), 2)
    if not isinstance(doc, dict) or not isinstance(doc.get("cases"), list) or not doc["cases"] or doc.get("version", 1) != 1:
        fail('suite %s needs version 1 and a non-empty top-level "cases" list' % path, 2)
    seen, out = set(), []
    for idx, case in enumerate(doc["cases"]):
        if not isinstance(case, dict):
            fail("case #%d must be an object" % idx, 2)
        cid = case.get("id")
        if not isinstance(cid, str) or not cid.strip():
            fail("case #%d needs a string id" % idx, 2)
        if cid in seen:
            fail("duplicate case id %r" % cid, 2)
        seen.add(cid)
        prompt, kind = case.get("prompt"), case.get("kind")
        if not isinstance(prompt, str) or not prompt.strip():
            fail("case %r needs a non-empty prompt" % cid, 2)
        if kind not in KINDS:
            fail("case %r: kind must be one of %s" % (cid, "|".join(KINDS)), 2)
        expect, reject = _names(case, "expect", cid), _names(case, "reject", cid)
        if "*" in expect:
            fail('case %r: "*" is only valid in reject' % cid, 2)
        if (kind in ("positive", "competing") and not expect) or (kind in ("negative", "competing") and not reject):
            fail("case %r (%s): expect/reject is empty where the kind requires it" % (cid, kind), 2)
        if kind == "negative" and expect:
            fail("case %r: a negative case must have an empty expect" % cid, 2)
        for name in expect + [r for r in reject if r != "*"]:
            if name not in catalog:
                fail("case %r references skill %r that is not in the catalog" % (cid, name), 2)
        if set(expect) & set(reject):
            fail("case %r lists the same skill in expect and reject" % cid, 2)
        if "*" in reject:
            reject = sorted(set(catalog) - set(expect) | {r for r in reject if r != "*"})
        out.append({"id": cid, "kind": kind, "prompt": prompt, "expect": sorted(set(expect)), "reject": sorted(set(reject))})
    return out


# --- Deciders ---------------------------------------------------------------

def _tokens(text):
    return {t for t in re.findall(r"[a-z0-9]+", text.lower()) if len(t) >= 3 and t not in STOPWORDS}


def rubric_select(prompt, catalog, threshold):
    """Offline lexical rubric: share of prompt tokens found in name+description."""
    want = _tokens(prompt)
    if not want:
        return []
    return [
        key for key in sorted(catalog)
        if len(want & _tokens(catalog[key]["name"] + " " + catalog[key]["description"])) / len(want) >= threshold
    ]


def build_payload(prompt, catalog):
    skills = [{"name": catalog[k]["name"], "description": catalog[k]["description"]}
              for k in sorted(catalog, key=lambda k: catalog[k]["name"])]
    return {"prompt": prompt, "skills": skills}


def parse_reply(text):
    """Extract the skills list from a model reply; None when unparseable."""
    text = (text or "").strip()
    fence = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fence:
        text = fence.group(1).strip()
    dec, found, pos = json.JSONDecoder(), None, text.find("{")
    while pos != -1:
        try:
            obj, end = dec.raw_decode(text, pos)
        except ValueError:
            pos = text.find("{", pos + 1)
            continue
        if isinstance(obj, dict) and isinstance(obj.get("skills"), list):
            found = obj["skills"]
        pos = text.find("{", end)
    return None if found is None else [s for s in found if isinstance(s, str)]


def cmd_select(path, payload, timeout):
    try:
        proc = subprocess.run([path], input=json.dumps(payload), capture_output=True, text=True, timeout=timeout)
    except (subprocess.TimeoutExpired, OSError) as exc:
        return None, "decider-cmd failed: %s" % exc
    if proc.returncode != 0:
        return None, "decider-cmd exit %d: %s" % (proc.returncode, proc.stderr.strip()[-200:])
    sel = parse_reply(proc.stdout)
    return (sel, None) if sel is not None else (None, "decider-cmd reply has no skills list")


def live_select(harness, payload, model, timeout):
    router = ROUTER_PROMPT + json.dumps(payload, indent=1)
    try:
        with isolated_workspace(None) as iso:
            prompt_file = os.path.join(os.path.dirname(iso), ".router-prompt.txt")
            cmd, stdin_text, pf_text = build_harness_cmd(harness, "without-skill", "", "", router, iso, prompt_file, model)
            if pf_text is not None:
                with open(prompt_file, "w", encoding="utf-8") as fh:
                    fh.write(pf_text)
            t0 = time.monotonic()
            proc = subprocess.run(
                cmd, input=stdin_text, stdin=None if stdin_text is not None else subprocess.DEVNULL,
                cwd=iso, capture_output=True, text=True, timeout=timeout,
            )
            wall = time.monotonic() - t0
    except (subprocess.TimeoutExpired, OSError, RuntimeError) as exc:
        return None, "%s failed: %s" % (harness, exc)
    if proc.returncode != 0:
        return None, "%s exit %d: %s" % (harness, proc.returncode, (proc.stderr or proc.stdout).strip()[-200:])
    traj = parse_harness_output(harness, proc.stdout, wall)
    if traj.get("errors"):
        return None, "%s reported a run error" % harness
    sel = parse_reply(traj.get("transcript"))
    return (sel, None) if sel is not None else (None, "%s reply has no skills list" % harness)


# --- Scoring ----------------------------------------------------------------

def _ratio(num, den):
    return None if den == 0 else round(num / den, 4)


def _metrics(tp, fp, fn, tn):
    return {
        "precision": _ratio(tp, tp + fp), "recall": _ratio(tp, tp + fn), "f1": _ratio(2 * tp, 2 * tp + fp + fn),
        "trigger_rate": _ratio(tp + fp, tp + fp + fn + tn), "false_trigger_rate": _ratio(fp, fp + tn),
    }


def score(catalog, cases, trials):
    """Confusion counts per skill over labelled, non-errored trials."""
    stats = {k: {"tp": 0, "fp": 0, "fn": 0, "tn": 0, "unlabeled_triggers": 0} for k in catalog}
    by_id = {c["id"]: c for c in cases}
    fps, fns = [], []
    for tr in trials:
        if tr["error"] is not None:
            continue
        case, picked = by_id[tr["case"]], set(tr["selected"])
        for skill, st in stats.items():
            hit = skill in picked
            if skill in case["expect"]:
                st["tp" if hit else "fn"] += 1
                if not hit:
                    fns.append({"case_id": case["id"], "skill": skill, "repeat": tr["repeat"]})
            elif skill in case["reject"]:
                st["fp" if hit else "tn"] += 1
                if hit:
                    fps.append({"case_id": case["id"], "skill": skill, "repeat": tr["repeat"]})
            elif hit:
                st["unlabeled_triggers"] += 1
    per_skill = []
    for skill in sorted(stats):
        st = stats[skill]
        per_skill.append({
            "skill": skill, "description_sha": hashlib.sha256((catalog[skill]["name"] + "\n" + catalog[skill]["description"]).encode()).hexdigest()[:12],
            "positives": sum(1 for c in cases if skill in c["expect"]),
            "negatives": sum(1 for c in cases if skill in c["reject"]),
            **{k: st[k] for k in ("tp", "fp", "fn", "tn")}, **_metrics(st["tp"], st["fp"], st["fn"], st["tn"]),
            "unlabeled_triggers": st["unlabeled_triggers"],
        })
    tot = {k: sum(s[k] for s in per_skill) for k in ("tp", "fp", "fn", "tn")}
    f1s = [s["f1"] for s in per_skill if s["f1"] is not None]
    overall = {**tot, **{k: v for k, v in _metrics(**tot).items() if k in ("precision", "recall", "f1")},
               "macro_f1": round(sum(f1s) / len(f1s), 4) if f1s else None}
    return per_skill, overall, fps, fns


def run_trials(opts, catalog, cases):
    trials, unknown = [], []
    for case in cases:
        payload = build_payload(case["prompt"], catalog)
        for rep in range(1, opts["repeats"] + 1):
            if opts["decider"] == "rubric":
                sel, err = rubric_select(case["prompt"], catalog, opts["threshold"]), None
            elif opts["decider"] == "cmd":
                sel, err = cmd_select(opts["decider_cmd"], payload, opts["timeout"])
            else:
                sel, err = live_select(opts["decider"], payload, opts["model"], opts["timeout"])
            known = []
            for name in sel or []:
                key = canon_skill(name)
                if key in catalog:
                    if key not in known:
                        known.append(key)
                elif key:
                    unknown.append({"case_id": case["id"], "skill": key, "repeat": rep})
            if err:
                print("replay-trigger: case %s repeat %d: %s" % (case["id"], rep, err), file=sys.stderr)
            trials.append({"case": case["id"], "repeat": rep, "selected": known, "error": err})
    return trials, unknown


def parse_opts(argv):
    try:
        got, rest = getopt.getopt(argv, "", [
            "suite=", "skills-dir=", "harness=", "decider-cmd=", "model=", "repeats=", "threshold=",
            "timeout=", "allow-errors", "json-out=", "aliases=", "help"])
    except getopt.GetoptError as exc:
        fail(str(exc), 2)
    if rest:
        fail("unexpected argument: %s" % rest[0], 2)
    o = {"suite": "", "dirs": [], "harness": "", "decider_cmd": "", "model": "", "repeats": 1,
         "threshold": DEFAULT_THRESHOLD, "timeout": 300, "allow_errors": False, "json_out": "", "aliases": ""}
    for key, val in got:
        name = key[2:].replace("-", "_")
        if key == "--help":
            print(__doc__.strip(), file=sys.stderr)
            sys.exit(0)
        try:
            if key == "--skills-dir":
                o["dirs"].append(val)
            elif key == "--allow-errors":
                o[name] = True
            else:
                o[name] = type(o[name])(val)
        except ValueError:
            fail("%s: invalid value %r" % (key, val), 2)
    if not o["suite"]:
        fail("--suite FILE is required", 2)
    if o["harness"] not in ("", "rubric") + LIVE_HARNESSES:
        fail("--harness must be rubric|%s (got %r)" % ("|".join(LIVE_HARNESSES), o["harness"]), 2)
    if o["decider_cmd"] and o["harness"]:
        fail("--decider-cmd and --harness are mutually exclusive", 2)
    if o["decider_cmd"] and not os.access(o["decider_cmd"], os.X_OK):
        fail("--decider-cmd %r is not an executable file" % o["decider_cmd"], 2)
    if not 0.0 <= o["threshold"] <= 1.0:
        fail("--threshold must be between 0 and 1", 2)
    if o["repeats"] < 1 or o["timeout"] < 1:
        fail("--repeats and --timeout must be >= 1", 2)
    o["decider"] = "cmd" if o["decider_cmd"] else (o["harness"] or "rubric")
    return o


def main(argv):
    opts = parse_opts(argv)
    if opts["aliases"]:
        configure_aliases(opts["aliases"])
    catalog = load_catalog(opts["dirs"] or [os.path.join(KIT_DIR, "skills")])
    if not catalog:
        fail("no skills found under --skills-dir", 2)
    cases = load_suite(opts["suite"], catalog)
    trials, unknown = run_trials(opts, catalog, cases)
    per_skill, overall, fps, fns = score(catalog, cases, trials)
    errors = sum(1 for t in trials if t["error"] is not None)
    mode = {"rubric": "lexical-rubric", "cmd": "custom"}.get(opts["decider"], "router-prompt")
    doc = {
        "kind": "trigger-eval", "version": 1, "decider": opts["decider"], "mode": mode,
        "model": opts["model"], "threshold": opts["threshold"] if opts["decider"] == "rubric" else None,
        "repeats": opts["repeats"], "suite": opts["suite"],
        "recorded_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "cases": len(cases), "trials": len(trials), "errors": errors, "overall": overall,
        "per_skill": per_skill, "false_positives": fps, "false_negatives": fns, "unknown_selected": unknown,
    }
    failed = errors and not opts["allow_errors"]
    if opts["json_out"] and not failed:
        os.makedirs(os.path.dirname(os.path.abspath(opts["json_out"])), exist_ok=True)
        with open(opts["json_out"], "w", encoding="utf-8") as fh:
            json.dump(doc, fh, indent=1)
            fh.write("\n")
    fmt = lambda v: "-" if v is None else ("%.4f" % v if isinstance(v, float) else str(v))  # noqa: E731
    print("trigger-eval decider=%s mode=%s cases=%d trials=%d errors=%d" % (opts["decider"], mode, len(cases), len(trials), errors))
    print("overall " + " ".join("%s=%s" % (k, fmt(v)) for k, v in overall.items()))
    for row in (r for r in per_skill if r["positives"] or r["negatives"]):
        print("  %-34s P=%s R=%s F1=%s fp=%d fn=%d" % (row["skill"], fmt(row["precision"]), fmt(row["recall"]), fmt(row["f1"]), row["fp"], row["fn"]))
    if failed:
        fail("%d of %d trials errored; no --json-out written (re-run with --allow-errors to keep partial results)" % (errors, len(trials)), 1)


if __name__ == "__main__":
    main(sys.argv[1:])
