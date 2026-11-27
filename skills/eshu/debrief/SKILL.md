---
name: debrief
description: "Use when asked for a skills debrief, /debrief, a usage-insights-style report, or workflow recommendations across Muse, Antigravity (agy), and Claude. Runs scripts/debrief.sh (Stage 1 meta + Stage 2 cached semantic facets + hook telemetry) and renders an offline interactive HTML report."
---

# Multi-Harness Agent Debrief

Generate a `/insights`-grade operational debrief across **Muse**, **Antigravity (`agy`)**, and **Claude** sessions. Deterministic scripts extract session metadata, cache semantic facets locally under `$XDG_DATA_HOME/eshu-agent-kit/debrief-cache/`, merge hook telemetry (`skills-usage.jsonl`) and git history, and render an offline interactive HTML report. Your job is to orchestrate parallel fast-tier facet extraction for uncached sessions and write the high-signal narrative synthesis and actionable workflow fixes.

Scope: this is the `eshu` layer of the kit. Skill names, goal mechanics, and hook events resolve per `skills/registry.md`. By default, debrief runs across **all harnesses (`muse,agy,claude`)** and **all repos** over the last **30 days**; pass `--since YYYY-MM-DD`, `--days N`, `--project SUB`, or `--harness muse,agy,claude` when the user asks to narrow scope.

Privacy boundary: local transcripts and cached facets stay under `$XDG_DATA_HOME/eshu-agent-kit/debrief-cache/` (never committed, never uploaded). Hook telemetry in `skills-usage.jsonl` stays content-free. Cite short session IDs in the report; never paste raw message text or secrets.

## Workflow (5 Steps)

### Step 1: Resolve Kit Root & Prepare Batches

Find the kit checkout from the path of this `SKILL.md`: follow symlinks (`readlink -f`) and go up three levels (`skills/eshu/debrief` → kit root containing `scripts/debrief.sh`). If copied without a symlink, resolve under your harness user skills directory; if still missing, ask for the kit path.

Run Stage 1 extraction and batch preparation:

```bash
bash "$KIT/scripts/debrief.sh" prepare --days 30 --max-new 100 --batch-size 10
```

Add `--since`, `--project`, or `--harness` if requested. `prepare`:
- Extracts/caches Stage 1 metadata (`tools`, `error_categories`, `languages`, `response_gaps`, `message_hours`, `skill_loads`, `turns_after_skill_load`, `git_commits`, `subagents`, and token/cache usage across all 3 harnesses: Claude `message.usage` + cache read/write, agy `PLANNER_RESPONSE` input/output/cache read, and Muse `model_completed` usage + `duration_ms` with fallback to `subagent.control.runtime_observed`) incrementally by file `mtime`.
- Auto-imports existing `~/.claude/usage-data/facets/*.json` so Claude sessions are not re-classified.
- Rolls Muse, `agy`, and Claude child subagents into their parent coordinator digest.
- Skips trivial sessions (`prompts < 2` and `tool_calls < 3`).
- Emits up to `--max-new` (default 100, newest first) uncached digests into `batch-01.json`, `batch-02.json`, … and prints a JSON manifest.

### Step 2: Parallel Fast-Tier Facet Extraction (Stage 2)

If `manifest.facets_queued == 0`, skip directly to Step 3.

Otherwise, dispatch **one fast-tier subagent per `batch-XX.json` in parallel** (`flash` on `agy`, `muse-ember` on Muse, `haiku` on Claude). Give each subagent its batch file path and ask it to return strict JSON `{"facets": [...]}` with one object per digest in the batch using this exact schema:

```json
{
  "session_id": "<exact digest session_id>",
  "harness": "muse|agy|claude",
  "source_mtime": 0,
  "underlying_goal": "1 concise sentence describing what the user wanted",
  "goal_categories": {"<snake_case_category>": 1},
  "outcome": "fully_achieved|mostly_achieved|partially_achieved|not_achieved|unclear",
  "satisfaction": "satisfied|likely_satisfied|dissatisfied|frustrated|unsure",
  "friction_counts": {"<friction_type>": 1},
  "friction_detail": "1-2 sentences naming the concrete failure mode (or empty string)",
  "primary_success": "multi_file_changes|good_debugging|correct_code_edits|good_explanations|proactive_help|fast_accurate_search|none",
  "session_type": "single_task|multi_task|iterative_refinement|exploration|quick_question",
  "brief_summary": "1-2 sentences summarizing what happened and how it ended"
}
```

Use concrete `goal_categories` (e.g. `bug_fix`, `feature_implementation`, `ci_workflow_maintenance`, `pr_review_and_merge`, `performance_investigation`, `docs_and_process`, `refactoring`, `testing_and_verification`) and canonical `friction_counts` keys (`buggy_code`, `wrong_approach`, `hook_or_env_retry`, `stale_status`, `tool_failure`, `misunderstood_request`, `missing_path_probe`, `excessive_changes`, `context_loss`, `user_rejected_action`).

As each subagent replies, validate and write its facets atomically:

