# Shipyard — Backend (Go control plane) internal design

Scope: **mechanics inside the Go process**. The public REST surface is owned by
api-designer; Postgres indexes are owned by postgres-pro. Neither is specified
here, but both are assumed to exist and both constrain this design.

Target: weeks, not months. Simplicity is a hard requirement and "production
grade" is also a requirement. Every decision below is annotated with *why*, and
with what it costs.

---

## 1. Process architecture

### 1.1 One binary, one process, by default

`cmd/shipyard` is the composition root. It has a `--role` flag:

| role | contents |
|---|---|
| `all` (default) | API + orchestrator + log streams. One process. |
| `api` | HTTP only. No engine. Talks to the queue table. |
| `engine` | Engine only. No HTTP. Same binary, flag differs. |

Single process is the default because it is a solo project: the API and the
engine share a failure domain, a config surface, a deployment, and a log stream
anyway. Splitting them buys nothing today and costs a second systemd unit, a
second config file, and a cross-host debugging story. But the **boundary is
enforced at the package level**, so `-role=api` on a second host is a flag
change, not a refactor. That is the point.

### 1.2 Package layout

```
cmd/shipyard/main.go            composition root; wiring only, no logic
cmd/shipyardctl/main.go         CLI: `enroll`, `reconcile`, `deploy`, `migrate`

internal/
  domain/                       entities, lifecycle state machine, error codes
  port/                         the interfaces that separate API from engine
  config/                       config load + fail-fast validation
  telemetry/                    slog, metrics registry, trace id

  store/
    postgres/                   pgx implementation of port repositories
    migrations/                 embedded *.sql, applied in order, tracked

  engine/                       the deployment execution engine  (no net/http)
    queue.go                    job claiming, backoff, lease reaping
    worker.go                   the run loop, global semaphore
    serverlock.go               per-server serialization
    runner.go                   executes one deployment, step by step
    steps/                      clone.go build.go config.go swap.go start.go verify.go
    reconciler/                 startup + periodic reconciliation walk
    circuit.go                  per-project deploy circuit breaker

  executor/                     the Bash contract: Request -> SSH command + framing
  ssh/                          client, session pool, exec, host-key TOFU store
  logpipe/                      build-log pump, ring buffer, disk spool, fan-out
  journal/                      journalctl cursor feed, refcounted multiplexer
  health/                       probe types, health window, rollback trigger
  nginx/                        server{} block renderer + fail-closed install

  api/                          chi router, middleware, handlers   (no engine import)
```

### 1.3 The dependency rule that cannot be violated

Three tiers, enforced mechanically:

```
tier 0   domain, port          import NOTHING internal. stdlib only.
tier 1   config, telemetry     may import tier 0.
tier 2   everything else       may import tiers 0-1.
         api  ─────► port ◄───── engine        (both depend on port, not each other)
```

`domain` and `port` are the *only* packages that define shared vocabulary, and
they are pure. No pgx, no context-handling oddities, no HTTP types. That is what
lets the state machine be unit-tested with zero infrastructure and lets the API
be tested against a fake store with zero Postgres.

Enforcement is a CI script, not a code review convention:

```bash
# scripts/check-deps.sh
set -euo pipefail
fail=0
# tier 0 must not import any internal package
for p in $(go list ./internal/domain/... ./internal/port/...); do
  if go list -deps "$p" | grep -q 'shipyard/internal/'; then
    echo "VIOLATION: $p imports an internal package"; fail=1
  fi
done
# api and engine must not import each other
if go list -deps ./internal/api/... | grep -q 'shipyard/internal/engine'; then
  echo "VIOLATION: api imports engine"; fail=1
fi
if go list -deps ./internal/engine/... | grep -q 'shipyard/internal/api'; then
  echo "VIOLATION: engine imports api"; fail=1
fi
exit $fail
```

A grep-gate is crude, and it is the right amount of crude: it is 12 lines,
impossible to forget, and it turns "we agreed not to do that" into something the
build enforces.

### 1.4 How HTTP and the orchestrator communicate

**Through the database. Not a channel, not an in-process call.**

```go
// internal/api/deployments.go — the entire hand-off
tx, err := pool.Begin(ctx)
release, err := pgxrepo.NextReleaseNumber(ctx, tx, projectID)   // allocated ONCE
dep,  err := pgxrepo.CreateDeployment(ctx, tx, CreateDeploymentParams{...})
_,  err = pgxrepo.EnqueueJob(ctx, tx, dep.ID, dep.ServerID, dep.ProjectID)
return tx.Commit(ctx)     // 202 Accepted
```

All three happen in one transaction, so the invariant *a Deployment always has
exactly one job* is enforced by atomicity rather than by application logic. There
is no window in which a Deployment exists with no job, and no window in which a
job exists for a nonexistent Deployment.

The engine discovers the row by polling (§2.1). It never receives a channel
message, never sees a goroutine handoff, and holds no in-memory pointer to
in-flight work.

**Why the database and not a channel:** a channel is a lossy, in-memory queue.
If the process dies after the HTTP 202 and before the worker picks it up, the
work is gone and the UI shows a PENDING deployment that will never run — a
silent, unrecoverable failure with no record that the request was ever
accepted. A row in Postgres is durable, inspectable, and makes the backlog a
`SELECT`. The ~5ms of poll latency is irrelevant against a 3-minute deploy.

`port` interface, defined in `internal/port`:

```go
type JobStore interface {
    // Enqueue must be called inside the same tx that created the Deployment.
    EnqueueJob(ctx context.Context, tx pgx.Tx, d Deployment) (JobID, error)
    ClaimJob(ctx context.Context, owner string, lease time.Duration) (*Job, error)
    HeartbeatJob(ctx context.Context, jobID JobID, owner string) error
    CompleteJob(ctx context.Context, jobID JobID, owner string, err error) error
    // ReapJob returns jobs whose lease expired — the worker died.
    ReapJob(ctx context.Context, olderThan time.Duration) ([]Job, error)
}
```

The engine gets `port.JobStore`; the API gets `port.DeploymentStore`. Neither
knows pgx except through the constructor in `store/postgres`.

---

## 2. The deployment execution engine

### 2.1 How work is claimed: a queue table plus a poller

**Recommendation: a `deployment_jobs` table polled with
`SELECT ... FOR UPDATE SKIP LOCKED`, inside the single default binary.**

```sql
CREATE TABLE deployment_jobs (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  deployment_id    uuid NOT NULL UNIQUE REFERENCES deployments(id) ON DELETE CASCADE,
  server_id        uuid NOT NULL,
  project_id       uuid NOT NULL,
  state            text NOT NULL DEFAULT 'pending'
                     CHECK (state IN ('pending','leased','retry','done','dead')),
  priority         int  NOT NULL DEFAULT 100,
  attempts         int  NOT NULL DEFAULT 0,
  max_attempts     int  NOT NULL DEFAULT 3,
  available_at     timestamptz NOT NULL DEFAULT now(),
  lease_owner      text,
  lease_expires_at timestamptz,
  last_error_code  text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX jobs_claimable ON deployment_jobs (available_at, priority, id)
  WHERE state IN ('pending','retry');
```

The claim is a single statement, so two workers (or the same worker twice) can
never take the same job:

```sql
UPDATE deployment_jobs SET
    state             = 'leased',
    lease_owner       = $1,
    lease_expires_at  = now() + $2::interval,
    attempts          = attempts + 1
WHERE id = (
    SELECT id FROM deployment_jobs
    WHERE state IN ('pending','retry')
      AND available_at <= now()
    ORDER BY priority, id
    FOR UPDATE SKIP LOCKED
    LIMIT 1
)
RETURNING *;
```

`engine/worker.go` loop:

```go
func (w *Worker) Run(ctx context.Context) error {
    for {
        if w.sem.Acquire(ctx, 1) != nil { return ctx.Err() }
        job, err := w.jobs.ClaimJob(ctx, w.owner, w.lease)
        if err != nil { w.sem.Release(1); return err }      // db down: back off hard
        if job == nil { w.sem.Release(1); w.backoff() ; continue }
        go func() {
            defer w.sem.Release(1)
            w.execute(ctx, job)          // §2.2–2.5
        }()
    }
}
```

Rejected alternatives, and why:

| Option | Why not |
|---|---|
| In-process goroutine pool triggered by the HTTP handler | Loses work on restart. No record of intent. |
| Postgres `LISTEN/NOTIFY` | Correct for latency, wrong for durability. A missed notify means an abandoned deployment. Would need both. |
| A separate worker binary from day one | Two systemd units, two configs, two deploys, zero benefit for one operator. Revisit when `--role` makes it a flag. |
| Redis / NATS / Kafka / Temporal | Explicitly out of scope, and a Postgres table is genuinely sufficient at this scale. The extra component would be the largest reliability risk in the system. |

The one cost worth naming: polling adds latency. Mitigate with a 250ms poll
interval and a `pg_notify` *hint* that sets an atomic flag to wake the loop early.
The hint is an optimization; correctness never depends on it being delivered.

### 2.2 Concurrency control

Two limits, and two different primitives for two different questions.

| Limit | Default | Question it answers |
|---|---|---|
| `MaxConcurrentDeploys` | 4 | How many can the control plane handle at once? |
| `MaxConcurrentPerServer` | **1** | What may touch one host concurrently? |

**Global** is a plain in-process `chan struct{}` semaphore in `engine/worker.go`.
It is fine to lose on crash: after a restart, in-memory concurrency is
irrelevant because the queue is empty until workers re-claim. No persistence
needed.

**Per-server** must be correct across control-plane restarts and across multiple
instances. Three candidates:

| Primitive | Verdict |
|---|---|
| `sync.Mutex` in a `map[uuid.UUID]*sync.Mutex` | **Rejected.** Correct for exactly one process, silently wrong the moment a second control plane exists — including during a rolling restart, which is precisely when you cannot afford a wrong answer. |
| `servers.is_deploying boolean` column | **Rejected.** Needs crash cleanup, and crash cleanup is the code that will be wrong at 2am. It is also not a lock: two workers can both read `false`. |
| **Postgres session advisory lock on a dedicated connection** | **Chosen.** |

