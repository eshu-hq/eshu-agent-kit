#!/usr/bin/env python3
"""Isolated multi-harness runner for replay evals (issue #103).

Runs one prompt against claude, agy, or muse in an isolated detached git
worktree (or temp dir) with a target SKILL.md either injected (with-skill) or
stripped (without-skill), writing a normalized trajectory JSON file.
"""
import contextlib
import getopt
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from debrief_common import canon_skill, safe_float, safe_int  # noqa: E402

VALID_HARNESSES = ("claude", "agy", "muse")
VALID_MODES = ("with-skill", "without-skill")


def _fail(msg, code=1):
    print("replay-runner: %s" % msg, file=sys.stderr)
    sys.exit(code)


def default_kit_dir():
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )


def resolve_skill_path(kit_dir, skill):
    """Locate SKILL.md under skills/eshu/<skill> or skills/core/<skill>."""
    name = canon_skill(skill)
    if not name:
        return ""
    for layer in ("eshu", "core"):
        cand = os.path.join(kit_dir, "skills", layer, name, "SKILL.md")
        if os.path.isfile(cand):
            return cand
    return ""


def wrap_prompt_with_skill(prompt, skill, skill_text):
    """Prepend target skill instructions cleanly without arm identity tokens."""
    return (
        "Follow these instructions for %s:\n\n%s\n\n---\n\nTask:\n%s"
        % (skill, skill_text.strip(), prompt)
    )


def _is_git_repo(path):
    if not path or not os.path.isdir(path):
        return False
    proc = subprocess.run(
        ["git", "-C", path, "rev-parse", "--is-inside-work-tree"],
        capture_output=True, text=True,
    )
    return proc.returncode == 0 and proc.stdout.strip() == "true"


