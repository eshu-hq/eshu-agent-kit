# Rules

Path-scoped routing rules for Claude Code. Source: `eshu/.claude/rules/`.
Install with `./install.sh --rules --repo PATH`, which links them into
`PATH/.claude/rules/` and the companion `scripts/claude-rules-lint.sh` into
`PATH/scripts/`.

These files are a **routing layer**. They answer one question: *given the file
Claude just opened, which kit skill must be loaded and which scoped document
must be read?* Each file declares a `paths:` glob in YAML frontmatter; Claude
Code loads the rule when it reads a file matching that glob — not at launch.

They MUST NOT restate rules from `AGENTS.md`. The canon states the rule once;
a rule here points at the skill that carries the detail.

Skill names below are the kit renames (`performance-rigor`,
`correlation-truth`, `folder-doc-keeper`, …). Relative `docs/` links resolve
in the consuming repo checkout until the consumer cutover.

Codex does not read `.claude/rules/`. It gets the same routing from the
per-directory `AGENTS.md` files, which stay exactly as they are.

`scripts/claude-rules-lint.sh` checks the cheap failure first: that every
rule declares `paths:` and every declared glob still matches at least one
tracked file in the repo. Run it after moving or renaming rules or the files
they point at.