```go
// internal/engine/serverlock.go
const advisoryNamespaceServer = 0x5A17

// AcquireServer takes a *session-scoped* advisory lock on a connection that is
// checked out of the pool for the whole deployment. It must not be the same
// connection the rest of the deployment borrows, or the lock is a no-op.
func (m *Locks) AcquireServer(ctx context.Context, serverID uuid.UUID) (*ServerLock, error) {
    conn, err := m.pool.Acquire(ctx)          // DEDICATED connection, held entire deploy
    if err != nil { return nil, fmt.Errorf("acquire conn: %w", err) }

    var ok bool
    q := `SELECT pg_try_advisory_lock($1, hashtextextended($2::text, 0))`
    if err := conn.QueryRow(ctx, q, advisoryNamespaceServer, serverID).Scan(&ok); err != nil {
        conn.Release()
        return nil, fmt.Errorf("try advisory lock: %w", err)
    }
    if !ok { conn.Release(); return nil, errServerBusy }

    return &ServerLock{conn: conn, serverID: serverID}, nil
}

func (l *ServerLock) Release() {
    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    // Best-effort; the lock is also released when the connection dies.
    _, _ = l.conn.Exec(ctx, `SELECT pg_advisory_unlock($1, hashtextextended($2::text, 0))`,
        advisoryNamespaceServer, l.serverID)
    l.conn.Release()
}
```

Three notes that matter:

1. **`pg_try_advisory_lock`, not `pg_advisory_xact_lock`.** A transaction-scoped
   lock dies at commit. A deploy takes minutes; holding an open transaction that
   long pins a connection, blocks `VACUUM` on the row, and would serialize the
   pool. Wrong tool.
2. **The lock is computed by the database** (`hashtextextended` on the uuid
   text) so every instance agrees on the key without a coordination protocol.
3. **`try`, not blocking.** A busy server does not queue inside Postgres; the
   job returns to `pending` with `available_at = now() + 5s`. Contention
   becomes visible as queue depth rather than as a pile of blocked goroutines.

Connection budget: at most `MaxConcurrentDeploys` connections are held by locks
at once (default 4). Document `MaxPoolConns >= MaxConcurrentDeploys + 10` and
enforce it in `config.Validate()`.

**Per-project** needs no primitive: a project maps to servers, and each server
already serializes. A circuit breaker (§6) is the only per-project gate.

**`try` failing is not a failure** — it requeues with a 5s backoff, and
`SERVER_BUSY` is never a terminal state for a deployment.

### 2.3 Crash recovery and reconciliation

**The governing principle: the host is the source of truth about reality; the
database is the source of truth about intent. Recovery never infers progress
from state — it asks the host, then converges on the desired end state.**

That means every step is *convergent* (running it twice reaches the same place
as running it once) rather than *sequential* (needing a remembered cursor). This
one design choice is what makes recovery tractable.

#### 2.3.1 Detecting orphans

A deployment is orphaned when its worker is gone. Three independent signals, any
one of which is sufficient:

```sql
-- (a) dead lease: the worker stopped heartbeating
SELECT j.* FROM deployment_jobs j
WHERE j.state = 'leased' AND j.lease_expires_at < now();

-- (b) stale heartbeat: the worker is alive but wedged (hung build, OOM-killed thread)
SELECT * FROM deployments
WHERE status IN ('cloning','building','configuring','starting','healthy')
  AND heartbeat_at < now() - interval '120 seconds';
```

The running step calls `HeartbeatJob` every 15s (well inside the 30s lease).
(2) is what catches a wedged-but-alive process, which (1) alone would wait out
a renewed lease for.

#### 2.3.2 Asking the host

`internal/engine/reconciler/inspect.go` runs a **read-only** verb on the target.
It never mutates anything, so it is always safe to run, repeatedly, on a host
in an unknown state.

```bash
# agent.sh inspect <b64-json>
# Emits exactly one NDJSON line on stdout:
{
  "ev":"inspect",
  "app_root":"/var/www/shop",
  "current":  "42",            # basename of readlink current, or null
  "previous": "41",
  "releases": [40,41,42,43],   # numeric-sorted
  "ready":    [40,41,42],      # releases containing .shipyard-ready
  "env_sha":  "9f2c1a",        # sha256 prefix of shared/.env
  "unit": {
    "name": "app@shop.service",
    "active": "active",
    "failed": "no",
    "n_restarts": 3,
    "exec_main_start": 1788000000
  }
}
```

```bash
#!/usr/bin/env bash
# read-only. Never mutates.
set -euo pipefail
root=$1; unit=$2
cur=$(readlink -f "$root/current" 2>/dev/null || true)
prev=$(readlink -f "$root/previous" 2>/dev/null || true)
rel=(); rdy=()
for d in "$root"/releases/*/; do
  [ -d "$d" ] || continue
  n=$(basename "$d"); rel+=("$n")
  [ -f "$d/.shipyard-ready" ] && rdy+=("$n")
done
printf '{"ev":"inspect","app_root":"%s","current":%s,"previous":%s,"releases":%s,"ready":%s,"env_sha":"%s"}\n' \
  "$root" "$(num_or_null "$cur")" "$(num_or_null "$prev")" \
  "$(json_arr "${rel[@]}")" "$(json_arr "${rdy[@]}")" \
  "$(sha256sum "$root/shared/.env" 2>/dev/null | cut -c1-6)"
```

`.shipyard-ready` is written as the **last act** of the build step. Its presence
is the guarantee that a release directory is complete. Its absence means "this
directory is still being written, or was abandoned mid-write" — and the swap
refuses to point `current` at it.

#### 2.3.3 The decision table

Let `N` = this deployment's `release_number` (allocated once, §2.4),
`P` = what `current` points at, `S` = the unit's `NRestarts`.

| Host truth | DB intent | Verdict | Action |
|---|---|---|---|
| `P == N`, unit `active`, `NRestarts` stable, release in `ready` | any non-terminal | **It actually succeeded.** The control plane died before recording it. | Promote to `RUNNING`. Idempotent no-op on the host. |
| `P == N-1` (or `P == previous`), unit `active` | `starting` / `healthy` / `verifying` | Swap never happened, or a rollback happened | `FAILED`, `failure_code=RECONCILED_SWAP_NEVER`, `failure_detail="current=$P want=$N"`. Old release still serving. **No user impact.** |
| `P == N`, unit `failed` or `NRestarts` climbing | any | Deployed and crash-looping | **Auto-rollback** (§6), then `FAILED`, `HEALTH_FAILED`. |
| `P == N`, `N` in `releases` but **not** in `ready` | any | Swap happened on an incomplete release — should be impossible, but check | Roll back to `previous`, `FAILED`, `RECONCILED_INCOMPLETE_RELEASE`, **and alert**: this is a contract violation between build and swap, i.e. a bug in Shipyard. |
| `N` in `releases`, `P != N` | any | Build finished, swap never ran | **Resume at the `swap` step.** Safe: the step is convergent. |
| `P == null`, `releases` empty | first-ever deploy, interrupted | Nothing to roll back to | `FAILED`, `RECONCILED_NO_PREVIOUS`. Needs a human. |
| `N` not in `releases` at all, `P == P` | `cloning`/`building` | Clone or build never produced a directory | **Resume at the `build` step** (`rm -rf` first, §2.4). If `attempts` exhausted, `FAILED`. |
| `P == previous`, `previous` itself unhealthy | any | Rollback target is also broken | `FAILED`, `ROLLBACK_FAILED`, **page**. The site is down and Shipyard did what it could. |

Two properties fall out of this table:

- **Almost every row ends in a resume or a terminal state, never in a guess.**
- **The only genuinely lossy case is a first-ever deploy that was interrupted
  mid-clone**, and that is recoverable because a clone is deterministic.

#### 2.3.4 When it runs

```go
func (r *Reconciler) Run(ctx context.Context) error {
    // 1. on startup, before the worker loop accepts any job.
    //    Ordering matters: never let a new deploy start while a stale one is
    //    unresolved, or you get two deploys racing for the same server.
    orphans := r.store.OrphanedDeployments(ctx)     // §2.3.1
    for _, d := range orphans {
        verdict := r.walk(ctx, d)                    // §2.3.3
        r.store.ApplyVerdict(ctx, d.ID, verdict)
    }
    // 2. then every 60s, forever, to catch things that go wrong at runtime.
    ticker := time.NewTicker(r.interval)
    for { select { case <-ctx.Done(): return ctx.Err(); case <-ticker.C: r.sweep(ctx) } }
}
```

A permanent 60s sweep is cheap (one indexed query) and catches the case where
the lease reaper misses something.

### 2.4 Idempotency and retries

#### 2.4.1 The idempotency key

**`(deployment_id, step_name)`, with `attempt` as the third component of the
primary key** so attempts are auditable rather than overwritten.

```sql
CREATE TABLE deployment_steps (
  deployment_id uuid NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
  name          text NOT NULL,
  attempt       int  NOT NULL,
  status        text NOT NULL CHECK (status IN ('running','ok','failed','skipped')),
  started_at    timestamptz,
  finished_at   timestamptz,
  exit_code     int,
  err_code      text,
  output_tail   text,      -- last 8 KiB, for the UI; full log is on disk (§4)
  PRIMARY KEY (deployment_id, name, attempt)
);
```

And critically — **the release number is part of the deployment's identity, not
a side effect of executing it:**

```sql
-- In the API transaction, at creation time. Not at build time.
INSERT INTO deployments (..., release_number, ...)
SELECT $1, ..., COALESCE(MAX(release_number), 0) + 1, ...
FROM deployments WHERE project_id = $2
ON CONFLICT (project_id, release_number) DO NOTHING
RETURNING *;
-- UNIQUE (project_id, release_number) is the backstop; 23505 => retry.
```

This single decision prevents an entire bug class. If release numbers were
allocated at build time, a retry after a crash would allocate `N+1`, orphan
release `N`, break `previous`, and make the §2.3.3 comparison
(`current == N`?) meaningless — the reconciler would not be able to tell success
from failure.

#### 2.4.2 Step-by-step retry classification

| Step | Idempotent? | How | Retried? |
|---|---|---|---|
| `clone` | yes | Content-addressed on the SHA. If `releases/<N>` exists but has no `.shipyard-ready`, `rm -rf` and re-clone. | yes |
| `build` | **only if the dir is clean** | `rm -rf releases/<N> && mkdir -p releases/<N>` first, every time. Build into `releases/<N>/.build`, `mv` into place on success. | yes |
| `config` | yes | Pure function `DB env → file`. `tmp` + `mv`. | yes |
| `swap` | yes | Convergent: "make current point at N". Re-running points at N again. | yes |
| `start` | yes | `systemctl restart` is idempotent. | yes |
| `verify` | yes | Read-only. | yes |

