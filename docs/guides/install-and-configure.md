# Install and configure

## Installer modes

```sh
./install.sh --global                    # this machine: skills + agents, all harnesses
./install.sh --global claude codex       # or pick: claude, codex, opencode, muse, cursor, all
./install.sh --agents --global opencode  # agents only, for the picked harnesses
./install.sh --repo /path/to/repo        # skills into one repo + writes its version pin
./install.sh --hooks --repo /path/to/repo  # hook scripts only; wiring stays explicit
./install.sh --rules --repo /path/to/repo  # Claude Code path-scoped rules + rules lint
```

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
