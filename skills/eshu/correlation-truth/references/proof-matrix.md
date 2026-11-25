# Proof Matrix

Checklist for `correlation-truth`: the mandatory positive/negative/ambiguous/graph proof rows plus the repo families to think through. Cover every row on a non-trivial change.

## Mandatory Proof Matrix

Every non-trivial correlation change covers all of these:

- Positive case: the intended service or deployment story materializes.
- Negative case: provenance-only or utility evidence stays non-materialized.
- Ambiguous case: mixed signals do not over-admit or invent truth.
- Graph proof: inspect the canonical nodes and edges directly.
- Query proof: confirm repo, service, and deployment surfaces agree with the
  graph.

Minimum repo families to think through (add one line per new verb or
ecosystem instead of forcing it into these five):

- Service repo with strong deployment evidence
- Deployment or controller repo that must stay utility or provenance-only
- Controller-backed service repo such as Jenkins or GitHub Actions plus image
- Ambiguous multi-unit or multi-Dockerfile repo
- Repo with namespace-like strings that are not real environments

