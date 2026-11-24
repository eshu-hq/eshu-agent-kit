# Workflow Runs

Scanner-adjacent workflow detail for `security-scan-gates`.

## Concurrency block for `workflow_run`

For `workflow_run` events GitHub sets `github.ref` to the default branch, so a
naive `${{ github.workflow }}-${{ github.ref }}` concurrency group coalesces
every release image scan into one group and GitHub drops queued runs. Key the
group on the triggering run's head_sha:
`${{ github.workflow }}-${{ github.event_name }}-${{ github.event.workflow_run.head_sha || github.ref }}`.

