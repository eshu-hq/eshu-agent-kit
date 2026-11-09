# Getting started with eshu-agent-kit

You have two ways in. Claude Code users can take the plugin, and
everyone can use [install.sh](../../install.sh). If you're not sure
which fits, start with the installer — it behaves the same on every
harness. At run time the kit needs only `bash` and `python3`.

## Option A: Claude Code plugin

```sh
claude plugin marketplace add eshu-hq/eshu-agent-kit
claude plugin install eshu-agent-kit@eshu-agent-kit
```

Or, from inside Claude Code:
`/plugin install eshu-agent-kit --marketplace eshu-hq/eshu-agent-kit`

That gets you the skills plus automatic hook registration.

## Option B: the installer

```sh
./install.sh --global              # this machine: skills + agents, all harnesses
./install.sh --repo /path/to/repo  # skills into one repo + writes its version pin
```

The installer symlinks, so kit updates flow through when you re-run it.

## Your first run

There's nothing to start afterwards — no service, no port. The kit
takes effect the next time your harness loads skills, roles, or hooks
from the linked paths. Give the agent a task in an eshu-hq repo and it
loads whichever kit skill fits (see [Concepts](../concepts/README.md)).

## Where to go next

- Other modes (`--agents`, `--hooks`, `--rules`) and model prompts:
  [Install and configure](../guides/install-and-configure.md).
- Pinning a product repo: [Pin a product repo](../guides/pin-a-product-repo.md).
- What you actually get, counted: [Reference](../reference/README.md).
