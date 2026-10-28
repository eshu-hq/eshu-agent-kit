# AGENTS.md — eshu-agent-kit

This repo owns shared agent material. Product repos own their overlay.

- Keep every skill, agent, rule, and hook portable first. Eshu coupling lives in `skills/eshu/` and named adapters, never in `core/`.
- Keep each file under 500 lines. Split by branch or sequence before a file sprawls.
- One meaning lives in one place. `skills/registry.md` is the rename and migration map; do not restate it elsewhere.
- Write in the repo standard: steps in order, each step ending on a checkable done condition. Reference that only some branches need goes behind a pointer, not inline.
- Never copy kit material into a product repo. Product repos pin a version and run `install.sh`.
- No AI attribution in commits, PRs, or docs. Never push to `main` on an active repo; the initial scaffold commit is the one exception.
