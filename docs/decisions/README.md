# Decisions

Architecture decision records (ADRs) for eshu-agent-kit. An ADR captures
one decision, why we made it, and what it costs us.

## Format

One file per decision: `ADR-NNNN-short-title.md`, numbered in order.
Each ADR uses these sections:

- **Status** — proposed, accepted, superseded (link the replacement).
- **Context** — the forces at play, in plain language.
- **Decision** — what we chose.
- **Consequences** — what gets easier, what gets harder.

Keep it short. Link to code and docs instead of restating them.

## Index

| ADR | Decision | Status |
| --- | --- | --- |
| [ADR-0001](ADR-0001-pin-and-link-never-copy.md) | Product repos pin a version and symlink via the installer; never copy kit files | accepted |
