# Install and configure

## Installer modes

`./install.sh --help` prints the full reference. The common forms:

```sh
./install.sh --global                    # this machine: skills + agents, all harnesses
./install.sh --global claude codex       # or pick: claude, codex, opencode, muse, cursor, agy, all
./install.sh --agents --global opencode  # agents only, for the picked harnesses
./install.sh --repo /path/to/repo        # skills into one repo + writes its version pin
./install.sh --repo /path/to/repo --aliases manifest.tsv  # harness skill names differ from kit dirs
./install.sh --hooks --repo /path/to/repo  # hook scripts only; wiring stays explicit
./install.sh --hooks --global muse        # machine-wide Muse hooks (explicit opt-in; see hooks/README.md)
./install.sh --hooks --global opencode    # machine-wide OpenCode bridge (explicit opt-in; see hooks/README.md)
./install.sh --rules --repo /path/to/repo  # Claude Code path-scoped rules + rules lint
```

Parts combine in one call: `./install.sh --agents --hooks --repo /path/to/repo`
installs both parts at once (any of `--skills --agents --hooks --rules`,
in any order; bare modes keep their historical defaults). To choose parts
interactively, run `./install.sh --pick [--repo DIR | --global [HARNESS...]]`
and answer the numbered list. Piped answers work the same way
(`printf '1 3\n' | ./install.sh --pick --repo DIR`), and with no terminal
the picker keeps the displayed defaults — every repo part, or skills and
agents globally (global hooks are never a default) — and prints the
equivalent explicit command so the run stays reproducible.

## Uninstall

```sh
./install.sh --uninstall --repo /path/to/repo [--force]
./install.sh --uninstall --global [harness...] [--force]
```

`--uninstall` removes only what the kit provably owns and prints every
removal: symlinks into the kit, generated marker files, byte-identical
copies of kit files, and the matching version pin. User files, modified
copies, and links pointing outside the kit always survive. Skill alias
wrappers (real directories carrying `.kit-alias`) survive too unless
you pass `--force`. Partial modes mirror the install ones
(`--agents`, `--hooks`, `--rules` with `--repo`; `--agents` with
`--global`; `--hooks --global (muse|claude|opencode)`). Uninstalling
global hooks drops the kit-owned tree, except through bare
`--uninstall --global`, which leaves hook registrations in place and
tells you the explicit `--hooks --global` undo instead; your settings
are never edited.
Global uninstall never edits settings that hold your model choices
or hook registrations: the OpenCode config merge, the Muse
`managed_hooks_path` key, and the Claude `settings.json` hook entries
are left untouched, with the manual undo printed instead.

## Skill name aliases

Some repos call their skills by different names than the kit directories
(`eshu-code-review` for the kit's `code-review`). A manifest maps each
harness-visible name to its kit source, one `alias<TAB>source` row per
line; the Eshu manifest at
[templates/repo-overlay/eshu-aliases.tsv](../../templates/repo-overlay/eshu-aliases.tsv)
is the worked example.

With `--aliases`, the installer materializes one wrapper directory per
alias in the repo's `.claude/skills` and `.codex/skills` trees. Each
wrapper carries the alias in its frontmatter `name:`; `.md` files are
copied with alias cross-links, and every other entry is symlinked from
the source. A `.kit-alias` marker records what generated each wrapper.
Renamed manifest sources are skipped for plain `.agents/skills` links,
so no generic twin is ever discoverable next to an alias, while
identical alias==source rows still link there as usual. Re-running
regenerates wrappers whose marker matches; a real file or directory in
the way fails loudly, and a mid-run failure removes this run's fresh
wrappers and restores replaced symlinks. Wrappers whose alias left the
manifest are reported as stale, never deleted automatically.

## How the installer behaves

Straight from [install.sh](../../install.sh):

- Global mode links skills into each picked harness's skill directory
  and writes that harness's agent files. It asks for one model ID per
  agent, plus the OpenCode main model. Pressing Enter keeps the kit
  default from [agents/roles.json](../../agents/roles.json), and so
  does any non-interactive run, so the whole thing stays scriptable.
- On OpenCode, your model choices merge into
  `~/.config/opencode/opencode.jsonc` so they win over per-file
  defaults. The merge tolerates comments and trailing commas. If it
  can't parse the file, it leaves the file untouched and exits nonzero.
  Other harnesses keep the model in each agent file.
- If a skill path already exists and isn't a symlink, the installer
  preserves it and reports the collision. It won't overwrite your copy.
  Resolve those paths by hand if you want the kit version.
- Repo mode never prompts. `--repo` also writes the kit's
  [VERSION](../../VERSION) into the target repo as `.agent-kit-version`.
- For Antigravity (`agy`), global installs link skills into
  `~/.gemini/config/skills` and write subagents to
  `~/.gemini/config/agents` (shared across Antigravity CLI, App, and IDE).
  Repo mode links skills into `.agents/skills` (which Antigravity reads
  natively) and `--agents --repo` links `agy` subagents into `.agy/agents`
  while keeping `.agents/agents` for Muse copies. Because Antigravity also
  scans workspace `.agents/agents/` ahead of `~/.gemini/config/agents/`, a
  repo with Muse agent copies in `.agents/agents/` shadows global `agy`
  agents of the same name until those workspace files are removed or
  pointed at `agy` definitions. For headless runs, `agents/agent-roles.py
  agy-exec ROLE TASK` invokes `agy -p` with the tier's `cli_model`,
  `--sandbox`, and `--mode plan` for read-only roles.

## The bits you configure

`.agent-kit-version` in a product repo is one line: the kit tag that
repo installs. To upgrade, move the pin and re-run the installer.

[agents/roles.json](../../agents/roles.json) holds the 10 role
definitions and the default model per role tier, per harness. If you
change models during a `--global` install, those choices land in each
agent file, or in `~/.config/opencode/opencode.jsonc` on OpenCode.

Hook wiring per harness is in [hooks/README.md](../../hooks/README.md).
