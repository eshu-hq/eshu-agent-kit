---
name: architect
tier: core
description: "Design before code for changes crossing function, module, or package boundaries: check the premise, settle data shapes and ownership first, compare two candidate shapes, and emit a bounded implementation handoff."
---

# Architect

Settle the data shapes, boundaries, and ownership *before* writing production code. Skip this skill for trivial single-function edits inside an existing contract.

Scope: portable `core` layer across all harnesses. This skill is read-only unless step 4 calls for a small scratch prototype outside production code.

## Workflow

1. **Check the premise and trace touched systems.** Read the real callers, owning types, and tests around the change. Verify that the requested mechanism fits the codebase and is not already solved or fighting an existing invariant. If the premise is flawed or obsolete, stop and say so candidly before designing around it. Done when callers, state owners, and boundary constraints are listed from live files.

```bash
git status -sb
rg -n "<entrypoint-or-type>" .
```

2. **Name the data shape and boundaries first.** Define the core domain types, state transitions, and system boundaries before writing control flow:
   - Parse and validate raw external inputs (CLI, config, JSON, network, DB rows) once at boundaries into typed domain values; trust internal types inside.
   - Keep business logic in pure functions behind thin imperative adapters.
   - Subtract dead code, unused branches, and redundant validators before layering new behavior.
   - Separate per-actor mutable state before reaching for locks or serialization. Done when the domain model and boundary contract fit in a short type/interface sketch.

3. **Sketch two distinct candidate shapes and pick by invariants.** Write down at least **two** genuinely different designs (types, signatures, module boundaries, failure modes) instead of locking onto the first idea. Compare them against three invariants:
   - **Single owner per state** (no synchronized shadow state).
   - **One supported way per task** (no parallel legacy/new paths left behind).
   - **Minimum caller knowledge and reader load** (a reader can trace where values come from and what mutates them in under 30 seconds; no single-caller wrappers).
   If a recurring workaround appears in both shapes, redesign as if the requirement had been foundational from day one. Done when one shape is chosen with a clear reason the alternative lost.

4. **Settle empirical forks by running code, not debating.** If the choice between two shapes depends on runtime behavior, library semantics, or performance, build a tiny throwaway scratch prototype outside the production path to observe it directly. Reserve user questions strictly for product or preference choices that an experiment cannot settle. Done when every empirical uncertainty is resolved by an observed run or explicitly recorded.

5. **Emit a bounded implementation handoff.** Output a concise spec covering:
   - goal and smallest change that meets it;
   - chosen data shapes, signatures, and owning files;
   - what gets deleted or migrated in the same wave;
   - concrete observable tests (behavior, negative/positive pairs, boundary errors) and proof commands;
   - explicit non-goals and open risks. Done when an implementer can build and verify the change without guessing contracts.

## Error recovery

- When the existing codebase has contradictory patterns across packages: check git history (`explain` skill) to identify which pattern is current, pick one, and avoid introducing a third way.
- When two candidate shapes remain genuinely tied on engineering tradeoffs: present both options with concrete gains and costs (or run a parallel prototype comparison) instead of silently picking at random.
- When a scratch prototype leaves temporary files behind: keep prototypes in a temp directory (`mktemp -d`) and verify `git status --short` is clean before implementation starts.

## License

Adapted from `architect`, `principle-foundational-thinking`, `principle-model-the-domain`, and `principle-boundary-discipline` in `pstack` (MIT License, Copyright (c) poteto).