```bash
bash "$KIT/scripts/debrief.sh" cache-write /path/to/batch-01-facets.json
```

(Or pipe JSON on stdin with `cache-write -`.) Re-run or fix any rejected record before proceeding.

### Step 3: Aggregate Across Harnesses, Hooks & Git

```bash
bash "$KIT/scripts/debrief.sh" aggregate --days 30 --repo "$PWD" --out "$WORK/aggregate.json"
```

Pass `--log` for extra machine logs, additional `--repo` flags for other active repos, and the same `--since`/`--project`/`--harness` flags used in Step 1. Pass `--papercuts FILE` with a snapshot exported via `gh issue list --label papercut --json number,title,body,state,stateReason > FILE` (aggregate itself makes no live `gh` calls); a later run on a fresh snapshot confirms a finding fixed when its issue closes. Pass repeatable `--evals PATH` (a JSON object, JSON array, `{"evals": ...}` wrapper, or directory of `*.json` replay-eval summaries; offline only) to join per-skill eval win rates, noise bands, pass rates, and pair counts (deduplicated per skill keeping newest `recorded_at`). Pass repeatable `--trigger-evals PATH` (files or directories of `replay-eval.sh trigger --json-out` results; any other JSON exits non-zero) for description trigger precision/recall; never route those through `--evals`. Pass repeatable `--eval-history` with an optional PATH (a `replay-eval.sh report --history` JSONL ledger; a bare flag reads the default ledger under the data dir, an explicit missing path exits non-zero, torn lines are skipped and counted) to build per-skill version trends from the ledger plus every `--evals` record; records whose `kind` is not `ablation` are ignored.

