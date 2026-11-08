# Approval wording

An approval request goes in the PR body or status comment, in plain English.
Name three things, then stop.

1. The recommendation: what should happen and why. `[action]` because `[reason]`.
2. The workflow or code checked: the gate, command, or diff behind the
   recommendation. `[workflow-or-command]` showed `[result]`.
3. The arbiter-eshu check: the ruling behind the recommendation, quoted by its
   one-line `RULING:` and `[ruling-id]`.

When the arbiter cannot decide, say so in the same place and recommend the
fallback: `[fallback-approver]` decides `[scope]` by `[deadline]`, and the
change waits for that decision. Never imply an approval that was never given.