@contextlib.contextmanager
def isolated_workspace(workspace=None):
    """Yield a clean detached git worktree or isolated temp dir; always clean up."""
    parent = tempfile.mkdtemp(prefix="replay-iso-")
    used_wt = False
    iso_dir = os.path.join(parent, "work")
    try:
        if workspace and _is_git_repo(workspace):
            iso_dir = os.path.join(parent, "wt")
            proc = subprocess.run(
                ["git", "-C", workspace, "worktree", "add", "--detach", iso_dir, "HEAD"],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                raise RuntimeError(
                    "git worktree add failed: %s"
                    % (proc.stderr or proc.stdout).strip()[-300:]
                )
            used_wt = True
        else:
            os.makedirs(iso_dir, exist_ok=True)
        yield iso_dir
    finally:
        cleanup_err = None
        if used_wt and workspace:
            rem = subprocess.run(
                ["git", "-C", workspace, "worktree", "remove", "--force", iso_dir],
                capture_output=True, text=True,
            )
            shutil.rmtree(parent, ignore_errors=True)
            if rem.returncode != 0:
                prn = subprocess.run(["git", "-C", workspace, "worktree", "prune"], capture_output=True, text=True)
                if prn.returncode != 0:
                    cleanup_err = RuntimeError("git worktree cleanup failed: %s" % (prn.stderr or rem.stderr or "").strip()[-200:])
        else:
            shutil.rmtree(parent, ignore_errors=True)
        if cleanup_err is not None and sys.exc_info()[0] is None:
            raise cleanup_err
        if cleanup_err is not None:
            sys.stderr.write("replay-runner: %s\n" % cleanup_err)


def build_harness_cmd(
    harness, mode, skill, skill_path, prompt, iso_dir, prompt_file, model=""
):
    """Build (cmd, stdin_text, prompt_file_text) for the chosen harness."""
    skill_text = ""
    if mode == "with-skill":
        if not skill_path or not os.path.isfile(skill_path):
            raise FileNotFoundError("SKILL.md not found for skill %r" % skill)
        with open(skill_path, encoding="utf-8") as fh:
            skill_text = fh.read()

    if harness == "claude":
        cmd = [
            "claude", "-p",
            "--output-format", "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--disable-slash-commands",
        ]
        if model:
            cmd += ["--model", model]
        if mode == "with-skill":
            cmd += ["--append-system-prompt-file", skill_path]
        return cmd, prompt, None

    if harness == "agy":
        eff = (
            wrap_prompt_with_skill(prompt, skill, skill_text)
            if mode == "with-skill"
            else prompt
        )
        cmd = [
            "agy",
            "--output-format", "json",
            "--disable-slash-commands",
        ]
        if model:
            cmd += ["--model", model]
        cmd.append("-p=" + eff)
        return cmd, None, None

    if harness == "muse":
        eff = (
            wrap_prompt_with_skill(prompt, skill, skill_text)
            if mode == "with-skill"
            else prompt
        )
        cmd = [
            "muse", "exec",
            "--json",
            "--no-session-log",
            "--disable-web-tools",
            "--disable-reminders",
            "--disable-request-user-input",
            "--no-foreign-personal-context",
            "--approval-mode", "never",
            "--trust-workspace",
            "--workspace", iso_dir,
        ]
        if model:
            cmd += ["--model", model]
        cmd += ["--prompt-file", prompt_file]
        return cmd, None, eff

    raise ValueError("unsupported harness: %r" % harness)


def _load_last_json_obj(raw):
    text = (raw or "").strip()
    if not text:
        return {}
    try:
        obj = json.loads(text)
        if isinstance(obj, dict):
            return obj
    except ValueError:
        pass
    for line in reversed(text.splitlines()):
        s = line.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            obj = json.loads(s)
            if isinstance(obj, dict):
                return obj
        except ValueError:
            continue
    return {}


def _parse_claude_output(stdout, wall_time_s):
    text = (stdout or "").strip()
    records = []
    if text:
        try:
            single = json.loads(text)
            if isinstance(single, dict):
                records = [single]
        except ValueError:
            for line in text.splitlines():
                s = line.strip()
                if s.startswith("{"):
                    try:
                        obj = json.loads(s)
                        if isinstance(obj, dict):
                            records.append(obj)
                    except ValueError:
                        continue
    tools, result_rec = [], None
    for rec in records:
        rtype = rec.get("type")
        if rtype == "assistant":
            msg = rec.get("message") if isinstance(rec.get("message"), dict) else {}
            for blk in (msg.get("content") if isinstance(msg.get("content"), list) else []):
                if isinstance(blk, dict) and blk.get("type") == "tool_use" and blk.get("name"):
                    tools.append(str(blk["name"]))
        if rtype == "result" or ("result" in rec and rtype is None):
            result_rec = rec
    if result_rec is None:
        return {
            "transcript": "", "tools": tools, "errors": 1,
            "tokens_in": 0.0, "tokens_out": 0.0, "cache_read_tokens": 0.0,
            "wall_time_s": round(max(0.0, safe_float(wall_time_s, 0.0)), 3), "cost_usd": 0.0,
        }
    usage = result_rec.get("usage") if isinstance(result_rec.get("usage"), dict) else {}
    cache_read = safe_float(usage.get("cache_read_input_tokens"), 0.0)
    cache_create = safe_float(usage.get("cache_creation_input_tokens"), 0.0)
    tin = safe_float(usage.get("input_tokens"), 0.0) + cache_create + cache_read
    tout = safe_float(usage.get("output_tokens"), 0.0)
    dur_ms = safe_float(result_rec.get("duration_api_ms"), 0.0) or safe_float(result_rec.get("duration_ms"), 0.0)
    dur = (dur_ms / 1000.0) if dur_ms > 0 else max(0.0, safe_float(wall_time_s, 0.0))
    if not tools and isinstance(result_rec.get("tools"), list):
        tools = [str(t) for t in result_rec["tools"]]
    return {
        "transcript": str(result_rec.get("result") or ""), "tools": tools,
        "errors": 1 if result_rec.get("is_error") else 0,
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout), "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3),
        "cost_usd": round(max(0.0, safe_float(result_rec.get("total_cost_usd"), 0.0)), 6),
    }


def _parse_agy_output(stdout, wall_time_s):
    data = _load_last_json_obj(stdout)
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    cache_read = safe_float(usage.get("cache_read_tokens"), 0.0)
    tin = safe_float(usage.get("input_tokens"), 0.0) + cache_read
    tout = safe_float(usage.get("output_tokens"), 0.0)
    dur = safe_float(data.get("duration_seconds"), 0.0)
    if dur <= 0:
        dur = max(0.0, safe_float(wall_time_s, 0.0))
    status = str(data.get("status") or "").upper()
    tools = [str(t) for t in data["tools"]] if isinstance(data.get("tools"), list) else []
    return {
        "transcript": str(data.get("response") or data.get("text") or ""),
        "tools": tools,
        "errors": 0 if status == "SUCCESS" else 1,
        "tokens_in": max(0.0, tin),
        "tokens_out": max(0.0, tout),
        "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3),
        "cost_usd": round(max(0.0, safe_float(data.get("cost_usd"), 0.0)), 6),
    }


