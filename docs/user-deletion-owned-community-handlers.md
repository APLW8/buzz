# Standalone owned-community and request-summary handlers

This slice adds callable Rust components and PostgreSQL-backed tests. It does
**not** enable owned communities in user intake, add a CLI command, dispatch the
new stage from the worker, or change transition rules. Existing user execution
still rejects owned-community inventories. Community deletion's existing CLI,
approval and worker remain unchanged.

## Components

| Component | Entry point | Responsibility |
| --- | --- | --- |
| Community API | `buzz_deletion::community::CommunityDeletionApi::{lookup, submit}` | Read an existing child by community ID; create and prepare one if missing |
| Owned-community handler | `buzz_deletion::user::owned_community::handle` | Check/submit the child and save its last observed state on the user stage |
| Summary handler | `buzz_deletion::user::summary::summarize_request` | Explain the request using a consistent snapshot of user workflow tables |
| Community persistence | `buzz-db/src/store/deletion/submission.rs` | Community-ID lookup and race-safe request admission |
| Waiting persistence | `buzz-db/src/store/entity_deletion/observations.rs` | Save an external observation under the parent lease/generation check |

The community API is an **in-process privileged operator API**, not a new HTTP
endpoint. Its constructor needs the writer `DeletionStore` and the deployment's
`MediaStorage`. It reuses existing catalog inventory, tenant-prefix enumeration,
inventory freezing, and community tables. It needs no Redis connection.
Calling it requires the same operator authority as the existing community CLI.
An approved inventory describes the intended scope; it is not a new mechanism
for authenticating operators or proving current community ownership.

## One owned-community handler invocation

The caller already holds the parent request lease and maintains its heartbeat.
It supplies the full `delete_owned_community` stage row. The handler reloads the
row through `start_stage`, validates its target/community against the approved
parent inventory, and requires `relationship: "owner"`.

1. **Lookup by community ID.** If a request exists, read it without modifying
   its inventory, approval, provenance, or execution state.
2. **Submit only when missing.** Create an operator-origin community request,
   prepare/freeze its inventory, and return its ID and current stage. Concurrent
   submissions converge on the existing community request. A child is never
   approved or executed by this handler.
3. **Persist the observation on the existing user stage.** If child logical
   deletion is complete (`retention_pending` with `completed_at`), save stage
   success. Otherwise return `OwnedCommunityOutcome::Waiting` and save
   `metadata_json.waiting`.

`waiting` contains the child ID, community ID/host, child stage, inventory
digest, last error/block reason, retry deadline, observation time, the reason
for waiting, operator instructions, and command argument arrays. Commands are
data for display; the handler never executes them.

| Last observed child state | User stage outcome | Operator action |
| --- | --- | --- |
| Submitted | Waiting | Finish preparation with the original submitter, then seek approval |
| Inventoried | Waiting | Inspect the frozen inventory and separately approve the child |
| Approved or executing | Waiting | Let community drain run it, or use the existing community `run` command |
| Blocked or aborted | Waiting | Inspect and resolve manually; no automatic replacement or reset |
| Retention pending with completion time | Completed | Logical deletion is complete; retained-copy obligations remain visible in the saved result |

Waiting currently means `status = 'running'` plus `metadata_json.waiting`.
It does not increase retry counts, set an error, finish the row, or change
`is_current`. Success removes the waiting marker and saves `metadata_json.result`.
Neither outcome advances the parent workflow.

If preparation fails after child submission, the child row remains `submitted`.
The error is recorded on the user stage with a retry deadline and propagated.
On the next due invocation, lookup finds that same child and records a wait
with preparation instructions. An operator can resume preparation using the
existing `buzz-admin deletions submit --host ... --requested-by ...` command.
This initial implementation deliberately does not retry preparation through
the lookup API. A crash between creating the child and saving its ID is also
recoverable by community-ID lookup. No derived UUID or new linking table is needed.

Once an ID has been observed, a missing or replaced child is an error requiring
reconciliation. An old lease generation cannot overwrite the user's saved
observation or result. Failures to record a retry also propagate.

## Summarize the request using only our tables

`summarize_request(store, request_id)` reads `entity_deletion_requests`,
`entity_deletion_approvals`, and `entity_deletion_stage_history` through the
existing repeatable-read inspection. It accepts no community API dependency.
It never calls lookup/submit, checks a child table, or changes workflow state.

The report includes:

- Parent target/status, approved inventory and approval evidence.
- Lease owner/generation, heartbeat, retry deadline/count/error, completion time.
- All reached stage rows, including completed results and retention notes.
- Every unfinished stage's ID, name, community, saved inputs, execution state,
  timestamps and error. A running row with an external observation is displayed
  as `waiting_external`; a failed row remains displayed as failed.
- For external waits: the saved child ID/status, observation time, reason,
  next operator action and suggested command arguments. These are explicitly
  **last observed**, not live community status.
- Inventory communities without any stage row yet. This is unreached work, not
  a claim that communities with rows have finished every possible stage.

For example, if A is awaiting approval, B has finished, and C has no stage yet,
the report lists A's saved approval instructions, B's completed result, and C
as not reached. If A completes independently, the summary still shows its saved
wait until A's **owned-community handler** runs again and records completion.
The summary never refreshes A itself.

`complete` requires the parent to be completed and all reached stages to be
completed. An empty unfinished-stage list alone is insufficient: later routing
may still need to create more stages. The summary also works for other external
waits recorded under `metadata_json.waiting`; it does not assume every wait is a
community deletion.

## What remains for workflow integration

The current transition code requires the current stage to complete before
advancing. Do not dispatch this handler from that loop yet: it would repeatedly
visit the unfinished row. A separate integration change must permit proceeding
past external waits, revisit those rows on a later run, and stop with a saved
unfinished request when only external dependencies remain. Summary reporting
must remain read-only. Claim/heartbeat/release stays the worker's responsibility.

## Test this slice

Configure a disposable local PostgreSQL administrator connection as described
in `crates/buzz-db/TESTING.md` (`BUZZ_POSTGRES_ADMIN_URL`, `PGHOST`, `PGPORT`,
`PGUSER`, `PGPASSWORD`; optionally `PG_BIN_DIR`), then run:

```bash
. ./bin/activate-hermit
./scripts/postgres-test-run.sh -p buzz-deletion --lib \
  -E 'test(user::owned_community::postgres_tests)'
```

The runner makes isolated databases per test. Tests use the real stores, API,
handler and summary. A loopback S3 fixture serves empty tenant-prefix listings;
no real object storage is accessed. Tests fixture child terminal state instead
of running destructive community deletion. They cover separate approval,
repeat lookup, stale summaries, child completion, preparation failure recovery,
concurrent admission, aborted requests, stale generations and input mismatch.
Owned inventory is fixture-seeded because real user intake still rejects it.