**Nothing in the pipeline is non-idempotent** — that is the goal. There is no
step that appends to a shared resource, allocates an identifier, or mutates
something a later step depends on. The only resource allocation (release
number) happens in the API transaction under a unique constraint.

#### 2.4.3 `shared/.env` is never half-written

The live service reads it via systemd's `EnvironmentFile=` **at start**. Two
failure modes: an interrupted write, and an append-only render that never
removes deleted keys.

```bash
# Render the COMPLETE desired set. Never append. Never write in place.
set -euo pipefail
target="$app_root/shared/.env"
tmp="$app_root/shared/.env.tmp.$$"
umask 077
: > "$tmp"                                  # truncate the temp, never the live file
while IFS= read -r kv; do                   # complete KV lines, NUL-safe upstream
  printf '%s\n' "$kv" >> "$tmp"
done < "$env_stdin_file"                    # fed by the agent from a private fd
printf '\n' >> "$tmp"                       # systemd requires a trailing newline
chown root:"$SVC_USER" "$tmp"
chmod 0640 "$tmp"
mv -f "$tmp" "$target"                      # rename(2) within shared/ => atomic
sync -f "$target" 2>/dev/null || true       # durable before the service reads it
```

- `mv -f` within one directory is `rename(2)`: atomic. A reader gets the old file
  or the new file, never a truncated one.
- Rendering the full set means a deleted variable actually disappears.
- `0640 root:appsvc` — readable by the service user, not by other apps on the
  host, not world-readable.
- Env changes reach the process only on the next `systemctl restart`, which only
  happens during a deploy. **That is the whole "env is a deploy boundary" story:
  it is a property of the mechanism, not a rule anyone has to remember.**

#### 2.4.4 Backoff

Per step, not per deployment. A failed `verify` re-runs the health check; it
does not rebuild for three minutes. This matters — the user is staring at a red
deploy and does not want to wait for a rebuild to learn their health check is
wrong.

```go
var backoff = []time.Duration{5 * time.Second, 15 * time.Second, 45 * time.Second}

func (r *runner) nextDelay(attempt int) time.Duration {
    if attempt >= len(backoff) { return backoff[len(backoff)-1] }
    d := backoff[attempt]
    return d + time.Duration(rand.Int63n(int64(d/4)))   // ±25% jitter
}
```

`max_attempts` is 3 for `clone`/`build`, 1 for `swap`/`start` (a failure there is
a real host problem; retrying blindly is worse than failing loudly), and
`HealthAttempts` (§6) is a separate budget.

A resumed deployment picks up at the **first step not marked `ok`**:

```go
func (r *runner) resumePoint(ctx context.Context, d Deployment) Step {
    done, err := r.store.SuccessfulSteps(ctx, d.ID)
    if err != nil { return StepClone }         // fail open to the start
    for _, s := range StepOrder {
        if !done[s.Name()] { return s }
    }
    return StepVerify
}
```

### 2.5 Timeouts and cancellation

```go
// internal/config — defaults, overridable per project
var StepBudgets = map[Step]time.Duration{
    StepClone:   10 * time.Minute,   // large monorepo
    StepBuild:   20 * time.Minute,   // npm install is the classic wedge
    StepConfig:   2 * time.Minute,
    StepSwap:     1 * time.Minute,   // must be fast: it is the swap
    StepStart:    2 * time.Minute,
    StepVerify:   5 * time.Minute,   // includes the health budget
}
var GlobalDeploymentBudget = 45 * time.Minute   // backstop
```

```go
func (r *runner) runStep(ctx context.Context, d Deployment, s Step) error {
    ctx, cancel := context.WithTimeout(ctx, s.Budget())
    defer cancel()
    return s.Run(ctx, r, d)
}
```

On timeout, the remote process is signalled, not merely abandoned:

```go
// internal/executor/ssh_exec.go
session, err := conn.NewSession()
go func() { <-ctx.Done(); session.Signal(ssh.SIGTERM) }()   // then SIGKILL after 10s
```

**And the crucial consequence: a build timeout has zero user impact.** The
timeout happens in `build`, which is step 2 of 6. `current` is untouched. The
old release is still serving. The deployment is `FAILED` with
`BUILD_TIMEOUT`; nobody notices. The entire point of the
`releases/<n>` + symlink layout is that it makes the expensive, failure-prone
phase of a deploy (build) occur *offline*, where failure is free.

This is worth stating explicitly because it is the strongest architectural
argument for the release layout: **failure isolation is structural, not
procedural.** No rollback code needs to run, because nothing was at risk.

---

## 3. The Bash execution layer contract

### 3.1 Two artifacts, not one

| Artifact | Installed | Contents | Mutates? |
|---|---|---|---|
| **agent** | `/usr/local/lib/shipyard/agent.sh` by Go, checksum-pinned | verbs: `clone build config swap start verify rollback inspect` | Shipyard's own steps |
| **deploy.sh** | in the user's repo | the user's build logic | whatever the user wrote |

The agent is transport and policy. `deploy.sh` is the user's business. The
agent's `build` verb is the only one that runs user code, and it runs it with
`env -i` plus a minimal, explicitly enumerated environment.

This split means the *contract* is ~200 lines of Bash that can be exhaustively
tested, and the *user code* is untrusted and cannot corrupt the contract.

### 3.2 Invocation

Always literally this, regardless of verb:

```bash
/usr/bin/env bash /usr/local/lib/shipyard/agent.sh <verb> <base64-of-json>
```

Two argv items, one of which is a fixed verb from a closed enum. Nothing
user-controlled and nothing secret is ever in argv.

```go
type Request struct {
    Verb     Verb                 // closed enum, never free-form
    AppRoot  string               // /var/www/<app>
    Unit     string               // app@<app>.service
    Release  int                  // N — allocated once, §2.4.1
    Commit   string               // full 40-char SHA
    Env      map[string]string    // from stdin, never argv — §3.5
    EnvSHA   string               // hash of Env, for change detection
    TraceID  string
    Budget   time.Duration
}
```

### 3.3 Stream framing

Three streams, cleanly separated so that user log noise can never be mistaken
for control data.

| fd | Content | Parsed by Go as |
|---|---|---|
| **1 (stdout)** | raw human log — the *build log* | line-oriented, streamed to the UI verbatim |
| **2 (stderr)** | **always** NDJSON control frames | `json.Decoder` over the stream |
| **0 (stdin)** | framed NDJSON params + secrets | agent reads to EOF before executing |

The agent guarantees stderr is *always* machine-parseable: the user's stderr is
captured and re-emitted wrapped, never passed through raw.

```bash
# inside the agent
{
  emit() { printf '%s\n' "$*" >&2; }   # every control frame
  # user's stdout -> fd 1 raw, user's stderr -> wrapped NDJSON on fd 2
  run_user() {
    set +e
    "$@" 2> >(while IFS= read -r l; do
               emit "$(json_str 'ev=log' 'stream=stderr' "line=$l")"
             done) >&1
    return $?
  }
}
```

A control frame is one line of JSON with an `ev` field. Examples:

```json
{"ev":"step","name":"build","state":"start"}
{"ev":"log","stream":"stdout","line":"added 412 packages in 8s"}
{"ev":"step","name":"build","state":"end","exit":0,"duration_ms":8123}
```

Go's reader for fd 2 is a `json.Decoder` in a goroutine feeding a typed channel.
A malformed line is counted in `logstream_dropped_frames_total{kind="bad_json"}`
and skipped — a bad control frame must never kill the stream.

### 3.4 Exit codes and the three-state result

| Code | Symbol | Meaning | Go reaction | Retry |
|---|---|---|---|---|
| 0 | — | Success, verified | step `ok` | — |
| 1 | `BUILD_FAILED` | `deploy.sh` failed | `FAILED` | no — user's code |
| 10 | `PRECONDITION` | git ref missing, disk full, app root absent | `FAILED` | no |
| 20 | `ENV_CONFIG` | `nginx -t` failed, unit file invalid | `FAILED` | no — needs a human |
| 30 | `HEALTH_FAILED` | health window exhausted | `FAILED` + **auto-rollback** | no |
| 40 | `AGENT_FAULT` | agent invariant violation | `FAILED` | **yes** + alert |
| 41 | `CONTRACT_VIOLATION` | exited without a result frame | `FAILED` | yes + alert |
| 75 | `EX_TEMPFAIL` | transient git/network | step `failed` | **yes**, backoff |
| 124 | — | GNU `timeout` killed it | step `failed` | yes |
| 130 | — | we sent SIGINT/SIGTERM | step `failed` | reconciler decides |

**But the exit code is the fast path, not the truth.** Before exiting — always,
via a `trap ... EXIT` — the agent emits exactly one result frame:

```json
{"ev":"result","status":"ok","release":42,"current":"42",
 "unit":{"name":"app@shop.service","active":"active","n_restarts":0},
 "state":{"swap":"committed","env_sha":"9f2c1a","built_sha":"3a91ff"}}
```

`status` ∈ `ok` | `failed` | `indeterminate`.

**Go requires this frame.** This is the direct answer to "how is a partial
failure distinguished from a clean failure":

```go
// internal/executor/result.go
func (r *Result) Verify(cmdExitCode int) error {
    switch {
    case r == nil:                       // process died, no frame at all
        return Fault(CodeContractViolation,
            "agent exited without a result frame", "exit", cmdExitCode)
    case r.Status == StatusOK && cmdExitCode != 0:
        return Fault(CodeAgentFault, "result frame says ok but exit != 0", ...)
    case r.Status == StatusIndeterminate:
        return Fault(CodeContractViolation,
            "agent could not determine outcome", "exit", cmdExitCode)
    case r.Status == StatusFailed:
        return Fault(CodeFromExit(cmdExitCode), r.Message, r.Detail)
    default:
        return nil
    }
}
```

Three states, not two: **success**, **failure**, and **"I do not know."** The
third is the one that matters. A step that reports `indeterminate` — killed
mid-`mv`, SSH dropped, disk full during the swap — is handed to the reconciler
rather than being guessed at. Most systems conflate this with failure and end up
either lying to the user or corrupting state. Being able to say "I don't know,
let me look" is the whole point.

### 3.5 Secrets never in argv

`ps auxww` shows the full argv of every process on the host to every local user.
`/proc/<pid>/environ` is readable by the process owner and by root. Both are
leak surfaces, and both are trivially avoided here.

**Rejected, and why:**

