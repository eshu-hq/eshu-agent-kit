#!/usr/bin/env python3
"""Isolated multi-harness runner for replay evals (issues #103, #130).

Runs one prompt against claude, agy, muse, codex, or opencode in an isolated
detached git worktree (or temp dir) with a target SKILL.md either injected
(with-skill) or stripped (without-skill), writing a normalized trajectory JSON.
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
from debrief_common import canon_skill  # noqa: E402
from replay_parsers import (  # noqa: E402,F401
    _parse_agy_output, _parse_claude_output, _parse_codex_output,
    _parse_muse_output, _parse_opencode_output, parse_harness_output,
)

VALID_HARNESSES = ("claude", "agy", "muse", "codex", "opencode")
VALID_MODES = ("with-skill", "without-skill")


def _fail(msg, code=1):
    print("replay-runner: %s" % msg, file=sys.stderr)
    sys.exit(code)


def default_kit_dir():
    return os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    )


def _iter_skill_roots(kit_dir, skills_dirs=None):
    dirs = []
    if skills_dirs:
        dirs.extend(skills_dirs)
    else:
        env = (os.environ.get("DEBRIEF_SKILLS_DIRS") or "").strip()
        if env:
            dirs.extend(p for p in env.split(os.pathsep) if p.strip())
    if not dirs and kit_dir:
        dirs.append(os.path.join(kit_dir, "skills"))
    return [os.path.expanduser(str(d)) for d in dirs if str(d).strip()]


def resolve_skill_path(kit_dir, skill, skills_dirs=None):
    """Locate SKILL.md under explicit --skills-dir roots or <kit>/skills/<layer>/<skill>."""
    name = canon_skill(skill)
    if not name:
        return ""
    for root in _iter_skill_roots(kit_dir, skills_dirs):
        if not os.path.isdir(root):
            continue
        direct = os.path.join(root, name, "SKILL.md")
        if os.path.isfile(direct):
            return direct
        for layer in ("eshu", "core"):
            cand = os.path.join(root, layer, name, "SKILL.md")
            if os.path.isfile(cand):
                return cand
        for entry in sorted(os.listdir(root)):
            cand = os.path.join(root, entry, name, "SKILL.md")
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
    eff = wrap_prompt_with_skill(prompt, skill, skill_text) if mode == "with-skill" else prompt

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
        cmd = ["agy", "--output-format", "json", "--disable-slash-commands"]
        if model:
            cmd += ["--model", model]
        cmd.append("-p=" + eff)
        return cmd, None, None

    if harness == "muse":
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

    if harness == "codex":
        cmd = ["codex", "exec", "--json", "--skip-git-repo-check", "-C", iso_dir]
        if model:
            cmd += ["-m", model]
        cmd.append("-")
        return cmd, eff, None

    if harness == "opencode":
        cmd = ["opencode", "run", "--format", "json", "--archived"]
        if model:
            cmd += ["-m", model]
        cmd.append(eff)
        return cmd, None, None

    raise ValueError("unsupported harness: %r" % harness)


def _usage():
    print(
        "Usage: replay-runner.sh --mode with-skill|without-skill --skill NAME "
        "--prompt-file FILE --out JSON [--harness claude|agy|muse|codex|opencode] [--model ID] "
        "[--workspace PATH] [--kit-dir PATH] [--skills-dir PATH ...] [--timeout SEC] [--dry-run-cmd]",
        file=sys.stderr,
    )


def main(argv):
    try:
        opts, _ = getopt.getopt(
            argv[1:], "", [
                "mode=", "skill=", "prompt-file=", "out=", "harness=",
                "model=", "workspace=", "kit-dir=", "skills-dir=", "timeout=", "dry-run-cmd",
                "help",
            ],
        )
    except getopt.GetoptError as exc:
        _fail(str(exc), 2)

    mode = skill = prompt_file = out = model = workspace = ""
    harness = "claude"
    kit_dir = default_kit_dir()
    skills_dirs = []
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
        elif key == "--skills-dir":
            skills_dirs.append(val)
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
        _fail("--harness must be one of %s (got %r)" % ("|".join(VALID_HARNESSES), harness), 2)
    if not skill:
        _fail("--skill is required", 2)
    if timeout < 1:
        _fail("--timeout must be >= 1", 2)

    skill_path = resolve_skill_path(kit_dir, skill, skills_dirs=skills_dirs or None) if mode == "with-skill" else ""
    if mode == "with-skill" and not skill_path:
        _fail("SKILL.md not found for skill %r under %s" % (skill, skills_dirs or kit_dir), 1)

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
            if harness in ("muse", "codex", "opencode") and mode == "without-skill":
                for rel in ((".agents", "skills"), (".claude", "skills"), (".codex", "skills")):
                    sdir = os.path.join(iso_dir, *rel)
                    if os.path.lexists(sdir):
                        if os.path.isdir(sdir) and not os.path.islink(sdir):
                            shutil.rmtree(sdir)
                        else:
                            os.unlink(sdir)
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
                    harness, proc.returncode, (proc.stderr or proc.stdout).strip()[-500:],
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
