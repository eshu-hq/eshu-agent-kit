# ADR-0001: Pin and link, never copy

## Status

Accepted. Recorded in [AGENTS.md](../../AGENTS.md) ("Never copy kit
material into a product repo. Product repos pin a version and run
`install.sh`.") and in the [skill registry](../../skills/registry.md)
layer rule.

## Context

Every eshu-hq repo needs the same skills, roles, hooks, and rules.
Copying them per repo drifted: fixes landed in one repo and never
reached the others, and nobody knew which copy was current.

## Decision

One kit repo owns the shared material and ships it by SemVer tag
([VERSION](../../VERSION)). A product repo records the tag it uses in
`.agent-kit-version`, keeps a small overlay, and runs `install.sh`,
which symlinks the kit in. Upgrading means moving the pin and
re-running the installer.

## Consequences

- A fix lands once here; repos pick it up deliberately, by pin.
- "Which copy?" always has an answer: the pin file.
- The installer must never overwrite a non-symlink path — it preserves
  and reports collisions instead (see
  [Install and configure](../guides/install-and-configure.md)).