- `ssh host "DEPLOY_KEY=$(cat key) git clone"` — argv, visible in `ps`. A key
  in argv is a key in the process table, in every shell history, and in every
  `ps` for the lifetime of the clone.
- `env DEPLOY_KEY=... bash deploy.sh` — better than argv, but still lands in
  `/proc/<pid>/environ`, and shows up in `systemctl show` and systemd unit
  dumps when the process is a unit.
- Shipping the deploy key from Go on every deploy — the key crosses the wire
  500 times when it needs to cross it once.

**What we do instead, in order of preference:**

**(a) The git deploy key never moves per-deploy.** The *public* half is
installed once into `/home/deploy/.ssh/authorized_keys` during server
enrollment (a human runs one command, or Go does it once with the admin key).
After that, the agent clones with the key already on disk:

```bash
git -c core.sshCommand='ssh -i /home/deploy/.ssh/id_deploy -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes' \
    fetch --depth 1 origin "$COMMIT"
```

**Shipyard never possesses a secret that can deploy anywhere.** Only public keys
live in the control plane. This is the cleanest available design and it costs
nothing.

**(b) Anything dynamic per-deploy goes over stdin**, which is not in argv and
not in environ. The agent reads a framed NDJSON stream from fd 0 to EOF before
executing:

```json
{"kind":"params","app_root":"/var/www/shop","release":42}
{"kind":"secret","name":"SLACK_WEBHOOK_URL","value":"https://hooks..."}
{"kind":"eof"}
```

Go writes this to `session.Stdin` and closes it. The agent holds the secrets in
a `0600` file under a private dir, and — importantly — **never exports them as
build-step env vars**, only as `${kind=secret}` substitutions inside generated
config files.

**(c) App runtime env vars** are a completely different case and are not a
leak: `DATABASE_URL` is supposed to be in the app process's own environ, which
is how Unix works. The chain is Postgres (encrypted, §8) → agent stdin → `shared/.env` at `0640 root:appsvc` → systemd `EnvironmentFile=` → the app's own `/proc/self/environ`. The right to read it belongs to the app's own user and nothing else.

**And the containment layer that makes the rest true.** The agent runs as a
dedicated unprivileged `shipyard` user with `sudo` scoped to exactly what it
needs:

```sudoers
# /etc/sudoers.d/shipyard — mode 0440, owner root:root
Defaults!SHIPYARD_NO_LOGIN_SHELL
shipyard ALL=(root) NOPASSWD: /usr/bin/systemctl restart app@*.service
shipyard ALL=(root) NOPASSWD: /usr/bin/systemctl stop app@*.service
shipyard ALL=(root) NOPASSWD: /usr/bin/systemctl is-active app@*.service
shipyard ALL=(root) NOPASSWD: /usr/bin/systemctl show -p NRestarts app@*.service
shipyard ALL=(root) NOPASSWD: /usr/bin/nginx -t
shipyard ALL=(root) NOPASSWD: /usr/bin/systemctl reload nginx
shipyard ALL=(root) NOPASSWD: /usr/bin/install -d -o shipyard -g shipyard -m 0750 /var/www/*/releases/*
```

Consequence: even a fully compromised `deploy.sh` cannot read
`/var/www/other-app/shared/.env`, cannot read the git deploy key of another
project, and cannot run arbitrary `systemctl`. Fifteen lines of config for real
defense in depth — and it is a line a reviewer will notice.

### 3.6 SSH client specifics

- `golang.org/x/crypto/ssh`, with `HostKeyCallback` = **TOFU against a table**.
  The first key seen is pinned to `servers.ssh_host_key`; a subsequent mismatch
  returns `HOST_KEY_MISMATCH`, is **never retried**, and alerts. This is a real
  MITM defense and it is the kind of detail that separates a toy from a control
  plane.
- `ServerAliveInterval: 15s` — not cosmetic. It bounds how long a dead control
  plane's TCP session lingers holding a Postgres advisory lock (§11.6).
- One `ssh.Client` per server, refcounted, with `MaxSessionsPerServer` (default
  4) so a log-stream reader cannot starve a deploy.
- A stale agent on the host is detected by a version stamp: the agent's
  `--version` must match the control plane's build version, checked at the start
  of every run. A version skew is `AGENT_FAULT` with a clear message, not a
  mysterious failure three steps later.

---

## 4. Build log capture and storage

### 4.1 Transport: SSE, not WebSocket

```
ssh stdout ─┬─▶ Pump.Publish  ─┬─▶ ring.Ring (256 KiB, in memory)
             │                 ├─▶ subs[] non-blocking, bounded per-sub buffer
             │                 └─▶ spool file (NDJSON.gz chunks, on disk)
             │                        │
             └──▶ log segmenter ◀──────┘
                        │
                     SSE ◀┘  (text/event-stream, id: <seq>)
```

SSE over WebSocket because this is one-directional, SSE survives corporate HTTP
proxies, `EventSource` reconnects with `Last-Event-ID` for free, and the
Next.js client consumes it in five lines. WebSocket would be the wrong tool and
would also require sticky sessions or Redis fan-out if the API is ever scaled
horizontally — which is precisely the kind of complexity this project does not
need.

### 4.2 The pump

```go
// internal/logpipe/pump.go
type Pump struct {
    mu     sync.Mutex
    tail   *ring.Ring     // 256 KiB, so a late subscriber gets context
    subs   map[int64]*sub
    spool  *Spool         // NDJSON.gz chunks under var/log/builds/<deployment_id>/
    total  atomic.Int64   // bytes seen
    cap    int64          // 32 MiB
    truncated atomic.Bool
    nextSeq atomic.Uint64
}

func (p *Pump) Publish(b []byte) {
    p.total.Add(int64(len(b)))
    if p.total.Load() > p.cap {
        // Hard stop, emit one frame, keep the first N MiB. A 40 MiB npm tree is
        // unreadable anyway; refusing it is kinder than storing it.
        p.truncated.Store(true)
        p.publishControl(ControlFrame{Ev: "truncated", Total: p.total.Load()})
        return
    }
    p.tail.Write(b)
    p.spool.Append(b)
    p.fanout(b)          // MUST NOT BLOCK
}

func (p *Pump) fanout(b []byte) {
    p.mu.Lock(); defer p.mu.Unlock()
    for id, s := range p.subs {
        select {
        case s.ch <- b:
        default:
            // Subscriber is slow. Drop, and tell it later.
            s.dropped.Add(1)
        }
    }
}
```

Three properties that are the entire design:

1. **Publishing never blocks.** A browser on a bad connection cannot apply
   backpressure through the SSH stdout pipe into the build's write buffer and
   stall the remote `npm`. This is the OOM / head-of-line-blocking defense.
2. **Memory is O(concurrent deployments), not O(log volume).** 4 concurrent
   deploys × 256 KiB ring ≈ 1 MiB, no matter how much a build prints. The
   unbounded part goes to disk. That sentence is the requirement.
3. **A slow subscriber learns it dropped lines** — the server injects
   `{"ev":"lag","dropped":N}` and the client can re-sync with a replay request
   from its last `seq`. Silent truncation is worse than a visible one.

### 4.3 Volume caps

- **Per deployment: 32 MiB**, default, configurable per project. On exceeding:
  stop spooling, set `truncated`, emit one frame. The deployment still succeeds
  — a chatty build is not a failed build.
- **Per subscriber: a 64 KiB channel buffer.** Overflow drops (§4.2).
- **Per deployment: 32 concurrent subscribers**, default. Beyond that, `429`.
  Otherwise 1000 restored browser tabs means 1000 goroutines each holding an
  SSH session.
- **Retention: 7 days**, reaped hourly by `logpipe.Reap()`. Deleting a project
  is `os.RemoveAll` — which is a strong argument for the filesystem.

### 4.4 Storage: files, not Postgres

```
var/log/builds/<deployment_id>/
    000001.ndjson.gz     64 KiB uncompressed per chunk
    000002.ndjson.gz
    meta.json            {lines, bytes, truncated, created_at}
```

`deployments.build_log_ref` points at the directory.

Build logs do not belong in Postgres. They are append-heavy, unread by any
`WHERE` clause anyone will actually write, and they will bloat `VACUUM` and
table size for the entire lifetime of the database. A directory of compressed
chunks is the correct tool, deletes atomically, backs up with `rsync`, and
needs no index. The database stores the pointer and the line count.

---

## 5. Runtime log streaming from `journalctl`

### 5.1 Cursors, not timestamps

This host has `--show-cursor` and `--after-cursor`, and using them is the single
most important decision in this section.

```bash
journalctl -u app@shop.service -f -n 0 \
          --output=json --show-cursor \
          --after-cursor="s=8f3a...c=91b2..." \
          --output-fields=MESSAGE,_SYSTEMD_UNIT,PRIORITY,_PID
```

Why timestamps cannot work: entries sharing a microsecond have unstable
ordering; Go's "last seen" clock and journald's `__REALTIME_TIMESTAMP` can
disagree; timezone handling is a footgun. The result is duplicated and missing
lines in the user's runtime log view, which reads as a correctness bug. The
journal **cursor is a monotonic position in the journal**, designed for exactly
this. Store it, feed it back, and the resume is exact and duplicate-free.

The cursor is returned on the *last* line of a session as `-- cursor: s=...`.
Advance it only after the whole batch is accepted into the ring.

### 5.2 One feed per (server, unit), refcounted

The naive design — one `journalctl -f` SSH process per browser tab — is wrong
in three ways at once: N tabs means N journald cursors all pulling identical
data, N SSH processes against the target, and N times the host CPU for zero
benefit. A browser crash-restore can open 40 tabs at once.

```go
// internal/journal/hub.go
type Key struct{ ServerID uuid.UUID; Unit string }

type Feed struct {
    key     Key
    ring    *ring.Ring            // 2000 lines
    subs    map[int64]chan Entry  // 64 KiB each
    cursor  string                // shared, advanced once per accepted batch
    cancel  context.CancelFunc
    refs    atomic.Int32
    lastUse atomic.Int64
}

type Hub struct {
    mu       sync.Mutex
    feeds    map[Key]*Feed
    maxFeeds int      // 64 (server, unit) pairs
    idleGrace time.Duration   // 60s
}

func (h *Hub) Subscribe(k Key, from string) (<-chan Entry, func(), error) {
    // refcount++; spawn `journalctl -f` on 0->1
    // refcount--; start a 60s idle timer; cancel the SSH process on 1->0
}
```

Feeds are idle-reaped. Without it, every unit anyone ever viewed leaves a live
SSH session and a `journalctl` process behind forever.

