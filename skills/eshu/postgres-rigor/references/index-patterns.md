# Index Patterns

Good and bad index shapes for queue and status tables. Prefer these over
inventing a shape per query.

## Good: partial index on an actionable predicate

```sql
CREATE INDEX fact_work_items_claimable_idx
  ON fact_work_items (queue, claimed_at)
  WHERE status = 'pending';
```

Why: the predicate matches the claim query exactly, and the partial shape
keeps insert/update churn off terminal rows.

## Good: covering INCLUDE that removes measured heap reads

```sql
CREATE INDEX fact_work_items_covering_idx
  ON fact_work_items (queue) INCLUDE (payload_ref, attempt);
```

Why only with measured reads: `EXPLAIN (ANALYZE, BUFFERS)` showed heap fetches
dominating the claim path before this index existed.

## Bad: index on a bare low-cardinality status column

```sql
CREATE INDEX fact_work_items_status_idx ON fact_work_items (status);
```

Why not: the planner will not pick it for a queue that is 90% terminal rows,
and every status transition pays the write.

## Bad: broad JSONB index with no operator case

```sql
CREATE INDEX fact_payload_gin_idx ON facts USING gin (payload);
```

Why not: without an operator, a selectivity number, and a row count, this is
write amplification with no read plan behind it.