Read `$WORK/aggregate.json` — it contains:
- `meta` (totals, active days, git repo rollups, excluded fixtures)
- `by_harness` (per-harness top/all sessions, facets, prompts, tool calls, errors)
- `hooks` (`goal_done`, `goal_released`, `model_failures`, `nudge_blocked`)
- `charts` (all 14 deterministic distributions, incl. prompt_distribution, + multi-agent parallel overlap + UTC hour counts; `median_response_gap_s_by_harness` sits beside the global median)
- `interjections` (follow-up rates, per-harness medians, top steered sessions; zero-prompt sessions named so rates read as lower bounds)
- `skill_table` (mined loads vs hook loads vs forced share vs goal stall share, cost columns `attributed_tokens_in/out/total`, `attributed_cache_read/write`, `attributed_errors`, `error_rate_per_session`, `token_bearing_sessions`, latency/tax `median_gap_s`, `median_duration_min`, `estimated_context_tax_tokens`, `papercut_filed`/`papercut_open`/`papercut_fixed` when `--papercuts` is passed, and `eval_win_rate`, `eval_noise_band`, `eval_pass_rate`, `eval_pairs` when `--evals` is passed, and `trigger_precision`, `trigger_recall`, `trigger_f1`, `trigger_decider` when `--trigger-evals` is passed)
- `papercuts` (per-skill findings counts `filed`, `open`, and `fixed` joined on the `skill:` body line, plus `total_filed`, `total_open`, `total_fixed`, and `unmatched_without_skill`; `null` without `--papercuts`)
- `evals` (per-skill replay-eval summaries with `win_rate`, `noise_band`, `pass_rate_with`, `pass_rate_without`, `cross_pairs`, cost/latency deltas, `tool_calls_delta`, `tool_errors_delta`, `skill_sha`, `harness`, `recorded_at`; `null` without `--evals`)
- `eval_trends` (`sources`, `records_loaded`, `records_skipped`, and `per_skill` version lists keyed by `(harness, skill_sha)` with `sha_short`, first/last `recorded_at`, `runs`, and the newest run's win rate, noise band, pass rate, tool and cost deltas; newest 20 per skill and harness; `null` without `--evals` or `--eval-history`)
- `trigger_evals` (newest per-skill, per-decider precision/recall/F1 with FP/FN counts from `replay-eval.sh trigger` results; `null` without `--trigger-evals`; a live decider is preferred over the rubric and the card always names the decider)
- `skill_costs` (`per_skill` cost/tax/latency/error attribution, `by_harness` token rollup, explicit `unattributed` totals, `totals`, and equal-split caveats; Claude, agy `PLANNER_RESPONSE`, and Muse main-session `model_completed` tokens are mined while older sessions lacking usage fields report 0; per-harness figures are never ranked against each other)
- `repositories` (normalized per-repo session, prompt, tool, error, token, top-skills, and top-interjection-reason rollups collapsing git/Claude worktrees under their parent repository)
- `interjections` (prompts-per-session distribution, follow-up rate, and content-free follow-up intent counts: `redirect_goal`, `debugging`, `thought_process`, `new_scope`, `approval`, `clarification`)
- `skill_recommendations` (evidence-backed `create` / `modify` / `remove` skill lifecycle suggestions driven by repo frequency, unattributed friction, overhead, nudged %, errors, open papercuts, goal-redirects, unused skills, and A/B evals)
- `session_health` (skill-stacking distribution `0`/`1-2`/`3-5`/`6+`, model turn mix, per-harness prompt cache hit/write/fresh percentages, and runaway/high-friction session outliers)
- `coaching_playbook` (two-sided plain-English action plan split into `for_you` user prompting/pacing habits and `for_agents` skill/rule/hook fixes)
- `facet_summaries` (structured per-session goals, outcomes, friction, and summaries)

### Step 4: Synthesize Usage-Driven Recommendations & Render HTML

Write `$WORK/synthesis.json` grounded strictly in `aggregate.json`. Every recommendation must cite the specific pattern, count, or session IDs that motivate it. Keep the report operational: no upsell card, no team-feedback section, no entertainment fluff, never rank people or harnesses, and never confuse correlation with causation.

Required `synthesis.json` schema:

```json
{
  "at_a_glance": {
    "working": "1-2 sentences on strongest proven patterns.",
    "hindering": "1-2 sentences on top recurring friction.",
    "quick_wins": "1-2 sentences on highest-leverage rules/skills/hooks to add.",
    "ambitious": "1-2 sentences on next-level parallel/autonomous workflows."
  },
  "project_areas": [
    {"name": "Area Name", "sessions_label": "~N sessions", "description": "2-3 sentences of concrete work observed."}
  ],
  "narrative_paragraphs": ["2-3 concise second-person paragraphs on how the sessions actually ran."],
  "key_insight": "The single highest-leverage observation from this window.",
  "wins_intro": "1 sentence framing what went right.",
  "big_wins": [
    {"title": "Win Title", "description": "2-3 sentences citing the evidence chain and session IDs."}
  ],
  "friction_intro": "1 sentence framing where time was lost.",
  "friction_categories": [
    {
      "title": "Friction Pattern",
      "description": "1-2 sentences on root cause and impact.",
      "examples": ["Concrete example with short session ID (no raw prompt text)."],
      "remediation": "Concrete action (rule, skill edit, hook fix, or replay-eval case) to prevent this friction."
    }
  ],
  "agents_md_additions": [
    {
      "target": "AGENTS.md | agents/roles.json | hooks/skill-nudge.sh | skills/...",
      "snippet": "Copy-pasteable rule, pre-brief, or hook snippet.",
      "why": "Evidence-backed reason tied to observed friction."
    }
  ],
  "features_to_try": [
    {
      "title": "Skill, Hook, or Harness Feature",
      "oneliner": "What it does in one line.",
      "why": "Why it fixes a pattern seen in your data.",
      "example": "Concrete command, config, or prompt to try."
    }
  ],
  "usage_patterns": [
    {
      "title": "Concrete Habit Shift",
      "summary": "1-sentence takeaway.",
      "detail": "2-3 sentences grounded in observed counts.",
      "prompt": "Ready-to-paste prompt for Muse / agy / Claude."
    }
  ],
  "horizon_intro": "1 sentence framing ambitious workflow upgrades.",
  "horizon_workflows": [
    {
      "title": "Ambitious Workflow",
      "possible": "What becomes possible with multi-agent / headless / hook automation.",
      "tip": "Practical first step.",
      "prompt": "Ready-to-paste workflow prompt."
    }
  ]
}
```

Render the offline HTML report:

```bash
bash "$KIT/scripts/debrief.sh" render \
  --aggregate "$WORK/aggregate.json" \
  --synthesis "$WORK/synthesis.json"
```

By default, `render` writes `$XDG_DATA_HOME/eshu-agent-kit/debrief-reports/report-YYYY-MM-DD-HHMMSS.html` and updates `report-latest.html` (override with `--out PATH` when requested). Under Harnesses & Skill Effectiveness it renders a **Skill Quality Flywheel** summary card (total tokens tracked, biggest skill overhead, open vs fixed papercut issues when `--papercuts` is passed, and eval-covered skills count when `--evals` is passed), a **Trigger Precision / Recall** card (only with `--trigger-evals`; names the decider, and live deciders are router-prompt results rather than native trigger rates), a **Skill Quality Trends (Version History)** card (only with `--evals` or `--eval-history`; newest 5 versions per skill and harness with win-rate change vs the previous version, `within noise` when inside the larger noise band), and the **Top Skills (Flywheel Scorecard)** table (`Skill | Sessions Used | Hook Loads | Nudged % | Total Tokens | Skill Overhead (tok) | Reply Gap / Session Len | Errors (Avg / Session) | Issues (Open / Fixed) | A/B Win Rate (±Noise)`) with hover tooltips and a plain-English column guide. Generated reports are offline (inline CSS/JS, system font stack, zero external requests) and have no artificial line cap.

### Step 5: Chat Summary

Reply concisely with:
1. Clickable `file://` link to the generated HTML report (and `report-latest.html`).
2. Coverage line (window, harnesses, top-level sessions, facets analyzed, any deferred by the 100-session cap).
3. The **Key Insight** and **Top 3 Actionable Fixes**.
4. What the data could not answer (unwired `agy` hooks, Codex/OpenCode exclusions, correlation caveats).