### 5.3 Backpressure

Identical to the build-log pump, with one addition: the **cursor always
advances**, because the ring is bounded and evicts oldest. If a slow subscriber
held the cursor back, the next read would re-deliver a growing window — an
unbounded re-read, which is worse than dropping lines.

Slow subscribers drop and receive `{"ev":"lag","dropped":N,"cursor":"s=..."}`,
and can re-sync from the ring by seq.

### 5.4 What happens when the unit restarts mid-stream

**Nothing. That is the payoff for using journald rather than
`systemctl follow`.**

`journalctl -f` is a stream of *events*, not a state snapshot. A restart appears
as ordinary `Stopping` / `Stopped` / `Started` entries and the stream continues.
There is no reconnect to write, because nothing tore.

What genuinely breaks:

| Event | Detection | Response |
|---|---|---|
| SSH connection drops | stream `io.EOF` | Reconnect with `--after-cursor=<last>` |
| Cursor too old (journald rotated) | returned cursor is lexicographically < saved cursor, or 0 lines with no error | Emit `{"ev":"gap","from":..,"to":..}`, re-seed with `-n 200`, continue |
| Rate limiting / journal full | `Suppressed messages: N` in output | Emit `{"ev":"suppressed","n":N}` — the user must know lines are missing |
| Feed idle | 60s no subscribers | Cancel the SSH session |

**Crash-loop detection does not belong here.** It belongs in `health`, polling
`systemctl show -p NRestarts` every 5s during the health window. Mixing it into
the log path would make the log path responsible for judging the service, and it
is not well positioned to do so.

One transport note: `--output=json` then render server-side, and use
`--output-fields` to strip `__CURSOR`, `_BOOT_ID`, `_MACHINE_ID` and friends
before they cross the wire. On a chatty service that is a 3–4× bandwidth
reduction, and these are exactly the "non-obvious problems" — per-line
`__CURSOR` and boot-id are among the largest fields journald emits.

---

## 6. Health checking

### 6.1 Two phases, because a TCP connect proves nothing

A TCP connect to a port that systemd has bound tells you the process exists. It
does not tell you the app initialised, connected to its database, loaded its
config, or is not in a `Restart=always` loop that passes through a listening
socket for 40ms each time.

**Phase 1 — unit stability (catches crash loops).**

```bash
systemctl is-active app@shop.service            # must be: active
systemctl show -p NRestarts --value app@shop    # must not increase
```

Poll every 2s for `UnitStableWindow` (default 10s). `NRestarts` increasing at
any point is an immediate failure. A plain 200-check would pass this app during
the fraction of the cycle it is up.

**Phase 2 — application probe (catches "running but broken").**

```go
type Check struct {
    Kind        CheckKind   // http | tcp | command
    Endpoint    string      // default http://127.0.0.1:8080/healthz
    ExpectCodes []int       // default [200]
    Headers     map[string]string
    Timeout     time.Duration   // 2s
    BodyContains string
}
```

Four rules, all of which matter:

1. **Probe `127.0.0.1` at the unit's port.** Going out through the public
   hostname tests nginx, DNS, TLS, and the public interface — none of which are
   the thing you deployed. It also means the check passes when the *old* release
   is still serving through an undischarged connection.
2. **Assert the release marker.** The single highest-leverage decision in the
   whole health design:

   ```
   unit:  Environment=SHIPYARD_RELEASE=42
   probe: expect  X-Shipyard-Release: 42
   ```

   If the old process is still answering — because the restart raced, or
   because `current` was never swapped, or because nginx cached a connection —
   the header is `41` and the check **fails**. A plain `GET /` returning 200
   cannot detect that at all. It is one env var, one header, and it converts a
   whole class of silent wrong-deploy bugs into a loud failure.
3. **Verify the symlink too**: `readlink current` == `N`. Cheap and definitive.
4. **Fail on latency spikes**, not just errors: record probe duration and fail
   if p > `Timeout`. A health endpoint taking 1.8s is not healthy.

### 6.2 Retry budget

```go
type HealthPolicy struct {
    UnitStableWindow  time.Duration // 10s
    Attempts          int           // 10
    Interval          time.Duration // 3s   => 30s window
    Timeout           time.Duration // 2s   per attempt
    SuccessThreshold  int           // 3 CONSECUTIVE
    SuccessSpread     time.Duration // 5s minimum span
}
```

`SuccessThreshold` is the part people miss. Requiring **3 consecutive successes
spread over at least 5s** rejects an app that boots, answers one request, and
dies — which is precisely the shape of a bad migration or a missing env var.
One success is not evidence.

### 6.3 Automatic rollback

```
verify fails
  │
  ├─ mark deployment FAILED (HEALTH_FAILED) FIRST, in its own transaction.
  │  (mark-then-act: a crash mid-rollback must not leave a RUNNING
  │   deployment pointing at a bad release)
  │
  ├─ rollback:
  │    1. swap_link <app_root> <previous>          # the same safe sequence, §7
  │    2. systemctl restart app@shop.service
  │    3. health-check `previous` with the SAME budget, expecting
  │       X-Shipyard-Release: <previous>
  │    4. ok   -> FAILED, reason=unhealthy_rolled_back, previous serving
  │    5. fail -> FAILED, reason=rollback_failed, + PAGE
  │               (site is down; Shipyard did what it could)
  │
  └─ notify + shipyard_rollbacks_total{project,result="ok"|"failed"}
```

Marking the deployment `FAILED` *before* attempting rollback is deliberate and
important: it means every crash in the middle of rollback is recoverable by
reconciler §2.3.3, which sees "current == N, unit unhealthy" and re-runs the
rollback. If you marked it after, a crash mid-rollback would leave a
`RUNNING` deployment and no signal that anything was wrong.

**Keep the failed release.** Do not `rm -rf` it. The user needs to inspect the
build that broke, and rollback must not be able to destroy the evidence.
Retention prunes old releases on the *next* deploy, never the current one.

### 6.4 Not flapping — three distinct modes

**Mode A — the control plane keeps retrying the bad release.**
Don't. Once rollback runs, the deployment is **terminal**. There is no
auto-retry of an unhealthy release, ever. The user re-deploys explicitly, which
produces a new Deployment row and a new audit trail entry. An auto-retry would
re-run the identical bad SHA in a loop and burn a build slot doing it.

**Mode B — rollback itself flapping: N fails → roll back to N-1 → N-1 fails →
roll forward → ...** This is the dangerous one. It would ping-pong a live site
between releases. A circuit breaker, in the database, with a doubling cooldown:

```sql
CREATE TABLE project_circuit (
    project_id         uuid PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
    consecutive_fails  int NOT NULL DEFAULT 0,
    state              text NOT NULL DEFAULT 'closed'  -- closed | open
    opened_at          timestamptz,
    probe_after        timestamptz,
    cooldown           interval NOT NULL DEFAULT interval '30 minutes',
    last_release       int
);
```

- After `RollbackThreshold` (default **2**) consecutive unhealthy deploys the
  circuit **opens**.
- While open, any new deployment for that project short-circuits at admission
  time in the API to `FAILED(CIRCUIT_OPEN)` with a message naming the last bad
  release — before it ever builds. This is cheap, and it is also a good product
  behaviour: "you've failed 2 deploys in a row; fix something first."
- After `cooldown`, the next deploy is allowed as a **half-open trial**. If it
  succeeds, the circuit closes. If it fails, it re-opens and `cooldown` **doubles**,
  capped at 24h.

```go
// internal/engine/circuit.go
func (c *Breaker) Admit(ctx context.Context, projectID uuid.UUID) (bool, time.Time, error) {
    // INSERT ... ON CONFLICT DO NOTHING to create the row, then SELECT ... FOR UPDATE
    switch row.State {
    case "closed":
        return true, time.Time{}, nil
    case "open":
        if time.Now().After(row.ProbeAfter) {
            return true, time.Now(), nil    // half-open: one trial through
        }
        return false, row.ProbeAfter, nil
    }
}
func (c *Breaker) Record(ctx context.Context, projectID uuid.UUID, healthy bool) error {
    // healthy  -> reset to closed
    // unhealthy-> fails++; if fails >= threshold: open, probe_after = now()+cooldown
    //             else cooldown = LEAST(cooldown * 2, interval '24 hours')
}
```

**Mode C — the app crash-looping on its own between deploys.** Shipyard is not
involved, and no circuit here can help, because nothing is calling it. The fix
is to make systemd itself the breaker, via a drop-in the agent installs:

```ini
# /etc/systemd/system/app@.service.d/limits.conf
[Unit]
StartLimitIntervalSec=120
StartLimitBurst=5
```

systemd then gives up and marks the unit `failed`, instead of restarting forever.
This is strictly better than reimplementing it in Go, because it is active
whenever the app is misbehaving, not just during a deploy. It also makes Phase
1's `is-active` correct instead of racy.

**The general principle:** put the breaker at the layer that is always active.
For "our deploys are bad" that is the database circuit. For "the app is bad" that
is systemd. Neither belongs in the other.

---

## 7. Symlink swap correctness

`ln -sfn /var/www/app/releases/42 /var/www/app/current` is wrong. Two ways:

1. **It is not atomic.** `-f` unlinks the destination *first*, then creates the
   link. Between `unlink` and `symlink` there is a window where **`current` does
   not exist**. `WorkingDirectory=/var/www/app/current` resolves to ENOENT in
   that window. `try_files $uri /index.html` returns 502.

   This is not theoretical and the window is not a microsecond sliver. Measured
   on this machine (`docs/swaprace.c`, a reader thread spinning on
   `stat("current")` while a writer performs 500 000 swaps):

   | Swap technique | samples | `current` did not resolve |
   |---|---|---|
   | `ln -sfn` equivalent — `unlink()` then `symlink()` | 2 087 195 | **1 346 839 (64.5%)** |
   | `symlink()` to temp + `rename(2)` | 4 387 001 | **0** |

   The gap exists between two syscalls, so its size is decided by the
   scheduler: under load the writer is preempted there and the window grows to
   milliseconds. Every request that resolves `current` during it gets a 502,
   and every `systemctl restart` that lands in it fails to start. You will hit
   it — not rarely, and never at a moment when you can reproduce it.
2. **The `-n` semantics are a portability trap.** With a directory destination,
   `ln` behaviour differs between GNU coreutils, busybox, and BSD. A swap that
   works on your Ubuntu lab and silently nests a symlink inside a directory on
   the next host is a bad afternoon.

