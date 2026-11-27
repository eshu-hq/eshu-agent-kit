---
name: papercut
tier: core
description: Use on any harness whenever a skill, hook, script, or doc misleads the session, fails silently, or contradicts reality. Files canonicalized, deduplicated papercut issues via scripts/file-papercut.sh and exports snapshots for /debrief.
---

# Papercut

File small in-session friction so `/debrief` tracks each report to its owning skill and confirms when it closes. Do not bundle unrelated bugs into one papercut, and fix trivial one-line defects inline when they fit the files your current PR already edits.

Scope: portable `core` layer across Claude, Codex, Muse, Antigravity, and OpenCode. Resolve `$KIT` from this file's directory (`readlink -f` up three levels from `skills/core/papercut/SKILL.md` to the kit root holding `scripts/file-papercut.sh`). Set `PAPERCUT_REPO=<owner/repo>` or pass `--repo` to target any GitHub repository outside the current git origin.

## Workflow

1. Confirm the report belongs in a papercut: one concrete friction event where a skill, hook, script, or doc misled the session, failed silently, or contradicted reality. Done when you can state the canonical skill name plus what was tried, expected, happened, and the smallest fix.
2. Dry-run the CLI to verify the canonical `skill: <name>` join-key line and the formatted four-section body before touching GitHub. Done when `--dry-run` exits 0 and prints the expected `skill:` line and `papercut` title.

```bash
bash "$KIT/scripts/file-papercut.sh" file \
  --skill <name> \
  --title "<short summary>" \
  --tried "<concrete command or step>" \
  --expected "<documented or promised behavior>" \
  --happened "<observed failure or mismatch>" \
  --fix "<smallest change that removes the friction>" \
  --dry-run --no-dedupe
```

3. File the papercut (live mode automatically checks open `papercut` issues for the same skill and topic, commenting on an existing issue instead of opening a duplicate). Pass `--repo <owner/repo>` when filing outside the current checkout's GitHub origin. Done when `file-papercut.sh` prints the created issue URL or the commented duplicate `#N` and exits 0.

```bash
bash "$KIT/scripts/file-papercut.sh" file \
  --skill <name> \
  --title "<short summary>" \
  --tried "<concrete command or step>" \
  --expected "<documented or promised behavior>" \
  --happened "<observed failure or mismatch>" \
  --fix "<smallest change that removes the friction>"
```

4. When preparing inputs for `/debrief`, export a fresh papercut snapshot atomically so `scripts/debrief.sh aggregate --papercuts FILE` can join filed-vs-fixed counts offline. Done when `snapshot` exits 0 and reports the written issue count.

```bash
bash "$KIT/scripts/file-papercut.sh" snapshot \
  --out "${TMPDIR:-/tmp}/papercuts.json" \
  --limit 200
```

## Error recovery

- When `gh` is unavailable or unauthenticated: `file-papercut.sh` exits 1 with a clear stderr message. Fall back to `--dry-run --no-dedupe` to print the formatted title and body, then file it once `gh auth login` succeeds or paste it into the repository's papercut issue form.
- When a duplicate open papercut already exists: live `file` automatically detects same-skill keyword overlap and posts your evidence as a comment on `#N` instead of opening a second issue. For offline checks, pass `--dedupe-file <snapshot.json>` with `--dry-run` to preview `duplicate: #N` before going online.
- When a skill name is non-canonical (plugin prefix like `eshu-agent-kit:`, legacy `eshu-` prefix, uppercase, or trailing punctuation): `file-papercut.sh` normalizes it using the same rules as `/debrief` (`debrief_common.canon_skill`). If `--dry-run` still prints an unexpected `skill:` value or exits 2 on empty name, check the canonical name in [registry.md](../../registry.md) and pass that exact name.
- When `file` exits 2 for missing fields: supply all five required flags (`--skill`, `--tried`, `--expected`, `--happened`, `--fix`) as non-empty text and re-run.
- When `snapshot` fails on malformed JSON or network failure: the script aborts without replacing `--out`, preserving any previous snapshot; verify `gh auth status` and `--repo <owner/repo>`, then re-run.
