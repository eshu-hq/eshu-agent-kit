#!/usr/bin/env python3
"""Git change-point / post-edit attribution for skills and hooks in /debrief.

Prevents long-window (30d / --all-time) averages from firing stale MODIFY
recommendations for skills or hooks the user already improved mid-window.
"""
import datetime
import html
import os
import subprocess

from debrief_common import canon_skill, safe_float, safe_int, ts_to_epoch


def _git_last_edit(path):
    """Return (epoch, short_sha) for the latest git commit touching path, or (None, None)."""
    target = os.path.abspath(path)
    cwd = target if os.path.isdir(target) else os.path.dirname(target)
    if not os.path.isdir(cwd):
        return None, None
    try:
        out = subprocess.check_output(
            ["git", "-C", cwd, "log", "-1", "--format=%ct,%h", "--", target],
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=5,
        ).strip()
        if out and "," in out:
            ep_s, sha = out.split(",", 1)
            return float(ep_s), sha.strip() or None
    except Exception:
        pass
    return None, None


def _iso_utc(epoch):
    if not epoch:
        return None
    return datetime.datetime.fromtimestamp(float(epoch), tz=datetime.timezone.utc).isoformat(timespec="seconds")


def _edit_info(path):
    ep, sha = _git_last_edit(path)
    if ep is not None:
        return {"edited_epoch": ep, "edited_at": _iso_utc(ep), "edited_sha": sha, "source": "git"}
    try:
        mt = float(os.path.getmtime(path))
        return {"edited_epoch": mt, "edited_at": _iso_utc(mt), "edited_sha": None, "source": "mtime"}
    except OSError:
        return None


def _scan_skill_files(skills_dirs, repo_paths):
    """Discover canonical skill -> SKILL.md path across explicit skills_dirs and repos."""
    found = {}
    roots = list(skills_dirs or [])
    env_dirs = os.environ.get("DEBRIEF_SKILLS_DIRS", "")
    if env_dirs and not roots:
        roots.extend(p for p in env_dirs.split(os.pathsep) if p)
    for rp in repo_paths or []:
        if rp and os.path.isdir(os.path.join(rp, "skills")):
            roots.append(os.path.join(rp, "skills"))
    if not roots:
        kit_skills = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "skills"))
        if os.path.isdir(kit_skills):
            roots.append(kit_skills)

    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _, filenames in os.walk(root):
            if "SKILL.md" not in filenames:
                continue
            sk_name = canon_skill(os.path.basename(dirpath))
            if sk_name and sk_name not in found:
                found[sk_name] = os.path.join(dirpath, "SKILL.md")
    return found


def discover_changepoints(skills_dirs=None, repo_paths=None):
    """Discover last-edit timestamps/SHAs for each skill and for hooks/."""
    skill_files = _scan_skill_files(skills_dirs, repo_paths)
    skills_cp = {}
    for sk, fp in sorted(skill_files.items()):
        info = _edit_info(fp)
        if info:
            skills_cp[sk] = info

    hooks_cp = None
    hook_candidates = []
    for rp in repo_paths or []:
        hd = os.path.join(rp, "hooks")
        if os.path.isdir(hd):
            hook_candidates.append(hd)
    if not hook_candidates:
        kit_hooks = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "hooks"))
        if os.path.isdir(kit_hooks):
            hook_candidates.append(kit_hooks)
    for hd in hook_candidates:
        info = _edit_info(hd)
        if info and (hooks_cp is None or info["edited_epoch"] > hooks_cp["edited_epoch"]):
            hooks_cp = info

    return {"skills": skills_cp, "hooks": hooks_cp}