**The correct sequence: `symlink()` to a temp name in the same directory, then
`rename(2)`.** `rename` within one directory and one filesystem is atomic in the
kernel: a reader sees the old target or the new one, never nothing.

```bash
#!/usr/bin/env bash
# shipyard-swap -- the ONLY sanctioned way to move `current`.
# usage: swap_link <app_root> <new_release_number>
set -euo pipefail
umask 022
app_root=$1
new_rel=$2
cur="$app_root/current"
new="$app_root/releases/$new_rel"

# --- 1. Fail closed. Never point `current` at a half-built release. -------
[ -d "$new" ] || { echo "no such release: $new" >&2; exit 10; }
[ -f "$new/.shipyard-ready" ] || { echo "release $new_rel not marked ready" >&2; exit 10; }

# --- 2. Record what we are moving away from (rollback target + ledger). ----
prev=$(readlink -f "$cur" 2>/dev/null || true)
prev_num=${prev##*/}

# --- 3. Build the new link under a temp name IN THE SAME DIRECTORY. -------
#     Same directory => same filesystem => rename(2) is guaranteed atomic.
#     Relative target => the whole app_root can be moved or bind-mounted.
tmp="$app_root/.current.$$.tmp"
ln -s "releases/$new_rel" "$tmp"

# --- 4. THE SWAP. One syscall. rename(2). No window where current is gone. -
mv -Tf "$tmp" "$cur"

# --- 5. Maintain `previous` for one-step rollback, same atomic technique. --
if [ -n "$prev_num" ] && [ "$prev_num" != "$new_rel" ]; then
  ptmp="$app_root/.previous.$$.tmp"
  ln -s "releases/$prev_num" "$ptmp"
  mv -Tf "$ptmp" "$app_root/previous"
fi

# --- 6. Make the rename durable before anything reads it. -----------------
sync -f "$app_root" 2>/dev/null || sync
```

Line by line, and why:

| Line | Why |
|---|---|
| `set -euo pipefail` | A failed `ln` must not be silently followed by a successful-looking `mv`. |
| `umask 022` | Deterministic perms regardless of the caller's umask. |
| 1: `-f .shipyard-ready` | The ordering guarantee between build and swap. Its presence means "this directory is complete and safe to serve." Without it, a half-copied release becomes `current` and you serve a broken app. |
| 2: capture `prev` | Rollback target. Also the ledger written into the result frame. |
| 3: temp in the *same dir* | Rename across filesystems is not atomic. `/tmp` and `/var` may be different mounts. Same dir guarantees same fs. |
| 3: **relative** target | `releases/42`, not `/var/www/app/releases/42`. The app root can then be moved, bind-mounted, or restored to a different path and `current` still resolves. Costs nothing, removes a bug class. |
| 4: `mv -Tf` | `-T` is **essential**: without it, if `current` were somehow a directory, `mv` would move the symlink *into* it, creating `current/current` and leaving the app pointing at the old release with a success message. `-f` replaces. `mv(1)` on the same fs is `rename(2)`. Measured above: zero non-resolving samples across 4.4M. |
| 5: `previous` | Rollback is then just "swap to `previous`" — the same convergent operation, so it is trivially safe to retry. |
| 6: `sync -f` | Directory entry durability. Without it, a power cut after the swap can lose the rename while systemd is already restarting against it. |

### 7.1 Ordering relative to `systemctl restart`

**Swap, then restart. Never the reverse, and never `reload`.**

- systemd resolves `WorkingDirectory=/var/www/app/current` **at service start**.
  Restarting before the swap starts the *old* release; the subsequent swap
  changes nothing until the next restart, so the deploy reports `HEALTHY` for a
  release that is not running. The `X-Shipyard-Release` assertion in §6.1
  catches this — but do not rely on the assertion to save you from an
  ordering bug; enforce the order in the step sequence, not in a comment.
- `systemctl reload` does not re-exec `ExecStart`. Using it means the old binary
  keeps running and the deploy lies. **`restart` only.**

### 7.2 Permissions

| Path | Mode | Owner | Why |
|---|---|---|---|
| `releases/<n>/` | `0755` | `root:appsvc` | Build may run as a different user; app must read it. |
| `releases/<n>/.shipyard-ready` | `0644` | `root:appsvc` | The swap's precondition. |
| `shared/` | `0750` | `root:appsvc` | Only root and the service user. Not other apps. |
| `shared/.env` | `0640` | `root:appsvc` | systemd reads it; the app's user can read it; nobody else. |
| `current` | n/a | `root:root` | Linux ignores symlink permissions. Ownership is what matters. |

The `shipyard` agent user gets write access to `releases/` and `shared/` through
the sudoers rules, not by `chown`ing the tree — so a compromised `deploy.sh`
running as `shipyard` still cannot read another project's `shared/.env`.

### 7.3 Retention

```bash
# prune -- runs in a background step, never inline with a swap
set -euo pipefail
app_root=$1; keep=${2:-5}
# Never prune `current` or `previous`, whatever their numbers are.
cur=$(basename "$(readlink -f "$app_root/current" 2>/dev/null || true)")
prv=$(basename "$(readlink -f "$app_root/previous" 2>/dev/null || true)")
cd "$app_root/releases"
ls -1 | grep -E '^[0-9]+$' | sort -n \
  | head -n "-$keep" \
  | grep -vxF -e "$cur" -e "$prv" \
  | xargs -r -I{} rm -rf -- "./{}"
```

Numeric sort (`sort -n`), never lexicographic — `sort` gives `10` before `9`,
which would delete the wrong release once you pass ten deployments, and that is
precisely the sort of bug that only shows up in someone's third week of use.
Pruning is a separate background step so a slow `rm -rf` of a multi-GB release
never delays the swap the user is waiting on.

---

## 8. Config and secrets in Shipyard itself

### 8.1 The split

| Kind | Where | Examples |
|---|---|---|
| Non-secret config | env, with a TOML file for defaults | `SHIPYARD_HTTP_ADDR`, `SHIPYARD_DSN`, `SHIPYARD_MAX_CONCURRENT_DEPLOYS`, `SHIPYARD_LOG_LEVEL` |
| Startup secrets | `shipyard.enc`, `age`-encrypted | SSH private key, SSH passphrase, registry token |
| The passphrase | environment, from systemd `LoadCredential=` | `SHIPYARD_KEY_PASSPHRASE` |
| Per-project app env | Postgres, **encrypted at rest**, write-only | `DATABASE_URL`, `STRIPE_SECRET_KEY` |
| The git deploy key | the **target host only**, in `authorized_keys` | Shipyard never holds it |

Precedence: defaults → `-config` file → environment. Environment wins.

### 8.2 Fail-fast validation

```go
// internal/config/config.go
func Load() (*Config, error) {
    c, errs := defaults(), &Problems{}
    loadFile(&c, errs)     // never returns on first error
    loadEnv(&c, errs)
    errs.addIf(c.MaxPoolConns <= c.MaxConcurrentDeploys,
        "MaxPoolConns (%d) must exceed MaxConcurrentDeploys (%d): "+
        "each in-flight deployment holds a dedicated connection for its advisory lock",
        c.MaxPoolConns, c.MaxConcurrentDeploys)
    errs.addIf(c.StepBudget[StepSwap] > 30*time.Second,
        "StepBudget[swap] must be under 30s: the swap is the user-visible cutover")
    errs.addIf(c.SSHPrivateKey == "", "ssh private key is required")
    if len(errs) > 0 { return nil, errs.Err() }   // ALL problems at once
    return c, nil
}
```

Report **all** problems in one error, not the first. Someone who forgot
`SHIPYARD_PG_PASSWORD` should learn about it — and about the three other things
they also got wrong — in one second, on startup, not after their first request.
This is the highest ratio of perceived professionalism to effort anywhere in the
codebase.

### 8.3 Why `age` and not Vault

The realistic threat is "someone reads my laptop's disk, or my repo, or a
backup." Vault answers that question by adding another service, another port,
another backup, another failure mode, and a learning curve — a net *negative*
for a solo evenings-and-weekends project, and the single largest reliability
risk in the architecture.

`age` answers it with one static binary, no keyserver, no daemon, and no
server to operate:

```bash
# encrypt once, by hand, at the console -- never in CI
age -R ~/.config/shipyard/recipients.txt -o shipyard.enc
# shipyardctl seal   # symmetric, if no recipients.txt

# systemd, in production: the passphrase never touches disk
# /etc/systemd/system/shipyard.service
[Service]
ExecStartPre=/usr/bin/install -d -m 0700 -o shipyard /run/shipyard
LoadCredential=passphrase:/run/credentials/shipyard.service/age-passphrase
Environment=SHIPYARD_KEY_PASSPHRASE_FILE=%C/age-passphrase
```

`LoadCredential=` gives a tmpfs-backed file readable only by the service, so the
passphrase is never in the unit file, never on disk, and never in `ps`. That is
the right answer for a portfolio project, and it is a detail a reviewer will
notice.

### 8.4 Encrypted env values in Postgres

```sql
CREATE TABLE project_env (
  project_id uuid NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  name       text NOT NULL,
  value_cipher bytea NOT NULL,     -- AES-256-GCM, random 96-bit nonce prefixed
  value_sha   bytea NOT NULL,      -- HMAC-SHA256, for change detection w/o decrypt
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, name)
);
```

- **Write-only at the API**: no read handler ever returns `value_cipher`. GET
  returns `[{name, has_value, updated_at}]`. Enforced by the repository
  interface — there is no method that returns values, so a handler author
  *cannot* leak one by forgetting to strip it. The type system is the control.
- **Encrypted at rest** with a key derived from the master in `shipyard.enc`, so
  a `pg_dump` does not hand over every app's `DATABASE_URL` and
  `STRIPE_SECRET_KEY`. ~40 lines.
- `value_sha` allows "did this change?" without decrypting, which is what the
  agent needs to decide whether a redeploy is required.

### 8.5 What is deliberately not built

No automatic secret rotation (documented: rotate by re-running
`shipyardctl host enroll`), no secret manager integration, no per-tenant keys.
Rotation infrastructure for a project with one operator is a feature that will
never be exercised and will therefore be broken.

---

## 9. Error taxonomy and observability

### 9.1 The taxonomy

Every error the system produces is exactly one of these. Closed set, Go
constants, never free strings.

