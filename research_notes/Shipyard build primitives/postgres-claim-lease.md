# PostgreSQL Work-Queue Primitives: `SKIP LOCKED`, Leases, and Fencing

**Scope:** Shipyard's control plane claims work directly from the `deployments` table. There is deliberately **no separate queue table**. Workers are Go services using `pgx`/`pgxpool`.

**Version target:** PostgreSQL 17 and 18. Every claim below is marked where 17 and 18 differ.

**Docs verified against:** PostgreSQL 18 documentation set (current release as of this writing; PostgreSQL 19 is in beta and is *not* covered here).

---

## 1. The crash question, answered precisely first

The premise "a crashed worker's row stays locked and `SKIP LOCKED` hides it forever" is **not how PostgreSQL works**, and building the design around it will produce the wrong conclusions.

### What the docs say

From [13.3.2 Row-Level Locks](https://www.postgresql.org/docs/18/explicit-locking.html):

> "Row-level locks are released at transaction end or during savepoint rollback, just like table-level locks."

> "This prevents them from being locked, modified or deleted by other transactions until the current transaction ends."

From [13.3.1 Table-Level Locks](https://www.postgresql.org/docs/18/explicit-locking.html):

> "Once acquired, a lock is normally held until the end of the transaction."

### The consequences

A row lock is owned by a **transaction**, not by a process, a session, or a connection string. The lock dies when:

| Event | Lock released? |
|---|---|
| `COMMIT` | Yes |
| `ROLLBACK` | Yes |
| Backend process crashes (`SIGKILL`, panic, OOM kill) | Yes — the connection terminates, the backend rolls back its transaction |
| Network partition / client disappears | Yes — the server eventually detects the dead socket and terminates the backend |
| Server process `terminate` | Yes |
| Connection is closed cleanly | Yes |
| **Backend is still alive and holding the transaction open** | **No** |
| Backend is alive but hung in a long `SELECT` or external wait | No — it still holds the lock |

So a **crashed** worker can never leave a row permanently locked. The server releases it at connection teardown, typically in milliseconds to a couple of seconds.

`SKIP LOCKED` hides a row *indefinitely* in exactly one situation: **a live backend still holds the transaction open.** That is a hung transaction, not a crash. Common causes:

- The Go goroutine deadlocked and the code never calls `tx.Rollback()` nor returns the connection to the pool.
- A blocking network call (Docker daemon, cloud API) made *inside* the claim transaction.
- `lock_timeout` / `statement_timeout` are not set, and a worker is blocked on some other row or table.
- A session that did `BEGIN` and then went idle in application code.
- A pooled connection returned to `pgxpool` mid-transaction by a bug, so nobody ever commits it.

The mitigation is not a lease — it is a timeout:

```sql
-- per-database or per-role
ALTER ROLE shipyard_worker SET lock_timeout = '3s';
ALTER ROLE shipyard_worker SET statement_timeout = '30s';
ALTER ROLE shipyard_worker SET idle_in_transaction_session_timeout = '60s';
```

`idle_in_transaction_session_timeout` is called out explicitly in the
[Serializable performance notes](https://www.postgresql.org/docs/18/transaction-iso.html) as a way to "automatically disconnect lingering sessions." That is the setting that actually kills a hung claim transaction.

### So why do you still need a lease?

Because of the **second** failure mode, which is not a lock problem at all.

The claim transaction commits. The worker now does long external work — building a container image, calling a cloud API, running a shell script — that takes minutes. During that window:

- There is **no row lock**. Other workers can see the row as unblocked.
- If the worker is killed, nothing in PostgreSQL notices. There is no transaction to roll back.
- The row is stuck in `running` with an owner that no longer exists, and nothing will ever reclaim it.

**The lease exists to make the *committed claim* recoverable, not to make the *lock* recoverable.** The lock handles concurrent attempts to claim. The lease handles a claim whose owner died after commit. These are orthogonal and you need both.

Summary:

| Hazard | Caused by | Handled by |
|---|---|---|
| Two workers claim the same row | Concurrent `SELECT ... FOR UPDATE` | Row lock + `SKIP LOCKED` |
| Row invisible because a transaction never ends | Live-but-hung backend | `idle_in_transaction_session_timeout`, `lock_timeout` |
| Row owned by a dead worker forever | Crash *after* claim commit | **Lease expiry + generation fencing** |
| Stale worker overwrites a reclaimed row's state | Lease expired, new owner took over | **Compare-and-set on `lease_generation`** |

---

## 2. Schema

```sql
CREATE TYPE deployment_status AS ENUM (
    'queued',
    'running',
    'succeeded',
    'failed',
    'canceled'
);

CREATE TABLE deployments (
    id               bigserial   PRIMARY KEY,
    status           deployment_status NOT NULL DEFAULT 'queued',

    -- Scheduling
    priority         integer     NOT NULL DEFAULT 100,
    queued_at        timestamptz NOT NULL DEFAULT now(),

    -- Lease / fencing
    lease_owner      text,
    lease_expires_at timestamptz,
    lease_generation bigint      NOT NULL DEFAULT 0,

    -- Bookkeeping
    attempts         integer     NOT NULL DEFAULT 0,
    last_error       text,
    started_at       timestamptz,
    finished_at      timestamptz,
    updated_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lease_fields_consistent CHECK (
        (lease_owner IS NULL AND lease_expires_at IS NULL)
     OR (lease_owner IS NOT NULL AND lease_expires_at IS NOT NULL)
    )
);
```

### Why every field is needed

- `lease_owner` — *who*. A free-text identity (`hostname:pid:uuid`) that is unique per worker incarnation, so a restarted process never impersonates its predecessor.
- `lease_expires_at` — *how long*. Compared with `now()`. Set generously: several multiples of your heartbeat interval, so one missed heartbeat does not trigger a reclaim.
- `lease_generation` — the **fencing token**. A monotonically increasing `bigint`, bumped on every claim. This is the single most important column in the table. It is what makes stale writes impossible.

The `CHECK` constraint enforces that owner and expiry are set together, so you can never have a row that looks leased but has no deadline.

### Do **not** make `slot_busy` a generated column over `now()`

It is tempting to write:

```sql
-- WRONG. This fails to create.
slot_busy boolean GENERATED ALWAYS AS (lease_expires_at > now()) STORED
```

Two independent reasons, both fatal:

1. **Generated column expressions must be immutable.** From [5.4 Generated Columns](https://www.postgresql.org/docs/18/ddl-generated-columns.html): "The generation expression can only use immutable functions." `now()` is `STABLE`, not `IMMUTABLE`. The same rule governs [index predicates](https://www.postgresql.org/docs/18/sql-createindex.html): all functions used in an index definition must be immutable.
2. Even if it were allowed, a stored value computed at write time cannot answer "is this lease expired *now*", because it is frozen at the moment of the last write.

The same immutability rule kills the natural partial index `WHERE lease_expires_at > now()`. **Design around it with two separate partial indexes instead** — see §4.

### 17 vs 18: the `STORED`/`VIRTUAL` default flipped

From the PostgreSQL 18 generated-columns docs:

> "There are two kinds of generated columns: stored and virtual. ... A generated column is by default of the virtual kind. Use the keywords VIRTUAL or STORED to make the choice explicit."

**In PostgreSQL 17 and earlier, all generated columns are `STORED` and there is no `VIRTUAL` keyword.** In 18, bare `GENERATED ALWAYS AS (...)` means `VIRTUAL`, which is a different storage behavior.

**Rule for Shipyard:** always write `STORED` explicitly. Never rely on the default. This keeps the schema identical across 17 and 18.

### Generated columns and `BEFORE` triggers do not mix

> "Generated columns are, conceptually, updated after BEFORE triggers have run. Therefore, changes made to base columns in a BEFORE trigger will be reflected in generated columns. But conversely, **it is not allowed to access generated columns in BEFORE triggers.**"

Any trigger-based fencing in §7 must therefore reference **base** columns (`lease_owner`, `lease_generation`), never a generated column. This is a second independent reason not to introduce `slot_busy`.

---

## 3. The claim

### The `WITH`-trap (read this before writing the query)

From [SELECT, The Locking Clause](https://www.postgresql.org/docs/18/sql-select.html):

> "these clauses do not apply to WITH queries referenced by the primary query. **If you want row locking to occur within a WITH query, specify a locking clause within the WITH query.**"

So this is **wrong** — the `FOR UPDATE` is ignored, no row is locked, and two workers will happily claim the same row:

```sql
-- WRONG: outer FOR UPDATE is ignored for the CTE.
WITH ready AS (
    SELECT id FROM deployments WHERE status = 'queued'
)
SELECT id FROM ready FOR UPDATE SKIP LOCKED;
```

This is **right** — the locking clause lives *inside* the CTE:

```sql
-- RIGHT
WITH ready AS (
    SELECT id
    FROM deployments
    WHERE status = 'queued'
    ORDER BY priority, queued_at
    LIMIT 10
    FOR UPDATE SKIP LOCKED
)
SELECT ...;
```

### What `SKIP LOCKED` actually guarantees

From the same page:

> "With `SKIP LOCKED`, any selected rows that cannot be immediately locked are skipped. Skipping locked rows provides an inconsistent view of the data, so this is not suitable for general purpose work, but can be used to avoid lock contention with multiple consumers accessing a queue-like table."

> "`NOWAIT` and `SKIP LOCKED` apply only to the row-level lock(s) — the required `ROW SHARE` table-level lock is still taken in the ordinary way."

> "With the `WITH TIES` mode ... `ORDER BY` is mandatory in this case, and `SKIP LOCKED` is not allowed."

> "When a locking clause appears at the top level of a `SELECT` query, the rows that are locked are exactly those that are returned by the query... In addition, rows that satisfied the query conditions as of the query snapshot will be locked, although they will not be returned if they were updated after the snapshot and no longer satisfy the query conditions. If a `LIMIT` is used, **locking stops once enough rows have been returned to satisfy the limit**."

The `LIMIT` behavior is the load-bearing detail: the executor stops walking the index as soon as it has `LIMIT` rows, so a busy table does not pay for locking the whole queue.

### The claim statement

```sql
WITH claimed AS (
    SELECT id
    FROM deployments
    WHERE status = 'queued'
      AND lease_owner IS NULL
    ORDER BY priority, queued_at
    LIMIT $1
    FOR UPDATE SKIP LOCKED
)
UPDATE deployments d
SET status           = 'running',
    lease_owner      = $2,
    lease_expires_at = now() + $3::interval,
    lease_generation = d.lease_generation + 1,
    attempts         = d.attempts + 1,
    started_at       = now(),
    finished_at      = NULL,
    last_error       = NULL,
    updated_at       = now()
FROM claimed
WHERE d.id = claimed.id
RETURNING d.id,
          d.lease_generation,
          d.lease_expires_at,
          d.attempts;
```

Everything happens in **one transaction**. The `UPDATE` holds the row locks taken by the CTE; the `RETURNING` gives you the freshly minted `lease_generation`, which is your fencing token for every subsequent write.

### Claiming with lease reclaim in the same statement

Expired leases need reclaiming too. Combine both candidate sets with `OR` so the planner can `BitmapOr` the two partial indexes from §4:

```sql
WITH claimed AS (
    SELECT id
    FROM deployments
    WHERE (status = 'queued'  AND lease_owner IS NULL)
       OR (status = 'running' AND lease_expires_at <= now())
    ORDER BY priority, queued_at
    LIMIT $1
    FOR UPDATE SKIP LOCKED
)
UPDATE deployments d
SET status           = 'running',
    lease_owner      = $2,
    lease_expires_at = now() + $3::interval,
    lease_generation = d.lease_generation + 1,
    attempts         = d.attempts + 1,
    updated_at       = now()
FROM claimed
WHERE d.id = claimed.id
RETURNING d.id, d.lease_generation, d.lease_expires_at, d.attempts;
```

If the two candidate sets need *different* `LIMIT`s (e.g. "always take one fresh row, then opportunistically take expired ones"), run them as two separate statements in one transaction rather than a `UNION ALL` CTE. Locking-clause behavior inside `UNION ALL` branches is not something to rely on.

**Reclaiming is a correctness event, not just housekeeping.** When you take over an expired `running` row, the previous owner may still be alive and still executing. That is exactly what `lease_generation` fencing (§6) exists to neutralize. Do not reclaim without it.

### `NOWAIT` vs `SKIP LOCKED`

Use `NOWAIT` when you want to *know* about contention:

> "With `NOWAIT`, the statement reports an error, rather than waiting, if a selected row cannot be locked immediately."

For a worker loop, `SKIP LOCKED` is correct: an empty result is a normal, cheap "nothing to do right now."

For the claim path, `SKIP LOCKED` is the right choice. Pair it with `lock_timeout` anyway (§1) so a table-level lock conflict (a concurrent `ALTER TABLE`, a `VACUUM FULL`) cannot park a worker indefinitely.

---

## 4. Indexes

Two partial indexes with **immutable** predicates, because `now()` is not allowed in an index predicate.

```sql
-- (a) Never-claimed work.
CREATE INDEX deployments_unclaimed_idx
    ON deployments (priority, queued_at, id)
    WHERE status = 'queued' AND lease_owner IS NULL;

-- (b) Expired-lease reclaim.
CREATE INDEX deployments_expired_idx
    ON deployments (lease_expires_at, id)
    WHERE status = 'running' AND lease_expires_at IS NOT NULL;
```

- (a) matches the first branch of the claim predicate exactly, so the index is used as a scan in `(priority, queued_at)` order and `SKIP LOCKED` can walk it and stop at `LIMIT`.
- (b) matches the second branch and is ordered so the most-overdue lease is found first.

The two indexes stay small because each excludes the other half of the queue. From [11.8 Partial Indexes](https://www.postgresql.org/docs/18/indexes-partial.html): the index "contains entries only for those table rows that satisfy the predicate," which "will also speed up many table update operations because the index does not need to be updated in all cases."

### Two things that silently break a partial index

From the same page:

> "PostgreSQL does not have a sophisticated theorem prover that can recognize mathematically equivalent expressions that are written in different forms. ... the predicate condition must exactly match part of the query's `WHERE` condition or the index will not be recognized as usable."

1. **Textual form must match.** `WHERE status = 'queued' AND lease_owner IS NULL` in the query will not use an index defined as `WHERE lease_owner IS NULL AND status = 'queued'`. Keep the predicates in the DDL and in the query literally identical, and put them in a shared SQL constant.

2. **Parameterized queries never use partial indexes.** The docs state it directly:

   > "Matching takes place at query planning time, not at run time. As a result, parameterized query clauses do not work with a partial index. For example a prepared query with a parameter might specify 'x < ?' which will never imply 'x < 2' for all possible values of the parameter."

   This bites when you write `WHERE status = $1` — `$1` is a runtime parameter, so the planner cannot prove `status = 'queued'` and the partial index is silently ignored. **Always inline enum literals in the claim query; never bind them as parameters.** Bind only the `LIMIT` and the interval, which do not appear in the predicate.

Verify with `EXPLAIN` after writing the query. A silent index miss under a busy queue is the single most common performance bug in this pattern.

### Do not fan out one partial index per state

The docs explicitly warn against `WHERE category = 1`, `WHERE category = 2`, ... : "Almost certainly, you'll be better off with a single non-partial index." Two indexes here is fine because the predicates are *disjoint by construction* and both are hot. A dozen would not be.

---

## 5. Heartbeat / lease renewal

Run this on a ticker at roughly TTL/3, from a **separate** connection or at minimum never from inside another open transaction on the same pooled conn.

```sql
UPDATE deployments
SET lease_expires_at = now() + $3::interval,
    updated_at       = now()
WHERE id              = $1
  AND lease_generation = $2
  AND lease_owner      = $4
  AND lease_expires_at > now()          -- the guard; see below
RETURNING lease_expires_at;
```

**The `lease_expires_at > now()` guard is not decoration.** Consider a worker whose event loop stalled: its lease lapsed, a reaper already handed the row to a new owner, and the stalled worker wakes up and tries to renew. Without the guard:

- `lease_generation` and `lease_owner` would not match, so the `UPDATE` matches zero rows. The worker correctly sees failure.

With the guard you additionally protect the narrower window where the reaper has *not yet* run but the lease has already lapsed. Renewing there would resurrect a lease that is nominally expired, and two workers would briefly believe they own the row. The guard makes renewal fail closed in every window.

**Rule: a renewal that affects 0 rows means you have lost the lease. Stop all work on that deployment immediately.** Do not retry, do not "re-claim" it — another worker owns it now.

### Choosing TTL and heartbeat

```
lease TTL     = 3 × heartbeat interval
heartbeat     = TTL / 3
```

This tolerates two consecutive missed heartbeats before a reclaim. Going more aggressive trades reclaims of live work for slower detection of dead workers. Two missed heartbeats is the standard compromise.

---

## 6. Fenced writes

Every state write a worker makes must be conditional on it still owning the lease.

```sql
UPDATE deployments
SET status      = 'succeeded',
    finished_at = now(),
    last_error  = NULL,
    updated_at  = now(),
    lease_owner = NULL,
    lease_expires_at = NULL
WHERE id               = $1
  AND lease_generation = $2
  AND lease_owner      = $3;
```

- **1 row updated** → you own it. Done.
- **0 rows updated** → your lease was reclaimed. Another worker owns this deployment now. **Discard your result and do not write anything else.** Never retry, never force, never write without the `WHERE` clause.

The `lease_generation` check is the load-bearing part. `lease_owner` alone is not enough: a worker that restarts could regenerate the same identity, and a lease could be reclaimed and re-leased to the same owner string. The monotonic generation cannot repeat.

The same conditional predicate applies to failure paths:

```sql
UPDATE deployments
SET status      = 'failed',
    last_error  = $4,
    finished_at = now(),
    updated_at  = now(),
    lease_owner = NULL,
    lease_expires_at = NULL
WHERE id               = $1
  AND lease_generation = $2
  AND lease_owner      = $3;
```

Make this a helper, not a pattern you retype. A single forgotten `AND lease_generation = $2` anywhere reintroduces the stale-write bug.

---

## 7. Trigger-based fencing with a GUC

If you want a hard database-level guarantee that no unleased writer can mutate a running deployment, use a custom GUC to carry the worker's identity into the database and check it in a trigger.

```sql
CREATE OR REPLACE FUNCTION shipyard_fence_deployment()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    actor_id   text;
    actor_gen  bigint;
BEGIN
    -- Only guard writes to a deployment that is currently leased.
    IF NEW.lease_owner IS NULL THEN
        RETURN NEW;
    END IF;

    actor_id  := current_setting('shipyard.worker_id', true);
    actor_gen := current_setting('shipyard.lease_generation', true);

    IF actor_id IS NULL THEN
        RAISE EXCEPTION
            'deployment % is leased to % but no worker context is set',
            NEW.id, NEW.lease_owner
            USING ERRCODE = '23514';
    END IF;

    IF actor_gen IS NULL OR actor_gen::bigint <> NEW.lease_generation THEN
        RAISE EXCEPTION
            'lease generation mismatch on deployment %: context has %, row has %',
            NEW.id, actor_gen, NEW.lease_generation
            USING ERRCODE = '40001';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER deployments_fence
    BEFORE UPDATE ON deployments
    FOR EACH ROW
    EXECUTE FUNCTION shipyard_fence_deployment();
```

Note the trigger reads **base** columns only (`NEW.lease_owner`, `NEW.lease_generation`) — accessing generated columns in a `BEFORE` trigger is not allowed (§2).

### `current_setting` with the two-argument form

From [9.28.1 Configuration Settings Functions](https://www.postgresql.org/docs/18/functions-admin.html):

> `current_setting ( setting_name text [, missing_ok boolean ] ) → text`
>
> "`current_setting` throws an error unless `missing_ok` is supplied and is true (in which case `NULL` is returned)."

Always pass `true`. Without it, the first `UPDATE` from any un-fenced code path (a migration, a `psql` session, an admin tool) dies with `unrecognized configuration parameter` rather than a readable error.

### Use `set_config(..., true)`, not session-level `SET`

From [SET](https://www.postgresql.org/docs/18/sql-set.html):

> "`SET` only affects the value used by the current session. If `SET` (or equivalently `SET SESSION`) is issued within a transaction that is later aborted, the effects of the `SET` command disappear when the transaction is rolled back. Once the surrounding transaction is committed, the effects will persist until the end of the session."

> "The effects of `SET LOCAL` last only till the end of the current transaction, whether committed or not."

This matters more than it looks, because of `pgxpool`. See §9.

**The GUC must be set inside the same transaction as the write.** Use:

```sql
SELECT set_config('shipyard.worker_id',        $3,        true);
SELECT set_config('shipyard.lease_generation', $2::text,  true);
```

The third argument `true` means transaction-local: it is discarded at `COMMIT` or `ROLLBACK`, so a pooled connection is never left with a stale worker identity. This is the safe default and it is exactly what `SET LOCAL` does.

Dotted two-part names like `shipyard.worker_id` are treated as custom GUC placeholders. This behavior is long-standing (since 9.2) and identical in 17 and 18, but it is not documented in the `SET` reference page — if you rely on it, add a startup assertion that `set_config` returns the value you set, so a future version change surfaces immediately.

### Is the trigger worth it?

The GUC trigger is defense in depth, not the primary mechanism. Keep §6's explicit `WHERE lease_generation = $2` on every write regardless. Reasons:

- The trigger cannot see work done outside a transaction-local GUC set, so a correctly-written worker that sets the GUC on a different connection would be blocked (correctly, but confusingly).
- A trigger adds planning/execution overhead to *every* update on `deployments`, including the API's own status writes from other services.
- The 0-rows-affected check in Go is unambiguous and self-documenting.

Use the trigger if you want the database to be a genuine backstop against a newly written service forgetting the fencing predicate. Do not use it as a substitute.

---

## 8. Isolation levels and retry

### `READ COMMITTED` (the default, and the right choice here)

From [13.2.1](https://www.postgresql.org/docs/18/transaction-iso.html):

> "UPDATE, DELETE, `SELECT FOR UPDATE`, and `SELECT FOR SHARE` commands behave the same as SELECT in terms of searching for target rows: they will only find target rows that were committed as of the command start time. However, such a target row might have already been updated (or deleted or locked) by another concurrent transaction by the time it is found. ... The search condition of the command (the `WHERE` clause) is **re-evaluated** to see if the updated version of the row still matches the search condition. If so, the second updater proceeds with its operation using the updated version of the row. In the case of `SELECT FOR UPDATE` and `SELECT FOR SHARE`, this means it is the **updated version** of the row that is locked and returned to the client."

This re-evaluation is exactly the safety net you want. If worker A commits a claim between worker B's snapshot and B's lock attempt, B's `WHERE status = 'queued' AND lease_owner IS NULL` is re-checked against A's new row, no longer matches, and the row is **dropped from B's result** rather than double-claimed. `READ COMMITTED` is not a weaker guarantee here; the re-check is the mechanism that makes `SKIP LOCKED` correct.

### `REPEATABLE READ` and `SERIALIZABLE` will fail your claim

From [13.2.2](https://www.postgresql.org/docs/18/transaction-iso.html):

> "But if the first updater **commits** (and actually updated or deleted the row, not just locked it) then the repeatable read transaction will be rolled back with the message `ERROR: could not serialize access due to concurrent update`"

And from [13.3.2](https://www.postgresql.org/docs/18/explicit-locking.html):

> "Within a `REPEATABLE READ` or `SERIALIZABLE` transaction, however, an error will be thrown if a row to be locked has changed since the transaction started."

**Consequence:** under `REPEATABLE READ`, two workers claiming concurrently is not "one gets it" — it is "one succeeds and the other aborts with SQLSTATE `40001`." That turns normal contention into exception-driven control flow and inflates your transaction retry rate. The same applies at `SERIALIZABLE`, which additionally monitors for read/write dependency anomalies that a queue claim has no business triggering.

**Use `READ COMMITTED` for claim transactions.** If the rest of Shipyard wants a stronger level for multi-row consistency work, use it there and keep claims separate.

### Deadlocks

From [13.3.4](https://www.postgresql.org/docs/18/explicit-locking.html):

> "The use of explicit locking can increase the likelihood of deadlocks... PostgreSQL automatically detects deadlock situations and resolves them by aborting one of the transactions involved."

> "So long as no deadlock situation is detected, a transaction seeking either a table-level or row-level lock will **wait indefinitely** for conflicting locks to be released."

Two sources of deadlock in this design:

1. **Cross-deployment lock ordering.** If a worker claims deployment A and then tries to touch deployment B while another worker does B-then-A, that is a classic cycle. The fix is the docs' advice: "acquire locks on multiple objects in a consistent order."
2. **A deployment that depends on another deployment.** If `deployments.parent_id` exists and workers may lock both, sort by `id` before locking.

SQLSTATE for a deadlock is `40P01`. **Retry it** — same as `40001`, it is a transient, expected condition. But prefer to avoid it by ordering.

### What to retry in Go

| SQLSTATE | Meaning | Action |
|---|---|---|
| `40001` | serialization failure | Retry the whole transaction, with jittered backoff |
| `40P01` | deadlock detected | Retry the whole transaction, with jittered backoff |
| `55P03` | `lock_not_available` (from `NOWAIT`) | Do not retry immediately; back off |
| `57014` | `query_canceled` (from `statement_timeout`) | Investigate; the claim is too slow or blocked |
| `23514` | `check_violation` (your `CHECK` or the fence trigger) | Bug — do not retry |
| `23505` | `unique_violation` | Bug, or expected under a partial unique index |

Both `40001` and `40P01` require retrying **the entire transaction**, not the individual statement. Use a `pgx` transaction closure so the retry boundary is unambiguous.

---

## 9. pgx and connection pinning

From the [pgxpool documentation](https://pkg.go.dev/github.com/jackc/pgx/v5/pgxpool):

> "Acquire returns a connection (Conn) from the Pool."

The pool methods — `Exec`, `Query`, `QueryRow`, `Begin`, `CopyFrom`, `SendBatch` — each check out an arbitrary available connection and return it when done. Two consequences:

### Session-level state does not survive a pool call

```go
// WRONG. The SET runs on one connection; the UPDATE may run on another.
pool.Exec(ctx, "SET shipyard.worker_id = 'worker-1'")
pool.Exec(ctx, "UPDATE deployments SET ...")
```

This is exactly why §7 says to use `set_config(..., true)` inside the transaction. Transaction-local settings travel with the transaction, which is the unit the pool actually guarantees.

### Session-level advisory locks require `Acquire`

A session-level advisory lock belongs to a *connection*, not to a pool. You must pin the connection for the entire window you hold the lock:

```go
conn, err := pool.Acquire(ctx)
if err != nil {
    return err
}
defer conn.Release()

if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", key); err != nil {
    return err
}
defer func() {
    // Best effort; the lock is also released when the session ends.
    _, _ = conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", key)
}()

// All work that relies on the lock must go through `conn`, not `pool`.
```

**You almost certainly do not need this.** See §10.

### Do not hold a transaction across external work

Every rule above assumes the claim transaction is short: lock, update, commit. Holding a transaction open across a Docker build or a cloud API call is the single most damaging mistake available in this design. It holds row locks, blocks `VACUUM`, retains dead tuples, and — combined with the crash analysis in §1 — is what actually creates the "row stays locked" hazard people attribute to crashes.

---

## 10. Advisory locks vs. leases vs. `FOR UPDATE`

Pick one. Do not stack all three "for safety".

From [13.3.5 Advisory Locks](https://www.postgresql.org/docs/18/explicit-locking.html):

> "Advisory locks are useful for locking strategies that are an awkward fit for the MVCC model. ... While a flag stored in a table could be used for the same purpose, **advisory locks are faster, avoid table bloat, and are automatically cleaned up by the server at the end of the session.**"

That third clause is the whole story. An advisory lock is a **session-scoped mutex with crash safety built in** — the server drops it when the connection dies. It has no TTL, no owner column, no reaper, and no persistence.

| Need | Right tool |
|---|---|
| Prevent two workers claiming the same row *right now* | `SELECT ... FOR UPDATE SKIP LOCKED` in the claim transaction |
| Recover a row whose owner died after committing the claim | **Lease** (`lease_expires_at` + reaper) |
| Guarantee a stale worker cannot write | **`lease_generation` fencing** |
| Serialize something outside the database entirely (e.g. one cloud account per region) | **Advisory lock**, with a pinned connection |
| Serialize multi-statement work across several tables that must not interleave | **Advisory lock**, transaction-scoped |

**Advisory locks cannot be your recovery mechanism**, because they vanish with the session — the exact moment you need to reclaim. And they cannot be your fencing mechanism, because there is nothing to compare a stale write against. Conversely, a lease is strictly heavier than an advisory lock, so do not use a lease to express "only one worker at a time" when the work is short and entirely in-database.

### If you do use transaction-level advisory locks

```sql
SELECT pg_try_advisory_xact_lock($1);  -- bigint key
SELECT pg_try_advisory_xact_lock($1, $2);  -- two int keys
```

From [9.28.10](https://www.postgresql.org/docs/18/functions-admin.html):

> "Locks can be either shared or exclusive... Locks can be taken at session level (so that they are held until released or the session ends) or at transaction level (so that they are held until the current transaction ends; **there is no provision for manual release**)."

Key properties:

- **Two key spaces.** `(bigint)` and `(int, int)` do not overlap. Pick one convention and never mix, or you will hold locks you think you are not.
- **Transaction-level locks are the right default.** Released automatically at `COMMIT`/`ROLLBACK`; nothing to leak.
- **Session-level locks survive `ROLLBACK`.** From §13.3.5: "a lock acquired during a transaction that is later rolled back will still be held following the rollback." This surprises people and leaks locks.
- **Session-level locks stack.** "A lock can be acquired multiple times by its owning process; for each completed lock request there must be a corresponding unlock request." Acquire once, unlock once.
- **Re-entrancy is silent.** "If a session already holds a given advisory lock, additional requests by it will always succeed." You cannot use an advisory lock to detect a self-deadlock.
- **Capacity is finite.** Both advisory and regular locks live in shared memory sized by `max_locks_per_transaction` and `max_connections`; the docs put the practical ceiling at "typically in the tens to hundreds of thousands." Exhausting it means **the server cannot grant any locks at all.**

### The `LIMIT` ordering hazard

From §13.3.5:

> "In certain cases using advisory locking methods, especially in queries involving explicit ordering and LIMIT clauses, care must be taken to control the locks acquired because of the order in which SQL expressions are evaluated."

```sql
SELECT pg_advisory_lock(id) FROM foo WHERE id = 12345;              -- ok
SELECT pg_advisory_lock(id) FROM foo WHERE id > 12345 LIMIT 100;   -- danger!
SELECT pg_advisory_lock(q.id) FROM (
  SELECT id FROM foo WHERE id > 12345 LIMIT 100
) q;                                                                  -- ok
```

The middle form can lock more rows than the application expects, and since session-level advisory locks have no timeout, "dangling" locks persist until session end. If you must call an advisory-lock function over a result set, force the subquery form. This is the same class of bug as the `WITH`-trap in §3, and it is why `SELECT ... FOR UPDATE SKIP LOCKED` — which the planner sequences correctly with `LIMIT` — is the better tool anyway.

---

## 11. `LISTEN` / `NOTIFY`

### The core correctness fact

From [NOTIFY](https://www.postgresql.org/docs/18/sql-notify.html):

> "if a `NOTIFY` is executed inside a transaction, the notify events are **not delivered until and unless the transaction is committed**."

> "if a listening session receives a notification signal while it is within a transaction, the notification event will not be delivered to its connected client until just after the transaction is completed (either committed or aborted)."

So notifications are commit-ordered and never lie about rolled-back work. That makes `NOTIFY` safe to use as a wake-up hint.

### The hard constraint: notifications are not durable

`LISTEN`/`NOTIFY` is not a queue. There is no replay: a worker that is not currently `LISTEN`ing, or whose connection drops, **does not receive the notification and never will**. The payload of each event is also in the notification, not in a log.

**Therefore every worker must have a periodic poll regardless of `NOTIFY`.** `NOTIFY` is a latency optimization that converts a 1-second poll into a ~1-millisecond wake-up. It is never the only trigger. A design where work is processed only in response to `NOTIFY` will silently lose jobs.

### Shipyard pattern

```sql
-- Producer, inside the transaction that creates the work.
SELECT pg_notify('shipyard_work', $1::text);   -- $1 = deployment id
```

```sql
-- Consumer setup, once, on a dedicated connection held for the process lifetime.
conn, err := pool.Acquire(ctx)
defer conn.Release()
_, err = conn.Exec(ctx, "LISTEN shipyard_work")
```

Use a **dedicated connection** for `LISTEN`. Under `pgxpool`, a connection can be returned to the pool and handed to someone else, and while it sits idle in the pool its notifications are simply not being read. Holding one connection exclusively for listening is cheap and correct.

On wake-up, the worker should:
1. **Ignore notifications whose PID equals its own backend PID** — that is its own commit bouncing back. The docs suggest exactly this: "When they are the same, the notification event is one's own work bouncing back, and can be ignored."
2. Deduplicate and coalesce. A burst of 1000 inserts produces 1000 notifications; the worker should claim a batch (`LIMIT 16`) and then loop until the claim returns zero rows.

### Limits to know

- **Payload:** "In the default configuration it must be shorter than 8000 bytes." Send the deployment id and let the worker read the row. If `max_notify_queue_pages` is not raised, `NOTIFY` **fails at commit** when the queue fills, which surfaces as an otherwise inexplicable commit failure.
- **No cleanup under a long transaction:** "no cleanup can take place if a session executes `LISTEN` and then enters a transaction for a very long time." This is a concrete argument for the dedicated listener connection *not* opening transactions at all, consistent with the docs' own closing advice: "applications using `NOTIFY` for real-time signaling should try to keep their transactions short."
- **Monitor it:** `SELECT pg_notification_queue_usage();` returns the fraction of the queue currently occupied.
- **No two-phase commit:** "A transaction that has executed `NOTIFY` cannot be prepared for two-phase commit."
- **Deduplication within a transaction:** "If the same channel name is signaled multiple times with identical payload strings within the same transaction, only one instance of the notification event is delivered." If your payload is just the deployment id, that is a feature. Do not rely on notification *count* as a work counter.
- `pg_notify(text, text)` is the function form and, unlike the `NOTIFY` statement, accepts non-constant channel names.

---

## 12. Enum evolution

Adding a status to the `deployment_status` enum:

```sql
ALTER TYPE deployment_status ADD VALUE IF NOT EXISTS 'cancelled' AFTER 'failed';
```

### The transaction restriction

From [ALTER TYPE](https://www.postgresql.org/docs/18/sql-altertype.html):

> "If `ALTER TYPE ... ADD VALUE` (the form that adds a new value to an enum type) is executed inside a transaction block, **the new value cannot be used until after the transaction has been committed.**"

Identical in 17 and 18. This is a genuine operational constraint, and it has bitten many migration systems.

**Implications:**

1. **A migration that adds a value and then uses it in the same transaction fails.** Split it: one transaction for `ALTER TYPE ... ADD VALUE`, commit, then a second transaction for the data migration that references the new label.
2. **Many migration tools wrap the whole migration in one transaction by default.** Disable that for enum migrations, or the migration will fail in a way that looks like a permissions or type error.
3. **This is a forward-only operation.** PostgreSQL enums cannot have a value removed. If you need to retire a status, map it to a terminal state and leave the label in place. Renaming is possible via `ALTER TYPE ... RENAME VALUE`, but note that "an error will occur if the specified value is not present or the new name is already present," and any application or trigger referencing the old label breaks.

### Consider a check constraint instead

For a small, stable, four-to-eight-value status set, a `text` column with a `CHECK` constraint is arguably the better fit:

```sql
status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','running','succeeded','failed','canceled'))
```

`CHECK` constraints are trivially evolvable — add a value to the list, done — with no transaction restriction and no OID ordering concerns. The trade-off is that you lose the enum's compact storage and lose a hard type-level guarantee; nothing stops a code path from writing a status outside the list except the `CHECK` itself, which is normally sufficient.

The PostgreSQL docs' own note on enum sort-order performance is worth weighing: "Comparisons involving an added enum value will sometimes be slower than comparisons involving only original members of the enum type."

Shipyard's status set is small and mostly terminal-forever. **`CHECK` on `text` is the better default here; use an enum only if you need the type identity.**

---

## 13. Index and schema migration notes

When adding the lease columns to an existing `deployments` table that already holds rows:

```sql
-- Adding lease_owner, lease_expires_at, lease_generation is all NULL-able and
-- has no default other than lease_generation, so this is fast and non-blocking.
ALTER TABLE deployments
    ADD COLUMN lease_owner      text,
    ADD COLUMN lease_expires_at timestamptz,
    ADD COLUMN lease_generation bigint NOT NULL DEFAULT 0;
```

Notes:

- The `NOT NULL DEFAULT 0` on `lease_generation` is a metadata-only default in modern PostgreSQL, so no table rewrite occurs.
- Do **not** add the `lease_fields_consistent` `CHECK` in the same migration unless every existing row already satisfies it. Existing rows will have `lease_owner IS NULL AND lease_expires_at IS NULL`, which satisfies the constraint, so it is safe — but verify with `SELECT count(*) FROM deployments WHERE (lease_owner IS NULL) <> (lease_expires_at IS NULL);` before adding it.
- Build the partial indexes with `CREATE INDEX CONCURRENTLY`. It cannot run inside a transaction block, and it takes a weaker lock that does not block reads or writes. It is also slower and can leave an invalid index on failure — check `pg_index.indisvalid` if a build is interrupted.
- Existing rows that were `running` when the migration ran have no lease. The first claim pass will pick them up only if your reclaim branch treats `lease_expires_at IS NULL` as expired. Handle that explicitly rather than letting them sit forever:
  ```sql
  WHERE (status = 'running' AND (lease_expires_at <= now() OR lease_expires_at IS NULL))
  ```
  Note this makes the reclaim branch no longer textually identical to the partial index predicate in §4, so that branch will not use the index. Reclaim the stragglers in a one-off backfill, then keep the strict predicate in steady state.

---

## 14. Complete worker loop

Putting it together, in Go, with the parts that are easy to get wrong called out.

```go
func (w *Worker) runOnce(ctx context.Context) (int, error) {
    const leaseTTL = 90 * time.Second
    batchSize := 16

    workerID := w.identity // stable-unique per process incarnation
    claimed, err := w.claimBatch(ctx, workerID, leaseTTL, batchSize)
    if err != nil {
        return 0, err
    }
    if len(claimed) == 0 {
        return 0, nil
    }

    var wg sync.WaitGroup
    for _, c := range claimed {
        wg.Add(1)
        go func(c Claimed) {
            defer wg.Done()
            // Heartbeat stops the moment the lease is lost.
            hbCtx, stopHB := context.WithCancel(ctx)
            lost := make(chan struct{})
            go w.heartbeat(hbCtx, c, leaseTTL/3, stopHB, lost)

            err := w.execute(hbCtx, c)

            stopHB()
            select {
            case <-lost:
                // Lease was reclaimed. Result is discarded, unconditionally.
                w.log.Warn("lease lost, discarding result",
                    "deployment_id", c.ID, "generation", c.Generation)
            default:
                w.finish(ctx, c, err) // fenced write; 0 rows => silently dropped
            }
        }(c)
    }
    wg.Wait()
    return len(claimed), nil
}
```

The claim, with transient-error retry:

```go
func (w *Worker) claimBatch(ctx context.Context, owner string, ttl time.Duration, n int) ([]Claimed, error) {
    const claimSQL = `
        WITH claimed AS (
            SELECT id
            FROM deployments
            WHERE (status = 'queued'  AND lease_owner IS NULL)
               OR (status = 'running' AND lease_expires_at <= now())
            ORDER BY priority, queued_at
            LIMIT $1
            FOR UPDATE SKIP LOCKED
        )
        UPDATE deployments d
        SET status           = 'running',
            lease_owner      = $2,
            lease_expires_at = now() + $3::interval,
            lease_generation = d.lease_generation + 1,
            attempts         = d.attempts + 1,
            started_at       = now(),
            finished_at      = NULL,
            last_error       = NULL,
            updated_at       = now()
        FROM claimed
        WHERE d.id = claimed.id
        RETURNING d.id, d.lease_generation, d.lease_expires_at, d.attempts`

    return withTxRetry(ctx, w.pool, func(tx pgx.Tx) ([]Claimed, error) {
        rows, err := tx.Query(ctx, claimSQL, n, owner, ttl)
        if err != nil {
            return nil, err
        }
        out, err := pgx.CollectRows(rows, pgx.RowToStructByName[Claimed])
        return out, err
    })
}
```

### Retry helper: do not use `pgconn.SafeToRetry`

This is a real trap. `pgconn.SafeToRetry(err)` reports whether a **connection** failed before data reached the server, so the driver can transparently retry on a fresh socket. It returns `true` for a closed connection or a failure to acquire the connection lock. It is **not** about transaction-level SQLSTATEs.

`40001` and `40P01` are `*pgconn.PgError` values with a `Code` field. Match on the code:

```go
func isTransient(err error) bool {
    var pgErr *pgconn.PgError
    if !errors.As(err, &pgErr) {
        return false
    }
    switch pgErr.Code {
    case "40001", // serialization_failure
        "40P01", // deadlock_detected
        "55P03": // lock_not_available
        return true
    }
    return false
}

func withTxRetry(ctx context.Context, pool *pgxpool.Pool, fn func(pgx.Tx) error) error {
    const maxAttempts = 5
    var backoff = 10 * time.Millisecond

    for attempt := 1; ; attempt++ {
        err := pgx.BeginFunc(ctx, pool, fn) // commits on nil, rolls back otherwise
        if err == nil {
            return nil
        }
        if !isTransient(err) || attempt >= maxAttempts {
            return err
        }
        // Jitter. Without it, every worker retries in lockstep and the
        // same pair collides again immediately.
        j := time.Duration(rand.Int63n(int64(backoff)))
        select {
        case <-time.After(backoff + j):
        case <-ctx.Done():
            return ctx.Err()
        }
        backoff *= 2
    }
}
```

Two details that matter:

- **`pgx.BeginFunc` is the retry boundary.** It begins, runs the closure, commits on `nil`, and rolls back otherwise. Retrying means re-running the whole closure against a **fresh transaction** — never a partially-applied one.
- **Jitter is mandatory, not polish.** `40001` on a claim is caused by a specific concurrent writer. Deterministic backoff re-collides with that same writer. Exponential backoff without jitter synchronises all workers into the next collision.

Also note `pgx.BeginFunc` takes an interface satisfied by both `*pgx.Conn` and `*pgxpool.Pool`. If you need a session-level advisory lock (§10), acquire a `*pgxpool.Conn` first and pass the pool to `BeginFunc`; the advisory lock stays on the pinned connection while the claim transaction borrows any available one.

Hard rules this encodes:

1. **One transaction, one pinned connection** for claim → commit. No external calls inside it.
2. **`LIMIT` is a bound parameter; the enum literals are inline** — required for the partial index (§4).
3. **`FOR UPDATE SKIP LOCKED` is inside the CTE** (§3).
4. **Every write carries `lease_generation`** (§6).
5. **A lost lease discards the result**; it never retries the write.
6. **The loop always polls**, whether or not `NOTIFY` woke it (§11).
7. **The heartbeat lives on a different connection** than any long transaction (§5).

---

## 15. Trap summary

| # | Trap | Reality |
|---|---|---|
| 1 | "A crashed worker leaves the row locked forever" | False. Locks die with the transaction. Only a live-but-hung backend holds one. Fix with `idle_in_transaction_session_timeout`, not a lease. |
| 2 | The lease exists to recover locks | No. The lease recovers *committed claims* whose owner died. Orthogonal to locking. |
| 3 | `WITH cte AS (SELECT ...) SELECT ... FOR UPDATE SKIP LOCKED` | The locking clause is ignored for `WITH` queries. Put it inside the CTE. |
| 4 | `GENERATED ALWAYS AS (lease_expires_at > now())` | Rejected. Generated expressions must be immutable; `now()` is `STABLE`. |
| 5 | `CREATE INDEX ... WHERE lease_expires_at > now()` | Rejected. Index expressions must be immutable. Use two partial indexes with static predicates. |
| 6 | `WHERE status = $1` in the claim | Parameterized clauses never match a partial index predicate. Inline the enum literal. |
| 7 | Index predicate written in a different textual order than the query | Never matches. Keep them byte-identical. |
| 8 | `GENERATED ALWAYS AS (...)` with no `STORED`/`VIRTUAL` | `STORED` in ≤17, **`VIRTUAL` in 18**. Always write `STORED` explicitly. |
| 9 | Accessing a generated column in a `BEFORE` trigger | Not allowed. Fence on base columns. |
| 10 | `REPEATABLE READ` for claim transactions | Contention becomes `40001` aborts instead of clean skips. Use `READ COMMITTED`. |
| 11 | Session-level `SET` then a separate `pool.Exec` | May run on a different connection. Use `set_config(..., true)` inside the transaction. |
| 12 | `current_setting('x')` without the second arg | Throws if unset. Always pass `true`. |
| 13 | Session-level advisory lock as the recovery mechanism | It vanishes with the session, which is exactly when you need recovery. |
| 14 | Session-level advisory locks released by `ROLLBACK` | They are **not**. They survive rollback and leak. Prefer `_xact_` variants. |
| 15 | One `pg_advisory_unlock` for N acquires | Locks stack. N acquires need N unlocks. |
| 16 | `pg_advisory_lock(id)` over a query with `LIMIT` | May lock more rows than expected, permanently. Force the subquery form. |
| 17 | `SELECT pg_advisory_lock(...)` expecting a foreign key namespace | `(bigint)` and `(int,int)` are **disjoint** key spaces. Mixing them silently under-locks. |
| 18 | `pg_try_advisory_lock` to detect your own deadlock | Re-entrant. It succeeds if you already hold it. |
| 19 | Processing work only on `NOTIFY` | Notifications are not durable and are not replayed. Always poll. |
| 20 | `LISTEN` on a pooled connection | It can be handed to another worker while idle. Use a dedicated connection. |
| 21 | Assuming notification count == work count | Identical payloads in one transaction are folded into one event. |
| 22 | Long transaction on the `LISTEN` connection | Blocks notification queue cleanup; can cause `NOTIFY` to fail at commit. |
| 23 | `ALTER TYPE ... ADD VALUE` and using the value in the same transaction | Fails. Split into two transactions; disable transactional migrations for enum changes. |
| 24 | Trying to remove an enum value | Not possible. Enums are forward-only; use `RENAME VALUE` or a `CHECK` constraint. |
| 25 | Holding the claim transaction across a Docker build | Holds row locks, blocks `VACUUM`, and is the actual cause of "stuck" rows. |
| 26 | `lock_timeout` / `statement_timeout` unset | A blocking conflict parks a worker forever. Set both per-role. |
| 27 | Writing status without the `lease_generation` guard | One forgotten predicate reintroduces the stale-write bug. Wrap it in a helper. |
| 28 | `CREATE INDEX CONCURRENTLY` inside a migration transaction | Rejected. It must run outside a transaction block. |
| 29 | Using `pgconn.SafeToRetry(err)` to detect `40001`/`40P01` | Wrong function. It is for *connection* failures, not transaction-level SQLSTATEs. Match `(*pgconn.PgError).Code`. |
| 30 | Deterministic exponential backoff on `40001` | Re-collides with the same concurrent writer every time. Jitter is mandatory. |
| 31 | Retrying a claim statement rather than the whole transaction | Leaves a half-applied transaction. `pgx.BeginFunc` makes the closure the retry boundary. |

---

## 16. Sources

All pages verified against the **PostgreSQL 18** documentation set. The docs use `/current/` as an alias; `/18/` is pinned explicitly here to avoid silently reading 19-beta text later. Statements about 17 are called out inline where 17 and 18 differ.

- [SELECT — The Locking Clause, `SKIP LOCKED`, `LIMIT` interaction, `WITH` caveat](https://www.postgresql.org/docs/18/sql-select.html)
- [13.3 Explicit Locking — row/table lock lifetime, deadlocks, advisory locks](https://www.postgresql.org/docs/18/explicit-locking.html)
- [13.2 Transaction Isolation — `READ COMMITTED` re-evaluation, `REPEATABLE READ` failures, SSI](https://www.postgresql.org/docs/18/transaction-iso.html)
- [5.4 Generated Columns — immutability, `STORED`/`VIRTUAL`, `BEFORE` trigger restriction](https://www.postgresql.org/docs/18/ddl-generated-columns.html)
- [11.8 Partial Indexes — predicate matching, parameterized-query caveat, anti-fan-out](https://www.postgresql.org/docs/18/indexes-partial.html)
- [CREATE INDEX — index expression immutability requirement](https://www.postgresql.org/docs/18/sql-createindex.html)
- [ALTER TYPE — `ADD VALUE` transaction restriction, forward-only enums](https://www.postgresql.org/docs/18/sql-altertype.html)
- [NOTIFY — commit ordering, payload limit, queue exhaustion, 2PC incompatibility](https://www.postgresql.org/docs/18/sql-notify.html)
- [SET — `SET` vs `SET LOCAL` lifetime and rollback behavior](https://www.postgresql.org/docs/18/sql-set.html)
- [9.28.1 Configuration Settings Functions — `current_setting(name, missing_ok)`](https://www.postgresql.org/docs/18/functions-admin.html)
- [9.28.10 Advisory Lock Functions — key spaces, stacking, session vs transaction scope](https://www.postgresql.org/docs/18/functions-admin.html)
- [9.27 System Information Functions — `pg_notification_queue_usage()`](https://www.postgresql.org/docs/18/functions-info.html)
- [pgxpool — `Acquire`, and the pool methods that check out arbitrary connections](https://pkg.go.dev/github.com/jackc/pgx/v5/pgxpool)
- [pgx error handling — `pgconn.SafeToRetry` semantics, `PgError.Code`, `pgx.BeginFunc`](https://github.com/jackc/pgx/blob/master/_autodocs/errors.md)
- [pgqueuer — a production `SKIP LOCKED` implementation, for comparison](https://github.com/janbjorge/pgqueuer/blob/main/docs/reference/skip-locked.md)