def latest_changepoint_epoch(changepoints, loaded_skills=None):
    """Return the most recent edited_epoch across relevant loaded skills and hooks, or None."""
    if not isinstance(changepoints, dict):
        return None
    skills_map = changepoints.get("skills") or {}
    if loaded_skills is not None:
        relevant = {canon_skill(s) for s in loaded_skills if canon_skill(s)}
        eps = [v["edited_epoch"] for sk, v in skills_map.items() if sk in relevant and v.get("edited_epoch")]
    else:
        eps = [v["edited_epoch"] for v in skills_map.values() if v.get("edited_epoch")]
    hc = changepoints.get("hooks")
    if isinstance(hc, dict) and hc.get("edited_epoch"):
        eps.append(hc["edited_epoch"])
    return max(eps) if eps else None


def _session_epoch(meta):
    for k in ("first_epoch", "last_epoch", "source_mtime"):
        v = meta.get(k)
        if isinstance(v, (int, float)) and v > 0:
            return float(v)
    return 0.0


def _bucket_stats(sess_list, hook_loads, hook_forced, skill_bytes):
    n = len(sess_list)
    if n == 0:
        return {"loads": 0, "errors_per_session": None, "redirects_per_session": None, "forced_pct": None, "overhead_per_load": None}
    errs = sum(sum((m.get("errors") or {}).values()) for m in sess_list)
    redirs = sum(safe_int((m.get("interjection_reasons") or {}).get("redirect_goal"), 0) for m in sess_list)
    forced_pct = round(100.0 * hook_forced / hook_loads, 1) if hook_loads > 0 else None
    ov = None
    if skill_bytes and skill_bytes > 0:
        tok_sz = skill_bytes / 4.0
        turns = sum(max(1, safe_int(m.get("prompts"), 1)) for m in sess_list)
        ov = round((tok_sz * turns) / n, 1)
    return {
        "loads": n,
        "errors_per_session": round(errs / n, 2),
        "redirects_per_session": round(redirs / n, 2),
        "forced_pct": forced_pct,
        "overhead_per_load": ov,
    }


def _classify_verdict(pre, post):
    if safe_int(post.get("loads"), 0) < 3:
        return "awaiting_data"
    if safe_int(pre.get("loads"), 0) < 1:
        return "post_only"
    improved = 0
    regressed = 0
    for key, tol in (("errors_per_session", 0.3), ("redirects_per_session", 0.15), ("forced_pct", 10.0)):
        pv, cv = pre.get(key), post.get(key)
        if pv is None or cv is None:
            continue
        if pv - cv >= tol:
            improved += 1
        elif cv - pv >= tol:
            regressed += 1
    if improved > 0 and regressed == 0:
        return "improved"
    if regressed > 0 and improved == 0:
        return "regressed"
    return "unchanged"