```go
// internal/domain/errors.go
type Code string

const (
    CodeUnknown              Code = "UNKNOWN"              // invariant broken — page
    CodeConfigInvalid        Code = "CONFIG_INVALID"        // operator misconfiguration
    CodeAuthFailed           Code = "AUTH_FAILED"           // ssh auth rejected
    CodeHostUnreachable      Code = "HOST_UNREACHABLE"      // connect/dns/timeout — retry
    CodeHostKeyMismatch      Code = "HOST_KEY_MISMATCH"     // possible MITIM — never retry
    CodeServerBusy           Code = "SERVER_BUSY"           // lock held — requeue
    CodeGitRefInvalid        Code = "GIT_REF_INVALID"       // ref does not resolve
    CodeGitAuthFailed        Code = "GIT_AUTH_FAILED"       // deploy key rejected
    CodeBuildFailed          Code = "BUILD_FAILED"          // deploy.sh exited != 0
    CodeBuildTimeout         Code = "BUILD_TIMEOUT"         // step budget exceeded
    CodeConfigRenderFailed   Code = "CONFIG_RENDER_FAILED"  // env render/write
    CodeNginxConfigInvalid   Code = "NGINX_CONFIG_INVALID"  // nginx -t failed — NOT reloaded
    CodeSystemdUnitInvalid   Code = "SYSTEMD_UNIT_INVALID"  // bad unit file
    CodeUnitUnstable         Code = "UNIT_UNSTABLE"         // crash loop in the window
    CodeHealthFailed         Code = "HEALTH_FAILED"         // never healthy — rolled back
    CodeRollbackFailed       Code = "ROLLBACK_FAILED"       // rollback also unhealthy — page
    CodeCircuitOpen          Code = "CIRCUIT_OPEN"          // breaker open — too many fails
    CodeCancelled            Code = "CANCELLED"             // operator cancelled
    CodeLeaseExpired         Code = "LEASE_EXPIRED"         // worker died — requeue
    CodeReconciledSwapNever  Code = "RECONCILED_SWAP_NEVER" // verdict: swap absent
    CodeReconciledIncomplete Code = "RECONCILED_INCOMPLETE" // verdict: swapped unready rel
    CodeContractViolation    Code = "CONTRACT_VIOLATION"    // agent broke the contract
    CodeAgentFault           Code = "AGENT_FAULT"           // agent invariant — alert
)
```

Each carries: `code` (machine), `message` (human), `detail` (structured
key/values), plus `deployment_id` / `step` where applicable. One constructor:

```go
func Fault(code Code, msg string, kv ...any) *Error
```

**Enforcement**: a golden test asserts the set of string constants equals an
exact list, so nobody can invent a code by accident. There are 24 codes, each
mapped to a retryable flag and an HTTP status, in one table that is itself
tested for completeness. Adding a code means touching the table, and the test
fails if you forget.

### 9.2 Metrics

```
shipyard_deployments_total{project,server,terminal_status}     counter
shipyard_deployment_duration_seconds{project,server}           histogram [30s 1m 2m 5m 10m 30m 1h]
shipyard_deployment_step_duration_seconds{step,result}         histogram
shipyard_deployments_in_flight{server}                          gauge
shipyard_job_queue_depth{state}                                 gauge
shipyard_job_wait_seconds{project}                              histogram   picked_up - created
shipyard_job_retries_total{reason}                              counter
shipyard_lease_expired_total{owner}                             counter
shipyard_health_probe_duration_seconds{project,result}         histogram
shipyard_health_probe_failures_total{project,kind}             counter
shipyard_rollbacks_total{project,result}                       counter
shipyard_circuit_state{project}                                 gauge  0 closed / 1 open
ssh_sessions_open{server}                                       gauge
ssh_exec_duration_seconds{verb,result}                          histogram
ssh_bytes_total{direction}                                      counter
journal_feeds_active{server,unit}                               gauge
journal_dropped_lines_total{server,unit,reason}                 counter
logstream_subscribers{kind}                                     gauge
logstream_dropped_frames_total{kind,reason}                     counter
build_log_bytes_total{project}                                  counter
build_log_truncated_total{project}                              counter
reconcile_runs_total{result}                                    counter
reconcile_verdicts_total{code}                                  counter
```

The four that matter most, and why:

- `shipyard_job_wait_seconds` — answers "why is my deploy not running?" which is
  the number one support question for any queue.
- `shipyard_deployment_step_duration_seconds` — tells you a build got slow
  before anyone opens a ticket.
- `journal_dropped_lines_total` — **silent data loss**. If this is nonzero,
  someone is reading an incomplete log and does not know it.
- `shipyard_lease_expired_total` — the control plane is flapping under its own
  load. It should be zero.

Label cardinality: `project` and `server` are UUIDs and are bounded by the
number of real hosts, which is fine. There is **no `deployment_id` label
anywhere** — that would be unbounded cardinality and would kill the Prometheus
server. Deployment identity goes in logs and in a trace, never in a label.

### 9.3 Structured log fields

JSON via `slog`. Every line carries:

```
ts level msg service version instance_id trace_id
deployment_id project_id server_id environment release_number commit_sha
step step_attempt job_id lease_owner err_code err_message
duration_ms ssh_session_id exit_code
```

Non-negotiables:

- **`deployment_id` on every engine log line.** It is the join key that makes
  `journalctl -u shipyard | jq 'select(.deployment_id=="...")'` possible.
- **`err_code` from the taxonomy**, never a bare error string as the
  classifier. "who is this?" must be answerable without reading the message.
- **`trace_id` generated at HTTP request entry**, threaded through the engine
  and exported into the Bash environment as `SHIPYARD_TRACE_ID` — so a line in a
  user's `deploy.sh` output can be correlated back to the control-plane log
  entry that caused it. Small detail; disproportionate value when debugging.
- **`instance_id`** is mandatory once `--role=api` and `--role=engine` can be
  separate hosts, so a log line can be attributed to a process.

`internal/telemetry` also sets up a `trace_id` in the logging context, so no
call site can forget it — a mistake here is a bug you find at 2am.

---

## 10. Testing strategy

### 10.1 The line: mock the transport, never the host

This is the whole strategy, stated once:

> **A Bash script's bugs are invisible to any Go test and are the entire bug
> surface of the execution plane. So the scripts are never mocked. Neither is
> systemd, nor nginx, nor journald. Only the SSH transport is mocked, and only
> in the unit tier.**

Mocking `deploy.sh` would mean asserting that Go called a function named
`Build` — a test that passes while the actual thing is broken.

### 10.2 Tier 1 — Go unit tests, no I/O

| Target | Technique |
|---|---|
| `domain` state machine | Table-driven over every `(from, to)` pair. Illegal transitions must error. Catches a late worker promoting a `FAILED` deployment to `RUNNING`. ~40 cases. |
| Reconciler | **Model-based**, see §10.4. The highest-value test in the repo. |
| Health + circuit breaker | Pure logic. Table-driven, including the doubling backoff and its 24h cap. |
| Env rendering | Golden files. |
| Config validation | Table of bad configs → expected error substrings. Includes the `MaxPoolConns` invariant. |
| Error taxonomy | Golden set of code strings; completeness of the retry/status table. |
| `nginx` block renderer | Golden `.conf` files, including the escape/quote cases. |

`domain` and `engine` target **95%+**; the repo target is 80%.

### 10.3 Tier 2 — integration against real Postgres

Require `SHIPYARD_TEST_DSN`; `t.Skip` when absent. No Docker, no testcontainers.
The SQL is the same SQL, and it starts faster.

- Real migrations applied to a scratch database.
- **Two `Locks` managers on two real connections** asserting the second gets
  `false`. Advisory locks cannot be meaningfully mocked; this test is the
  only reason §2.2 is trustworthy.
- The claim query under concurrency: N goroutines, M jobs, assert no job is
  claimed twice and none is lost.
- The lease reaper: claim, stop heartbeating, advance time, assert the job is
  reaped exactly once.
- The breaker under a real transaction with `SELECT ... FOR UPDATE`.

### 10.4 The reconciler model test

The test that justifies the whole recovery design:

```go
// TestReconcilerConvergence
// For every step index 0..6, every failure mode at that step, and every
// moment at which we can kill the process, assert that after recovery the
// (db_state, host_state) pair converges to the correct verdict.
func TestReconcilerConvergence(t *testing.T) {
    for _, stopAt := range allSteps {
        for _, mode := range []failureMode{modeClean, modeMidWrite, modeAfterSwap, modeHung, modeOOM} {
            t.Run(fmt.Sprintf("stop=%s/%s", stopAt, mode), func(t *testing.T) {
                host := newFakeHost()      // real filesystem, real symlinks
                db   := newRealDB(t)       // real Postgres

                runUntil(t, host, db, stopAt, mode)   // "crash": just stop
                v := newReconciler(host, db).walk(t.Context(), orphanedDeployment(t, db))

                assertVerdict(t, v, expectedVerdict(stopAt, mode))
                assertHostSafe(t, host)   // current always points at a ready release
            })
        }
    }
}
```

The `assertHostSafe` assertion is the point of the entire exercise: after
**every** crash point, `current` must point at a `.shipyard-ready` release and
the unit must not be crash-looping. A crash must never leave the site serving a
half-written directory. That property, exhaustively tested, is the deliverable.

`newFakeHost` uses a **real temp directory and real symlinks** — not a struct
with booleans — because the swap's correctness *is* a filesystem property.

### 10.5 Tier 3 — the real thing

**The scripts, on a real host, as a real user, against a real tree.**

```go
// internal/executor/testdata/bin/systemctl  — in PATH ahead of the real one
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SHIPYARD_TEST_LOG:?}"
if [ "${1:-}" = "is-active" ]; then echo "${SHIPYARD_FAKE_ACTIVE:-active}"; exit 0; fi
exit 0
```

`testdata/nginx` and `testdata/git` likewise. Then:

- Assert the **exact argv** the agent produced for every verb. This catches
  "forgot `mv -T`", "restarted before swapping", "used `ln -sfn`".
- Run `swap_link` against a real directory tree with real symlinks, then assert
  `readlink current` and that a concurrent reader never observes ENOENT
  (spawn 1000 readers in a loop during the swap). That is a real concurrency
  test of a real kernel guarantee.
