# Install and configure

## Installer modes

```sh
./install.sh --global                    # this machine: skills + agents, all harnesses
./install.sh --global claude codex       # or pick: claude, codex, opencode, muse, cursor, all
./install.sh --agents --global opencode  # agents only, for the picked harnesses
./install.sh --repo /path/to/repo        # skills into one repo + writes its version pin
./install.sh --repo /path/to/repo --aliases manifest.tsv  # harness skill names differ from kit dirs
./install.sh --hooks --repo /path/to/repo  # hook scripts only; wiring stays explicit
./install.sh --rules --repo /path/to/repo  # Claude Code path-scoped rules + rules lint
```

## Skill name aliases

Some repos call their skills by different names than the kit directories
(`eshu-code-review` for the kit's `code-review`). A manifest maps each
harness-visible name to its kit source, one `alias<TAB>source` row per
line; the Eshu manifest at
[templates/repo-overlay/eshu-aliases.tsv](../../templates/repo-overlay/eshu-aliases.tsv)
is the worked example.

With `--aliases`, the installer materializes one wrapper directory per
alias in the repo's `.claude/skills` and `.codex/skills` trees. Each
wrapper carries the alias in its frontmatter `name:`, cross-skill links
rewritten to alias names, and every other entry symlinked from the
source, with a `.kit-alias` marker recording what generated it. Sources
listed in the manifest are skipped for plain `.agents/skills` links, so
no generic twin is ever discoverable next to an alias. Re-running
regenerates wrappers whose marker matches; a real file or directory in
the way fails loudly instead of being overwritten.

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

## The bits you configure

`.agent-kit-version` in a product repo is one line: the kit tag that
repo installs. To upgrade, move the pin and re-run the installer.

[agents/roles.json](../../agents/roles.json) holds the 10 role
definitions and the default model per role tier, per harness. If you
change models during a `--global` install, those choices land in each
agent file, or in `~/.config/opencode/opencode.jsonc` on OpenCode.

Hook wiring per harness is in [hooks/README.md](../../hooks/README.md).