def compute_changepoint_impact(metas_values, hook_events, skill_sizes, changepoints, since_epoch=0.0):
    """Split each edited skill (and hooks/) into pre-edit vs post-edit buckets."""
    metas_list = list(metas_values or [])
    if not metas_list or not isinstance(changepoints, dict):
        return {"skills": {}, "hooks": None, "summary": {"skills_edited_in_window": 0, "improved": 0, "awaiting_data": 0, "unchanged": 0, "regressed": 0}}

    epochs = [_session_epoch(m) for m in metas_list if _session_epoch(m) > 0]
    min_ep = min(epochs) if epochs else 0.0
    max_ep = max(epochs) if epochs else 0.0

    # Group sessions & hook events per canonical skill
    by_skill = {}
    for m in metas_list:
        ep = _session_epoch(m)
        for raw_sk in set(m.get("skill_loads") or []):
            sk = canon_skill(raw_sk)
            if sk:
                by_skill.setdefault(sk, []).append((ep, m))

    # Index hook skill-load & nudge-block by skill + timestamp
    hook_by_skill = {}
    blocked_by_sess_sk = {}
    for ev in hook_events or []:
        ts_ep = ts_to_epoch(str(ev.get("ts") or "")) or 0.0
        et = str(ev.get("type") or "")
        sid = str(ev.get("session") or "")
        det = ev.get("detail") if isinstance(ev.get("detail"), dict) else {}
        if et == "nudge-block":
            for raw_sk in det.get("skills") or []:
                sk = canon_skill(raw_sk)
                if sk:
                    blocked_by_sess_sk.setdefault((sid, sk), []).append(ts_ep)
        elif et == "skill-load":
            sk = canon_skill(det.get("skill") or "")
            if sk:
                forced = any(b <= ts_ep for b in blocked_by_sess_sk.get((sid, sk), []))
                hook_by_skill.setdefault(sk, []).append((ts_ep, forced))

    skills_out = {}
    counts = {"improved": 0, "awaiting_data": 0, "unchanged": 0, "regressed": 0, "post_only": 0}
    for sk, cp in sorted((changepoints.get("skills") or {}).items()):
        ed = cp.get("edited_epoch") or 0.0
        sess_pairs = by_skill.get(sk) or []
        if not sess_pairs:
            continue
        # Inside git, track any edit occurring after >=1 pre-edit session (including
        # brand-new commits with 0 post-edit sessions yet -> awaiting_data). Outside
        # git (file mtime fallback), require sessions on both sides so a fresh clone/copy
        # never falsely suppresses recommendations.
        has_pre = any(ep > 0 and ep < ed for ep, _ in sess_pairs)
        has_post = any(ep >= ed for ep, _ in sess_pairs)
        in_window = (ed >= min_ep and ed <= max_ep + 86400) or (since_epoch and ed >= since_epoch)
        if cp.get("source") != "git" and not has_post:
            continue
        if not (has_pre and in_window):
            continue
        pre_s = [m for ep, m in sess_pairs if ep < ed]
        post_s = [m for ep, m in sess_pairs if ep >= ed]
        h_ev = hook_by_skill.get(sk) or []
        pre_hl = sum(1 for t, _ in h_ev if t < ed)
        pre_hf = sum(1 for t, f in h_ev if t < ed and f)
        post_hl = sum(1 for t, _ in h_ev if t >= ed)
        post_hf = sum(1 for t, f in h_ev if t >= ed and f)
        sz = safe_int((skill_sizes or {}).get(sk), 0)
        pre_st = _bucket_stats(pre_s, pre_hl, pre_hf, sz)
        post_st = _bucket_stats(post_s, post_hl, post_hf, sz)
        verdict = _classify_verdict(pre_st, post_st)
        counts[verdict] = counts.get(verdict, 0) + 1
        skills_out[sk] = {
            "edited_epoch": ed,
            "edited_at": cp.get("edited_at"),
            "edited_sha": cp.get("edited_sha"),
            "source": cp.get("source"),
            "pre": pre_st,
            "post": post_st,
            "verdict": verdict,
        }

    hooks_out = None
    hcp = changepoints.get("hooks")
    if isinstance(hcp, dict) and hcp.get("edited_epoch"):
        hed = hcp["edited_epoch"]
        pre_m = [m for m in metas_list if _session_epoch(m) < hed]
        post_m = [m for m in metas_list if _session_epoch(m) >= hed]
        if pre_m and (hed >= min_ep and hed <= max_ep + 86400):
            def _hblk(ml):
                if not ml:
                    return None
                hb = sum(safe_int((m.get("error_categories") or {}).get("Hook Blocked"), 0) for m in ml)
                return round(hb / len(ml), 3)
            pre_hb, post_hb = _hblk(pre_m), _hblk(post_m)
            if len(post_m) < 3:
                h_verdict = "awaiting_data"
            elif pre_hb is not None and post_hb is not None and (pre_hb - post_hb) >= 0.1:
                h_verdict = "improved"
            elif pre_hb is not None and post_hb is not None and (post_hb - pre_hb) >= 0.1:
                h_verdict = "regressed"
            else:
                h_verdict = "unchanged"
            hooks_out = {
                "edited_epoch": hed,
                "edited_at": hcp.get("edited_at"),
                "edited_sha": hcp.get("edited_sha"),
                "pre": {"sessions": len(pre_m), "hook_blocked_per_session": pre_hb},
                "post": {"sessions": len(post_m), "hook_blocked_per_session": post_hb},
                "verdict": h_verdict,
            }

    return {
        "skills": skills_out,
        "hooks": hooks_out,
        "summary": {
            "skills_edited_in_window": len(skills_out),
            "improved": counts["improved"],
            "awaiting_data": counts["awaiting_data"],
            "unchanged": counts["unchanged"],
            "regressed": counts["regressed"],
        },
    }


