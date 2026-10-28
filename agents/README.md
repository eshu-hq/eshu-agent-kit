# Agents

Agent definitions live here. Source today: `eshu/.agents/agents/` (plus `.claude/agents/` and `.codex/agents/` mirrors).

Move order: `arbiter` first (it settles undecided design), then `develop`, `review`, `debug`, `perf`, `scan`. Rename the same way as skills: drop `eshu-` from the portable base, keep an `eshu` adapter where the workflow encodes Eshu contracts (promotion gates, graph truth, queue behavior).

Each definition keeps its model routing and tool bounds. No agent downgrades its own model; leaf agents do not dispatch.
