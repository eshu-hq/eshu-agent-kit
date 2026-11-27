# Engineering principles (steering handles)

These eight named handles capture cross-cutting engineering habits that file-path rules cannot trigger. Keep this page as the single source of truth; point to a handle by name instead of restating it across skills.

**Accountability rule:** Only name a principle in a reply or review when you also name the specific choice it changed. A principle cited with no concrete decision behind it is noise.

| Handle | When to apply | Concrete rule and test |
|---|---|---|
| **attack-the-premise** | Two or more fixes sharing one assumption fail the same gate. | Stop before fix #3. Write the shared assumption in one sentence, inspect the failure *distribution* (not just magnitude), and design a direct observation that falsifies it before editing again. |
| **explain-the-number** | Before trusting, reporting, or acting on any latency, throughput, speedup, regression, or eval number. | Answer: *Why not double?* (from a runtime profile/counters, never a code guess), tuning parity, physical/Amdahl limits, zero errors, ≥5 alternating A/B repeats, end-to-end share, and proof the work actually ran. Missing any forces `INCONCLUSIVE`. |
| **build-the-lever** | Any non-trivial sweep, migration, or repeated verification check. | Do the first unit by hand, write a small idempotent script or codemod, and prove it by rerunning on the first unit. Prefer a deterministic script over manual edits or agent fan-out. Artifact test: if no script/tool/check exists, you did not build the lever. |
| **minimize-reader-load** | Shaping or reviewing code that feels hard to trace. | Guard two axes: indirection layers between question and answer, and hidden mutable state held in the reader's head. 30-second test: can a new reader answer *"where does X come from?"* and *"what can change X?"* in under 30s? Collapse single-caller wrappers and single-impl interfaces. |
| **subtract-before-you-add** | Sequencing any addition, refactor, or rewrite. | Delete dead code, unused branches, and speculative validators first, then build on the simpler base. |
| **separate-before-serializing-shared-state** | Concurrent actors or workers might write the same file, row, key, or branch. | Eliminate shared mutation first (per-actor isolation merged on read). *"We need a lock"* is a smell to check first, and prose instructions are never concurrency control. Serialize structurally only when a single shared writer is a real domain invariant. |
| **test-behavior-not-implementation** | Writing, changing, or reviewing any test. | Judge every test with two imagined edits: breaking observable behavior MUST fail it, and changing internals preserving behavior MUST keep it green. Assert typed errors and observable state, not internal call order or error text; pair every "never happens" test with a positive case where it does. |
| **encode-lessons-in-structure** | You catch yourself repeating the same correction or instruction a second time. | Escalate up the hierarchy: Architecture → Types/Lint (with replacement hint) → Behavioral test → Docs last. Once the structural fix prevents the mistake, delete the redundant prose rule. |

## License

Adapted from the `principle-*` skills in `pstack` (MIT License, Copyright (c) poteto).