def _e(val):
    return html.escape(str(val if val is not None else ""), quote=True)


def render_changepoint_card(agg):
    """Render Post-Edit Impact (Since Last Skill & Hook Change) HTML card."""
    cp = agg.get("changepoints")
    if not isinstance(cp, dict):
        return ""
    skills = cp.get("skills") or {}
    hooks = cp.get("hooks")
    if not skills and not hooks:
        return ""
    badges = {
        "improved": ("IMPROVED", "#dcfce7", "#166534"),
        "awaiting_data": ("AWAITING DATA", "#e0f2fe", "#075985"),
        "unchanged": ("UNCHANGED", "#fef3c7", "#92400e"),
        "regressed": ("REGRESSED", "#fee2e2", "#991b1b"),
    }
    rows = []
    if hooks:
        lbl, bg, fg = badges.get(hooks["verdict"], (hooks["verdict"].upper(), "#f1f5f9", "#334155"))
        sha = hooks.get("edited_sha") or "mtime"
        dt = str(hooks.get("edited_at") or "")[:10]
        rows.append(
            f'<tr><td><strong>hooks/</strong></td>'
            f'<td><code>{_e(sha)}</code> ({_e(dt)})</td>'
            f'<td style="font-family:monospace;font-size:12px">{hooks["pre"]["sessions"]} sess, {hooks["pre"]["hook_blocked_per_session"]} blk/s</td>'
            f'<td style="font-family:monospace;font-size:12px">{hooks["post"]["sessions"]} sess, {hooks["post"]["hook_blocked_per_session"]} blk/s</td>'
            f'<td><span style="padding:2px 7px;border-radius:4px;font-size:11px;font-weight:700;background:{bg};color:{fg}">{_e(lbl)}</span></td></tr>'
        )
    for sk, info in sorted(skills.items()):
        lbl, bg, fg = badges.get(info["verdict"], (info["verdict"].upper(), "#f1f5f9", "#334155"))
        sha = info.get("edited_sha") or "mtime"
        dt = str(info.get("edited_at") or "")[:10]
        pr, po = info["pre"], info["post"]
        pre_s = f"{pr['loads']} loads, {pr['errors_per_session']} err/s, {pr['redirects_per_session']} red/s"
        post_s = f"{po['loads']} loads" + (f", {po['errors_per_session']} err/s, {po['redirects_per_session']} red/s" if po["loads"] else " (none yet)")
        rows.append(
            f'<tr><td><strong>{_e(sk)}</strong></td>'
            f'<td><code>{_e(sha)}</code> ({_e(dt)})</td>'
            f'<td style="font-family:monospace;font-size:12px">{_e(pre_s)}</td>'
            f'<td style="font-family:monospace;font-size:12px">{_e(post_s)}</td>'
            f'<td><span style="padding:2px 7px;border-radius:4px;font-size:11px;font-weight:700;background:{bg};color:{fg}">{_e(lbl)}</span></td></tr>'
        )
    return (
        '<div class="chart-card" id="section-changepoints" style="margin:20px 0">'
        '<div class="chart-title">Post-Edit Impact (Since Last Skill &amp; Hook Change)</div>'
        '<div style="font-size:12px;color:#64748b;margin:-4px 0 10px">'
        'Recommendations evaluate post-edit sessions only so pre-fix history does not trigger stale MODIFY nags.'
        '</div>'
        '<table class="skill-table" style="width:100%">'
        '<thead><tr><th>Skill / Surface</th><th>Last Edit</th><th>Pre-Edit</th><th>Post-Edit</th><th>Verdict</th></tr></thead>'
        f'<tbody>{"".join(rows)}</tbody></table></div>'
    )