- Run `deploy.sh` fixtures: one that succeeds, one that exits 1, one that hangs
  forever (asserts the timeout path and the SIGTERM-then-SIGKILL escalation),
  one that prints 200 MiB in 3 seconds (asserts the log cap and that the
  control plane's RSS stays flat).

**systemd and nginx, for real, in CI**, on a `ubuntu-latest` runner (it has
systemd as PID 1):

```go
func TestSystemdAndNginxReal(t *testing.T) {
    if os.Getpid() != 1 && !isCIContainer() { t.Skip("needs systemd as PID 1") }
    // install a real unit, start it, assert is-active; restart it; assert NRestarts
    // write a real server{} block, run real `nginx -t`, assert it FAILS on a
    // bad block and that the running config is untouched  <- the fail-closed test
}
```

That last assertion — that a bad block does **not** take down the server — is
the single most important assertion in the suite, and it is impossible to write
without a real nginx. Skip gracefully when systemd is not PID 1, so macOS
contributors are not blocked while CI stays authoritative.

**Journald is never mocked.** Cursor semantics are the entire point of §5; a
mock would be a lie that hides the exact bug the design exists to prevent. The
cursor-resume test runs against the host's real journal: read 100 lines, kill
the feed, resume from the cursor, assert the concatenation is exactly 100 lines
with no gap and no duplicate.

**E2E** — one test, against a real SSH-able local host, walking the full
lifecycle: create project → deploy a fixture repo → assert `current` == N, unit
active, `shared/.env` contents correct → deploy a deliberately broken commit →
assert **auto-rollback** and `current` back at N-1, with the failed release
still on disk. This single test demonstrates more than the other 400 combined.

### 10.6 CI gates

```bash
go test -race -count=1 ./...          # race on the pump and the hub, always
golangci-lint run
scripts/check-deps.sh                 # the tier rule from §1.3
shellcheck -x deploy.sh scripts/*.sh internal/**/testdata/bin/*
                                 # mandatory: a Bash execution plane without
                                 # shellcheck is negligent
```

Nightly: tier 3 against a systemd-enabled runner. PR: tiers 1-2 plus the
filesystem-level tests (they need no privileges).

---

## 11. Ten bugs you will hit if you build this naively

Ordered by likelihood.

**1. `ln -sfn` is not atomic — 502s and failed restarts, forever.**
`ln -f` does `unlink()` then `symlink()`, and the target is absent for the whole
gap between them. Measured on this machine: a reader resolving `current` while
a writer performs 500 000 `ln -sfn`-style swaps failed to resolve **1 346 839
times out of 2 087 195 samples — 64.5%**. The `symlink()`+`rename(2)` form had
**0 failures in 4 387 001 samples**. The window is bounded only by the
scheduler, so under load it stretches to milliseconds. `WorkingDirectory` →
ENOENT, `try_files` → 502, and you spend a week blaming nginx connection
limits because the failure is invisible and unreproducible.
*Fix:* `ln -s` to a temp name **in the same directory**, then `mv -T`
(= `rename(2)`, atomic). §7. Four lines. Never `ln -sfn`.
Reproduce: `cc -O2 -pthread -o swaprace docs/swaprace.c && ./swaprace 500000`.

**2. Retrying a build in a dirty release directory corrupts `node_modules`.**
`npm ci`, `pip install`, and cargo all write into the existing tree. Interrupt
one at step 900 of 1000; the retry finds a half-populated `node_modules` and
either fails mysteriously or produces a subtly wrong build. The symptom points
at the registry, not at you, and you lose an evening to it.
*Fix:* the release number is allocated once in the API transaction (§2.4.1); a
retry does `rm -rf releases/<N>` first, and builds into `.build/`, moving into
place only on success. A failed build never leaves a directory that looks
complete.

**3. Retries allocate a new release number — orphaned releases and a double
swap.** If `release_number` comes from `max()+1` at execution time, a crash
after the swap plus a retry allocates `N+1`. Now `N` is orphaned, `previous`
points at the wrong release, and the reconciler's core comparison
(`current == N`?) has lost its meaning — it can no longer distinguish success
from failure. The system becomes unable to recover from the very crash it was
built to survive.
*Fix:* allocate in the API transaction with `UNIQUE (project_id, release_number)`.
The number is part of the deployment's *identity*, not a side effect of
*executing* it.

**4. `shared/.env` written in place → truncated env → mystery crash loop.**
`>> shared/.env` or an in-place `os.WriteFile`, interrupted, leaves a partial
file. The service restarts against garbage and crash-loops — hours after the
deploy that caused it, so the causal link is invisible. Separately, an
append-only render never removes deleted variables, so a stale
`OLD_DATABASE_URL` outlives its removal and quietly wins.
*Fix:* render the **complete** desired set to a temp file, `fsync`, `mv`
(atomic `rename(2)`), `chmod 0640`. Never append; never write in place. §3.4.3.

**5. The advisory lock is taken on a pooled connection, so it is a no-op.**
`pool.QueryRow("SELECT pg_try_advisory_lock(...)")` acquires the lock on
*some* connection. The next query borrows a *different* one, and the first is
returned to the pool — releasing the lock. You believe you have per-server
mutual exclusion. You have none. This passes **every single-process dev test**
and breaks the first time a second control plane exists, which in practice is
during a rolling restart, when you can least afford it.
*Fix:* `conn, _ := pool.Acquire(ctx)`; run the lock, the entire deployment, and
the unlock on that one `conn`. Write the two-connection test from §10.3 that
asserts the second `try` returns `false` — it takes 15 lines and it is the only
thing standing between you and concurrent deploys to the same host.

**6. A dead control plane holds the server lock forever, and nothing deploys.**
A session advisory lock is released when the connection dies — but a
half-dead process's TCP session lingers in `ESTABLISHED` until timeout, which is
minutes, or forever without keepalives. Every subsequent deploy to that server
gets `SERVER_BUSY` and requeues. No deploys happen. No errors are logged.
Total silence, which is the worst possible failure mode because nothing pages.
*Fix, defence in depth:* (a) the `lease_expires_at` reaper is **independent** of
the lock, so a lost lock is not a lost deployment; (b) `ServerAliveInterval:
15s` on the SSH client bounds the TCP lifetime; (c) on graceful shutdown,
explicitly unlock and close before exiting; (d) a `shipyard_job_queue_depth`
gauge with an alert on `state="pending"` growth, because silence must be
*loud* somewhere.

**7. `journalctl --since` resume loses and duplicates log lines.**
Timestamps are not a stable cursor. Entries sharing a microsecond order
arbitrarily; Go's clock and journald's `__REALTIME_TIMESTAMP` can disagree;
timezone handling is a footgun. The user sees duplicated or missing lines in
runtime logs and reports it as a correctness bug, and you cannot reproduce it
because it depends on timing.
*Fix:* `--show-cursor` + `--after-cursor`, storing the `s=` cursor. This host has
both. The cursor is a monotonic position in the journal and the resume is exact.
§5.1.

**8. One `journalctl -f` SSH process per browser tab.**
The naive implementation opens an SSH session and a `journalctl -f` per SSE
subscriber. Twenty open tabs is twenty journald cursors all streaming identical
data, twenty SSH processes, and roughly 5× the host CPU for zero benefit. A
browser crash-restore can spawn forty at once. It looks fine in testing, where
you have one tab.
*Fix:* one refcounted `Feed` per `(server, unit)`, multiplexed to N subscribers,
idle-reaped after 60s. §5.2.

**9. nginx is reloaded with an invalid config — taking down every site on the
box.** `nginx -t` fails, the exit code is lost in a subshell, and the reload
proceeds. One project's typo takes out every other site on the host, because
they all share one nginx process. This is the highest-*impact* bug on the list
even though it is not the most frequent.
The mirror-image variant: on Debian/Ubuntu, `sites-enabled/*` is a symlink into
`sites-available/`; writing the real file without re-linking means nginx is
still serving a config you believe you changed, and the deploy reports success
while the old release is live.
*Fix:* `set -o pipefail` and `nginx -t || { ...; exit 20; }` **in the same
script**, with the exit code propagated; `ln -sfn` into `sites-enabled` as part
of the same step; and verify with `nginx -T | grep -q '<server_name>'` after the
reload. Fail closed, always.

**10. `systemctl restart` fires before the swap — or `reload` is used — and the
deploy reports HEALTHY for a release that is not running.**
systemd resolves `WorkingDirectory=/var/www/app/current` **at start**. Restart
first and you start the old release; the swap afterwards changes nothing until
the next restart. nginx then caches the resolved upstream, and you get
intermittent 502s until something forces a reload.
*Fix:* enforce swap → restart in the step sequence (not in a comment), and
`restart` never `reload`. The `X-Shipyard-Release` header assertion (§6.1) turns
this silent wrong-deploy into a loud failure — which is why it is the default
health check rather than an optional extra.

**Honourable mentions** (real, less likely): `shared/` and `releases/` landing
on different filesystems, which makes `mv` a non-atomic copy — check
`stat -c %d` and never configure them on separate mounts; a build that writes
to `current/` (a stray `npm install` in the wrong cwd) silently mutating the
symlinked release, so the release is no longer immutable and "rollback"
restores a mutated tree — hence `.shipyard-ready` plus a read-only check; a
backgrounded process in `deploy.sh` (`nohup`, `setsid`) holding the SSH channel
open until it exits, so the build "hangs" long after it finished and burns the
whole timeout; and `deploy.sh` piping to `head`, which closes the pipe, sends
`SIGPIPE`, and exits 141 — a spurious "build failure" that costs an hour of
debugging a one-line shell script.

---

## Appendix: the step sequence, end to end

```
PENDING → CLONING → BUILDING → CONFIGURING → STARTING → HEALTHY → RUNNING
             │           │            │            │          │
             │           │            │            │          └─ verify: 3 consecutive
             │           │            │            │             successes, release header
             │           │            │            │             matches, symlink correct
             │           │            │            └─ start: swap(current→N) FIRST,
             │           │            │               then systemctl restart
             │           │            └─ config: render COMPLETE env → tmp → mv
             │           └─ build: rm -rf N; clone; .build/; touch .shipyard-ready
             └─ clone: git fetch <sha>; git checkout --detach <sha>
```

Three properties, in order of how much they are worth:

1. **Nothing touches `current` until step 5 of 6.** Every expensive,
   failure-prone phase is offline, so a failed build has literally zero user
   impact. Failure isolation is structural, not procedural — no rollback code
   needs to run, because nothing was at risk.
2. **Every step is convergent**, so recovery never needs to know "how far did it
   get" — only "is the desired end state true". That is what makes §2.3 a
   decision table rather than a state machine that has to guess.
3. **Rollback is the same operation as deploy**, because both are
   "make `current` point at release M". One well-tested path instead of two.