def _parse_muse_output(stdout, wall_time_s):
    parts, deltas, tools, started = [], [], [], {}
    terminal_text, parsed_any, errors = "", False, 0
    tin = tout = cache_read = cost_usd = dur_total = 0.0

    for line in (stdout or "").splitlines():
        s = line.strip()
        if not s or not s.startswith("{"):
            continue
        try:
            rec = json.loads(s)
        except ValueError:
            continue
        if not isinstance(rec, dict):
            continue
        parsed_any = True
        pl = rec.get("payload") if isinstance(rec.get("payload"), dict) else {}
        inner = pl.get("record") if isinstance(pl.get("record"), dict) else (pl or rec)
        ev = pl.get("event") if isinstance(pl.get("event"), dict) else rec.get("event")
        ev = ev if isinstance(ev, dict) else {}
        pt = str(rec.get("payload_type") or rec.get("type") or rec.get("kind") or "")
        pk = str(pl.get("kind") or "")
        ek = str(ev.get("kind") or ev.get("type") or "")

        if ek == "assistant_message_committed" or pt == "assistant_message_committed":
            txt = ev.get("text") if ek == "assistant_message_committed" else (inner.get("text") or rec.get("text"))
            if isinstance(txt, str) and txt.strip():
                parts.append(txt.strip())
        elif pt == "run.output.delta" or pk == "run_output_delta":
            if isinstance(pl.get("text"), str):
                deltas.append(pl["text"])
        elif pt.startswith("run.terminal.") or pk == "run_terminal":
            if isinstance(pl.get("text"), str) and pl["text"].strip():
                terminal_text = pl["text"].strip()
            term = str(pl.get("terminal") or "")
            if term and term != "completed":
                errors += 1
        elif pt == "run.usage" or pk == "run_usage":
            for m in (pl.get("models") if isinstance(pl.get("models"), list) else []):
                if isinstance(m, dict):
                    cache_read += safe_float(m.get("cached_tokens"), 0.0)
                    tin += safe_float(m.get("input_tokens"), 0.0)
                    tout += safe_float(m.get("output_tokens"), 0.0)
            errors += max(0, safe_int(pl.get("failed_calls"), 0))
        elif pt == "tool_batch.effect.started" or ek == "tool_batch.effect.started":
            src = ev if ek == "tool_batch.effect.started" else inner
            cid = str(src.get("call_id") or "")
            if cid:
                started[cid] = str(src.get("tool_name") or "unknown")
        elif pt == "tool_batch.effect.terminal" or ek == "tool_batch.effect.terminal":
            src = ev if ek == "tool_batch.effect.terminal" else inner
            cid = str(src.get("call_id") or "")
            tools.append(str(src.get("tool_name") or started.get(cid) or "unknown"))
            outcome = src.get("outcome")
            kind = outcome.get("kind") if isinstance(outcome, dict) else outcome
            if kind != "completed":
                errors += 1
        elif ek == "model_completed" or pt == "model_completed":
            src = ev if ek == "model_completed" else inner
            usage = src.get("usage") if isinstance(src.get("usage"), dict) else {}
            cr = safe_float(usage.get("cache_read_tokens"), 0.0) or safe_float(usage.get("cache_read_input_tokens"), 0.0)
            cache_read += cr
            tin += safe_float(usage.get("input_tokens"), 0.0) + cr
            tout += safe_float(usage.get("output_tokens"), 0.0)
            cost_usd += safe_float(src.get("cost_usd"), 0.0) or safe_float(usage.get("cost_usd"), 0.0)
            ds, dm = safe_float(src.get("duration_seconds"), 0.0), safe_float(src.get("duration_ms"), 0.0)
            dur_total += ds if ds > 0 else ((dm / 1000.0) if dm > 0 else 0.0)

    if not parsed_any:
        errors = max(errors, 1)
    transcript = terminal_text or ("\n".join(parts) if parts else "".join(deltas).strip())
    dur = dur_total if dur_total > 0 else max(0.0, safe_float(wall_time_s, 0.0))
    return {
        "transcript": transcript, "tools": tools, "errors": max(0, errors),
        "tokens_in": max(0.0, tin), "tokens_out": max(0.0, tout), "cache_read_tokens": max(0.0, cache_read),
        "wall_time_s": round(max(0.0, dur), 3), "cost_usd": round(max(0.0, cost_usd), 6),
    }


def parse_harness_output(harness, stdout, wall_time_s=0.0):
    """Pure parser from raw harness stdout to canonical trajectory dict."""
    if harness == "claude":
        return _parse_claude_output(stdout, wall_time_s)
    if harness == "agy":
        return _parse_agy_output(stdout, wall_time_s)
    if harness == "muse":
        return _parse_muse_output(stdout, wall_time_s)
    raise ValueError("unsupported harness: %r" % harness)


def _usage():
    print(
        "Usage: replay-runner.sh --mode with-skill|without-skill --skill NAME "
        "--prompt-file FILE --out JSON [--harness claude|agy|muse] [--model ID] "
        "[--workspace PATH] [--kit-dir PATH] [--timeout SEC] [--dry-run-cmd]",
        file=sys.stderr,
    )


