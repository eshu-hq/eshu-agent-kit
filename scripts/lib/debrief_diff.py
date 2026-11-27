#!/usr/bin/env python3
"""Report snapshots, report-to-report diffs, and recommendation accountability verification."""
import datetime
import hashlib
import html
import json
import os
import subprocess
import sys

from debrief_common import atomic_write_json, default_reports_dir, read_json, safe_float, safe_int
from debrief_radar import compare_radar_profiles, compute_radar_profile

SNAPSHOT_SCHEMA_VERSION = 1


def _fail(msg, code=2):
    sys.stderr.write(str(msg).rstrip("\n") + "\n")
    raise SystemExit(code)


def default_snapshots_dir(reports_dir=None):
    return os.path.join(reports_dir or default_reports_dir(), "snapshots")


def _file_sha256(path):
    if not path or not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None


def _git_head(repo_path):
    if not repo_path or not os.path.isdir(repo_path):
        return None
    try:
        out = subprocess.check_output(
            ["git", "-C", repo_path, "rev-parse", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
        return out or None
    except Exception:
        return None


def _git_touched_since(repo_path, prev_sha, rel_path):
    if not (repo_path and prev_sha and rel_path and os.path.isdir(repo_path)):
        return []
    try:
        out = subprocess.check_output(
            ["git", "-C", repo_path, "log", "--format=%h", f"{prev_sha}..HEAD", "--", rel_path],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
        return [ln.strip() for ln in out.splitlines() if ln.strip()]
    except Exception:
        return []


def _resolve_target_path(target, repo_paths=None, skills_dirs=None):
    """Best-effort local path for a recommendation target (skill name or repo file)."""
    if not target:
        return None, None
    t = str(target).strip()
    if os.path.isfile(t):
        return t, None
    # Skill name lookup in skills_dirs or repo_paths/skills/{core,eshu}/<t>/SKILL.md
    search_skill_dirs = list(skills_dirs or [])
    for rp in repo_paths or []:
        if rp and os.path.isdir(os.path.join(rp, "skills")):
            search_skill_dirs.append(os.path.join(rp, "skills"))
    for sd in search_skill_dirs:
        for rel in (os.path.join(t, "SKILL.md"), os.path.join("core", t, "SKILL.md"), os.path.join("eshu", t, "SKILL.md")):
            cand = os.path.join(sd, rel)
            if os.path.isfile(cand):
                return cand, rel
    for rp in repo_paths or []:
        if not rp:
            continue
        cand = os.path.join(rp, t)
        if os.path.isfile(cand):
            return cand, t
    return None, None


def _rec_id(kind, action, target):
    raw = f"{kind}|{action}|{str(target or '').strip().lower()}"
    return "rec_" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]


def _extract_kpis(agg):
    meta = agg.get("meta") or {}
    charts = agg.get("charts") or {}
    by_h = agg.get("by_harness") or {}
    skills = agg.get("skill_table") or []
    health = agg.get("session_health") or {}
    tot_sess = sum(safe_int(v.get("sessions"), 0) for v in by_h.values())
    top_sess = safe_int(meta.get("top_level_sessions"), 0)
    tot_errs = sum(safe_int(v.get("errors"), 0) for v in by_h.values())
    hook_blk = safe_int((charts.get("tool_error_categories") or {}).get("Hook Blocked"), 0)
    redirs = safe_int((charts.get("interjection_reasons") or {}).get("redirect_goal"), 0)
    totals = (agg.get("skill_costs") or {}).get("totals") or {}
    tot_tokens = safe_int(totals.get("tokens_in"), 0) + safe_int(totals.get("tokens_out"), 0)
    c_hits = c_tot = 0.0
    for hv in (health.get("cache_by_harness") or {}).values():
        if isinstance(hv, dict):
            tin = safe_float(hv.get("tokens_in"), 0.0)
            hpct = hv.get("cache_hit_pct")
            if tin > 0 and hpct is not None:
                c_hits += tin * (safe_float(hpct, 0.0) / 100.0)
                c_tot += tin
    if c_tot <= 0:
        cr = safe_float(totals.get("tokens_cache_read"), 0.0)
        tin = safe_float(totals.get("tokens_in"), 0.0)
        if tin > 0 and cr > 0:
            c_hits, c_tot = min(cr, tin), tin
    eval_wrs = [safe_float(r.get("eval_win_rate"), -1.0) for r in skills if r.get("eval_win_rate") is not None]
    eval_wrs = [w for w in eval_wrs if 0.0 <= w <= 1.0]
    f1s = [safe_float(r.get("trigger_f1"), -1.0) for r in skills if r.get("trigger_f1") is not None]
    f1s = [f for f in f1s if 0.0 <= f <= 1.0]
    return {
        "total_sessions": tot_sess,
        "top_level_sessions": top_sess,
        "total_errors": tot_errs,
        "errors_per_session": round(tot_errs / tot_sess, 4) if tot_sess > 0 else None,
        "hook_blocked": hook_blk,
        "redirect_goal": redirs,
        "redirect_per_session": round(redirs / top_sess, 4) if top_sess > 0 else None,
        "median_gap_s": charts.get("median_response_gap_s"),
        "total_tokens": tot_tokens,
        "cache_hit_pct": round((c_hits / c_tot) * 100.0, 2) if c_tot > 0 else None,
        "eval_mean_win_rate": round(sum(eval_wrs) / len(eval_wrs), 4) if eval_wrs else None,
        "trigger_mean_f1": round(sum(f1s) / len(f1s), 4) if f1s else None,
    }


def _skill_metrics_map(agg, skills_dirs=None, repo_paths=None):
    out = {}
    trends = (agg.get("eval_trends") or {}).get("per_skill") or {}
    for row in agg.get("skill_table") or []:
        sk = row.get("skill")
        if not sk:
            continue
        loads = safe_int(row.get("mined_loads"), 0)
        tax = safe_float(row.get("estimated_context_tax_tokens"), 0.0)
        fp, _ = _resolve_target_path(sk, repo_paths=repo_paths, skills_dirs=skills_dirs)
        sha = _file_sha256(fp)
        if not sha and sk in trends:
            tval = trends.get(sk)
            if isinstance(tval, list) and tval:
                sha = (tval[-1] or {}).get("skill_sha") or sha
            elif isinstance(tval, dict):
                for entries in tval.values():
                    if isinstance(entries, list) and entries:
                        sha = (entries[-1] or {}).get("skill_sha") or sha
        out[sk] = {
            "mined_loads": loads,
            "hook_loads": safe_int(row.get("hook_loads"), 0),
            "forced_pct": row.get("forced_pct"),
            "overhead_tokens": round(tax, 1),
            "overhead_per_load": round(tax / loads, 1) if loads > 0 else None,
            "errors_per_session": row.get("error_rate_per_session"),
            "redirect_interjections": safe_int(row.get("redirect_interjections"), 0),
            "papercut_open": safe_int(row.get("papercut_open"), 0),
            "papercut_fixed": safe_int(row.get("papercut_fixed"), 0),
            "eval_win_rate": row.get("eval_win_rate"),
            "eval_noise_band": row.get("eval_noise_band"),
            "trigger_f1": row.get("trigger_f1"),
            "skill_sha": sha,
            "skill_bytes": os.path.getsize(fp) if fp and os.path.isfile(fp) else None,
        }
    return out


def _pick_target_metric(action, target, sm_map, kpis):
    sm = sm_map.get(target)
    if sm:
        if sm.get("forced_pct") is not None and safe_float(sm["forced_pct"], 0) >= 25.0:
            return {"name": "forced_pct", "baseline": sm["forced_pct"], "direction": "min", "skill": target}
        if sm.get("overhead_per_load") is not None and safe_float(sm["overhead_tokens"], 0) >= 50_000_000:
            return {"name": "overhead_per_load", "baseline": sm["overhead_per_load"], "direction": "min", "skill": target}
        if sm.get("errors_per_session") is not None and safe_float(sm["errors_per_session"], 0) >= 2.0:
            return {"name": "errors_per_session", "baseline": sm["errors_per_session"], "direction": "min", "skill": target}
        if sm.get("eval_win_rate") is not None:
            return {"name": "eval_win_rate", "baseline": sm["eval_win_rate"], "direction": "max", "skill": target}
        return {"name": "redirect_interjections", "baseline": sm.get("redirect_interjections"), "direction": "min", "skill": target}
    if action == "create":
        return {"name": "redirect_per_session", "baseline": kpis.get("redirect_per_session"), "direction": "min", "skill": None}
    return {"name": "errors_per_session", "baseline": kpis.get("errors_per_session"), "direction": "min", "skill": None}


def build_snapshot(agg, syn=None, repo_paths=None, skills_dirs=None, snapshot_id=None):
    """Build a compact content-free snapshot JSON from aggregate (+ optional synthesis)."""
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")
    sid = snapshot_id or ("snap-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d-%H%M%S"))
    kpis = _extract_kpis(agg)
    sm_map = _skill_metrics_map(agg, skills_dirs=skills_dirs, repo_paths=repo_paths)
    radar = agg.get("radar_profile") or compute_radar_profile(agg)
    repo_heads = {}
    for rp in repo_paths or []:
        head = _git_head(rp)
        if head:
            repo_heads[os.path.basename(os.path.abspath(rp))] = head

    # Carry forward carry_over_count / first_seen_at from prior accountability check if present
    prev_acct = {
        r["rec_id"]: r
        for r in ((agg.get("diff_from_prev") or {}).get("accountability") or [])
        if isinstance(r, dict) and r.get("rec_id")
    }
    recs = []
    seen = set()

    def add_rec(kind, action, target, summary):
        rid = _rec_id(kind, action, target)
        if rid in seen:
            return
        seen.add(rid)
        fp, _ = _resolve_target_path(target, repo_paths=repo_paths, skills_dirs=skills_dirs)
        prev_r = prev_acct.get(rid) or {}
        recs.append({
            "rec_id": rid,
            "kind": kind,
            "action": action,
            "target": target,
            "target_sha": _file_sha256(fp) or (sm_map.get(target) or {}).get("skill_sha"),
            "target_metric": _pick_target_metric(action, target, sm_map, kpis),
            "summary": str(summary or "")[:240],
            "first_seen_at": prev_r.get("first_seen_at") or now_iso,
            "carry_over_count": safe_int(prev_r.get("carry_over_count"), 0),
        })

    for item in agg.get("skill_recommendations") or []:
        add_rec("skill_lifecycle", item.get("action") or "modify", item.get("target") or "", item.get("suggestion") or item.get("reason") or "")
    for item in (syn or {}).get("agents_md_additions") or []:
        add_rec("agents_rule", "add_rule", item.get("target") or "AGENTS.md", item.get("why") or item.get("snippet") or "")

    pareto = agg.get("pareto") or {}
    pareto_hv = (pareto.get("summary") or {}).get("mean_version_hv")
    return {
        "schema_version": SNAPSHOT_SCHEMA_VERSION,
        "snapshot_id": sid,
        "recorded_at": now_iso,
        "scope": (agg.get("meta") or {}).get("scope") or {},
        "repo_heads": repo_heads,
        "kpis": kpis,
        "radar": radar,
        "pareto_hv": pareto_hv,
        "skill_metrics": sm_map,
        "recommendations": recs,
    }


def save_snapshot(snapshot, reports_dir=None, explicit_out=""):
    """Persist snapshot to local snapshots dir (updating latest + scope pointer) and optional --snapshot-out."""
    sdir = default_snapshots_dir(reports_dir)
    os.makedirs(sdir, exist_ok=True)
    snap_path = os.path.join(sdir, f"{snapshot['snapshot_id']}.json")
    atomic_write_json(snap_path, snapshot)
    atomic_write_json(os.path.join(sdir, "latest-snapshot.json"), snapshot)
    skey = (snapshot.get("scope") or {}).get("scope_key")
    if skey:
        atomic_write_json(os.path.join(sdir, f"latest-{skey}.json"), snapshot)
    if explicit_out:
        atomic_write_json(explicit_out, snapshot)
    return snap_path


def find_previous_snapshot(reports_dir=None, scope_key=None):
    """Locate most recent snapshot matching scope_key, falling back to latest-snapshot.json."""
    sdir = default_snapshots_dir(reports_dir)
    cands = []
    if scope_key:
        cands.append(os.path.join(sdir, f"latest-{scope_key}.json"))
    cands.append(os.path.join(sdir, "latest-snapshot.json"))
    for p in cands:
        if os.path.isfile(p):
            obj = read_json(p)
            if isinstance(obj, dict) and obj.get("kpis"):
                return p, obj
    return None, None


def _kpi_delta(prev_v, curr_v, direction):
    if prev_v is None or curr_v is None:
        return {"prev": prev_v, "curr": curr_v, "delta": None, "pct_change": None, "improved": None}
    pv, cv = float(prev_v), float(curr_v)
    delta = round(cv - pv, 4)
    pct = round(((cv - pv) / abs(pv)) * 100.0, 1) if pv != 0 else None
    improved = (delta > 0) if direction == "max" else (delta < 0) if delta != 0 else None
    return {"prev": prev_v, "curr": curr_v, "delta": delta, "pct_change": pct, "improved": improved}


def _verify_recommendation(rec, prev_snap, curr_snap, repo_paths=None, skills_dirs=None):
    target = rec.get("target") or ""
    action = rec.get("action") or "modify"
    prev_sha = rec.get("target_sha")
    curr_sm = (curr_snap.get("skill_metrics") or {}).get(target)
    prev_sm = (prev_snap.get("skill_metrics") or {}).get(target)

    # 1. Check implementation evidence
    evidence = []
    changed = False
    fp, rel = _resolve_target_path(target, repo_paths=repo_paths, skills_dirs=skills_dirs)
    curr_sha = _file_sha256(fp) or (curr_sm or {}).get("skill_sha")
    if prev_sha and curr_sha and curr_sha != prev_sha:
        changed = True
        evidence.append(f"target SHA changed ({prev_sha[:7]} -> {curr_sha[:7]})")
    elif action == "remove" and prev_sha and not fp and not curr_sm:
        changed = True
        evidence.append("target skill removed")
    elif action == "create" and not prev_sha and fp:
        changed = True
        evidence.append("target skill/file created")

    if curr_sm and prev_sm:
        if safe_int(curr_sm.get("papercut_fixed"), 0) > safe_int(prev_sm.get("papercut_fixed"), 0):
            changed = True
            evidence.append("tied papercut closed")
        if curr_sm.get("skill_sha") and prev_sm.get("skill_sha") and curr_sm["skill_sha"] != prev_sm["skill_sha"]:
            if not any("SHA changed" in e for e in evidence):
                changed = True
                evidence.append(f"skill version updated ({prev_sm['skill_sha'][:7]} -> {curr_sm['skill_sha'][:7]})")

    for rp in repo_paths or []:
        rname = os.path.basename(os.path.abspath(rp))
        prev_head = (prev_snap.get("repo_heads") or {}).get(rname)
        check_rel = rel or target
        commits = _git_touched_since(rp, prev_head, check_rel)
        if commits:
            changed = True
            evidence.append(f"git commits touching {check_rel}: {', '.join(commits[:3])}")

    # 2. Check target metric movement
    tm = rec.get("target_metric") or {}
    mname = tm.get("name")
    base_v = tm.get("baseline")
    direction = tm.get("direction") or "min"
    sk = tm.get("skill")
    if sk:
        curr_v = (curr_sm or {}).get(mname)
        sample_n = safe_int((curr_sm or {}).get("mined_loads"), 0)
        noise = safe_float((curr_sm or {}).get("eval_noise_band"), 0.0) if mname == "eval_win_rate" else 0.0
    else:
        curr_v = (curr_snap.get("kpis") or {}).get(mname)
        sample_n = safe_int((curr_snap.get("kpis") or {}).get("top_level_sessions"), 0)
        noise = 0.0

    improved = None
    metric_delta = None
    if base_v is not None and curr_v is not None:
        metric_delta = round(float(curr_v) - float(base_v), 4)
        margin = max(noise, 0.02 if mname in ("eval_win_rate", "trigger_f1") else 0.0)
        if direction == "max":
            improved = (float(curr_v) - float(base_v)) > margin
        else:
            improved = (float(base_v) - float(curr_v)) > margin

    prev_carry = safe_int(rec.get("carry_over_count"), 0)
    if changed:
        if sample_n < 3 and improved is not True:
            status = "implemented_pending_data"
        elif improved is True:
            status = "implemented_verified"
        else:
            status = "implemented_ineffective"
        carry = 0
    else:
        if improved is True:
            status = "resolved_externally"
            carry = 0
        else:
            status = "not_done"
            carry = prev_carry + 1

    return {
        "rec_id": rec.get("rec_id"),
        "kind": rec.get("kind"),
        "action": action,
        "target": target,
        "summary": rec.get("summary") or "",
        "status": status,
        "changed": changed,
        "evidence": evidence,
        "metric": {"name": mname, "prev": base_v, "curr": curr_v, "delta": metric_delta, "direction": direction, "improved": improved},
        "first_seen_at": rec.get("first_seen_at"),
        "carry_over_count": carry,
    }


def diff_snapshots(prev_snap, curr_snap, repo_paths=None, skills_dirs=None):
    """Compare two report snapshots: KPI deltas, skill deltas, radar diff, HV delta, and recommendation accountability."""
    p_sc = prev_snap.get("scope") or {}
    c_sc = curr_snap.get("scope") or {}
    warnings = []
    if p_sc.get("mode") != c_sc.get("mode"):
        warnings.append(f"Scope mode differs: prev={p_sc.get('mode')} vs curr={c_sc.get('mode')}")
    if sorted(p_sc.get("harnesses") or []) != sorted(c_sc.get("harnesses") or []):
        warnings.append(f"Harnesses differ: prev={p_sc.get('harnesses')} vs curr={c_sc.get('harnesses')}")
    if p_sc.get("project") != c_sc.get("project"):
        warnings.append(f"Project filter differs: prev={p_sc.get('project')} vs curr={c_sc.get('project')}")

    pk, ck = prev_snap.get("kpis") or {}, curr_snap.get("kpis") or {}
    kpi_specs = (
        ("errors_per_session", "min"),
        ("hook_blocked", "min"),
        ("redirect_per_session", "min"),
        ("cache_hit_pct", "max"),
        ("eval_mean_win_rate", "max"),
        ("trigger_mean_f1", "max"),
        ("total_tokens", "min"),
    )
    kpi_deltas = {name: _kpi_delta(pk.get(name), ck.get(name), d) for name, d in kpi_specs}

    radar_diff = compare_radar_profiles(prev_snap.get("radar"), curr_snap.get("radar"))
    hv_prev, hv_curr = prev_snap.get("pareto_hv"), curr_snap.get("pareto_hv")
    hv_delta = round(float(hv_curr) - float(hv_prev), 4) if (hv_prev is not None and hv_curr is not None) else None

    acct = [
        _verify_recommendation(r, prev_snap, curr_snap, repo_paths=repo_paths, skills_dirs=skills_dirs)
        for r in (prev_snap.get("recommendations") or [])
    ]
    counts = {}
    for row in acct:
        counts[row["status"]] = counts.get(row["status"], 0) + 1

    return {
        "prev_snapshot_id": prev_snap.get("snapshot_id"),
        "prev_recorded_at": prev_snap.get("recorded_at"),
        "curr_snapshot_id": curr_snap.get("snapshot_id"),
        "scope_warnings": warnings,
        "kpi_deltas": kpi_deltas,
        "radar_diff": radar_diff,
        "pareto_hv": {"prev": hv_prev, "curr": hv_curr, "delta": hv_delta},
        "accountability": acct,
        "accountability_counts": counts,
    }