def main(argv):
    try:
        opts, _ = getopt.getopt(
            argv[1:], "", [
                "mode=", "skill=", "prompt-file=", "out=", "harness=",
                "model=", "workspace=", "kit-dir=", "timeout=", "dry-run-cmd",
                "help",
            ],
        )
    except getopt.GetoptError as exc:
        _fail(str(exc), 2)

    mode = skill = prompt_file = out = model = workspace = ""
    harness = "claude"
    kit_dir = default_kit_dir()
    timeout = 300
    dry_run = False

    for key, val in opts:
        if key == "--mode":
            mode = val
        elif key == "--skill":
            skill = canon_skill(val)
        elif key == "--prompt-file":
            prompt_file = val
        elif key == "--out":
            out = val
        elif key == "--harness":
            harness = val
        elif key == "--model":
            model = val
        elif key == "--workspace":
            workspace = val
        elif key == "--kit-dir":
            kit_dir = val
        elif key == "--timeout":
            try:
                timeout = int(val)
            except ValueError:
                _fail("--timeout must be an integer", 2)
        elif key == "--dry-run-cmd":
            dry_run = True
        elif key == "--help":
            _usage()
            return

    if mode not in VALID_MODES:
        _fail("--mode must be with-skill or without-skill (got %r)" % mode, 2)
    if harness not in VALID_HARNESSES:
        _fail("--harness must be one of %s (got %r)" % (
            "|".join(VALID_HARNESSES), harness), 2)
    if not skill:
        _fail("--skill is required", 2)
    if timeout < 1:
        _fail("--timeout must be >= 1", 2)

    skill_path = resolve_skill_path(kit_dir, skill) if mode == "with-skill" else ""
    if mode == "with-skill" and not skill_path:
        _fail("SKILL.md not found for skill %r under %s" % (skill, kit_dir), 1)

    if dry_run:
        prompt = ""
        if prompt_file and os.path.isfile(prompt_file):
            with open(prompt_file, encoding="utf-8") as fh:
                prompt = fh.read()
        cmd, _, _ = build_harness_cmd(harness, mode, skill, skill_path, prompt, workspace or "/tmp/replay-workspace", prompt_file or "/tmp/replay-prompt.txt", model)
        print(json.dumps({"harness": harness, "mode": mode, "skill": skill, "skill_path": skill_path, "cmd": cmd}, indent=2))
        return

    if not prompt_file or not out:
        _fail("need --prompt-file and --out (or pass --dry-run-cmd)", 2)
    try:
        with open(prompt_file, encoding="utf-8") as fh:
            prompt = fh.read()
    except OSError as exc:
        _fail("cannot read prompt file %s: %s" % (prompt_file, exc), 1)

    try:
        with isolated_workspace(workspace or None) as iso_dir:
            eff_pf = os.path.join(os.path.dirname(iso_dir), ".replay-eff-prompt.txt")
            if harness == "muse" and mode == "without-skill":
                skills_dir = os.path.join(iso_dir, ".agents", "skills")
                if os.path.lexists(skills_dir):
                    if os.path.isdir(skills_dir) and not os.path.islink(skills_dir):
                        shutil.rmtree(skills_dir)
                    else:
                        os.unlink(skills_dir)
            cmd, stdin_text, pf_text = build_harness_cmd(
                harness, mode, skill, skill_path, prompt, iso_dir, eff_pf, model
            )
            if pf_text is not None:
                with open(eff_pf, "w", encoding="utf-8") as fh:
                    fh.write(pf_text)
            t0 = time.monotonic()
            try:
                proc = subprocess.run(
                    cmd, input=stdin_text, cwd=iso_dir,
                    capture_output=True, text=True, timeout=timeout,
                )
            except subprocess.TimeoutExpired:
                _fail("harness %s timed out after %ds" % (harness, timeout), 1)
            except FileNotFoundError:
                _fail("harness binary not found on PATH: %s" % cmd[0], 1)
            except OSError as exc:
                _fail("harness %s could not execute: %s" % (harness, exc), 1)
            wall = time.monotonic() - t0
            if proc.returncode != 0:
                _fail("harness %s failed (exit %d): %s" % (
                    harness, proc.returncode,
                    (proc.stderr or proc.stdout).strip()[-500:],
                ))
            traj = parse_harness_output(harness, proc.stdout, wall)
    except RuntimeError as exc:
        _fail(str(exc), 1)

    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(traj, fh, indent=1)
        fh.write("\n")


if __name__ == "__main__":
    main(sys.argv)
