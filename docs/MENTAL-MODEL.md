# Shipyard — Mental Model & Roadmap

> Synthesis of 9 specialist analyses (platform, backend, devops/SRE, API, DBA,
> Postgres, frontend, UI/UX), then **corrected against empirical research** on a
> live PostgreSQL 18.6 instance and authoritative Linux/git docs. This document
> is the **canonical** mental model. The raw analyses in `docs/` are inputs, not
> spec. Where they disagree, the adjudications in §5 win. Where a claim was
> empirically disproved, the correction is marked "verified" inline and
> detailed in `reference/Shipyard build primitives/VERIFIED.md`.

---

## 0. The one-sentence model

Shipyard is a **write-ahead intent ledger + a single serial Bash executor**,
where the ledger is Postgres, the executor is SSH into Linux, and the only
source of truth about "what is actually running" is the target host — not the
database.

Everything else is consequence:

- Postgres records **what we meant to do** (intent).
- The host filesystem + systemd records **what is actually true** (reality).
- Reconciliation is the narrow, self-healing gap between them.
- The UI, API, and state machine are read models over that gap.

---

## 1. The three planes (why the codebase splits the way it does)

| Plane | Owns | Never does |
|---|---|---|
| **UI** (Next.js) | Rendering, optimistic state, log viewer ergonomics | Any mutation that isn't an API call |
| **Control plane** (Go, one binary) | Ledger, state machine, lease/claim, secrets, log writer | Touch a target host directly |
| **Execution plane** (Bash, on the host) | git/systemd/nginx/symlink/files | Decide anything; persist state; call the API |

The invariant that makes this tractable: **only Bash mutates a host.** Go
dispatches, observes, and records. It never writes a unit file, never flips a
symlink, never restarts a service. This is why the release swap is the most
important thing in the project: it is the one place where "the new release is
live" actually happens, and it must be atomic. You will write it by hand in
Phase 1 — the recipe is in `docs/ROADMAP.md` §1.2, and the rules it must obey
are in §8.1 below.

Docker remains **lab-only**: containers are just Linux hosts you can `ssh` into.
The engine is built once and reused.

---

## 2. Core domain (5 entities + 3 support tables)

```
servers ──┐
          ├──< deployments >── deployment_events      (the audit spine)
projects ─┤        │  │
          │        │  └──< deployment_services >── services   (systemd units)
          │        │
          └──< environment_revisions ──< environment_variables   (secrets, encrypted)

reconcile_runs    (batch outcome of every host sweep)
audit_log         (purge/override/delete audit)
```

- **Server** = a host. **Project** = a logical app. **Service** = a systemd unit
  a project runs (a project may have web + worker). A **Deployment** is *one
  immutable commit SHA on one server* — the atomic unit of rollback.
- `services` is **per-project** (not per-server). `unit_name` is stored, never
  computed at read time — it is a contract with the host, and reconciliation
  compares a stored expectation against `systemctl show` output.
- **Environment revisions** make a deploy reproducible: a run records *which*
  revision it used, never the values themselves (in the API; values live
  encrypted in the DB).

The MVP must be demoable with **zero services and zero explicit environments**
configured — a project deploys to a single derived unit against a default
`production` revision. The tables exist for when you need them, not before.

---

## 3. The crux: three orthogonal status axes

Most designs collapsed these into one `status` column. That's the bug. There are
**three different questions**, and conflating them is why draft migrations keep
breaking:

| Axis | Question | Owner | Column |
|---|---|---|---|
| **State** | What step is this run at? | Engine (intent) | `state` + `state_seq` (CAS token) |
| **In-flight** | Is a worker on it right now? | Derived | `slot_busy` (GENERATED) |
| **Active** | Is this the LIVE one on the box? | Host reality / reconciler | `is_active` + `active_verified_at` |

- **State machine (9 states, lowercase).** Terminal = `running | failed | canceled`.
  ```
  pending → cloning → building → configuring → starting → health_checking → running
     ↘         ↘          ↘           ↘            ↘               ↘            ↘
                             failed  (reachable from any non-terminal)
  cancel (abort_requested_at) → canceled   (any non-terminal, operator-forced)
  ```
  `health_checking` (not `HEALTHY`) because there is a real gap between "health
  passed" and "promoted/serving". `canceled` is a real terminal state the API
  and SRE both need.
- **In-flight** is a `STORED` generated column over the 6 pre-terminal
  non-failed states. A `UNIQUE (project_id, server_id) WHERE slot_busy` index
  turns a second concurrent deploy into `409 {reason: "deploy_in_flight"}`.
  Deriving it means it can never drift and it vanishes when the run ends.
  **Verified on PG 18.6:** a generated column over an *enum membership test* is
  legal (it is immutable), and the partial unique index on it is enforced by the
  database — a second in-flight insert raises `duplicate key ... d_one_inflight`,
  and the slot frees automatically at a terminal state. Never build a generated
  column over `now()` (not immutable — rejected by the server). Always write
  `STORED` explicitly: the bare default flipped to `VIRTUAL` in PG 18.
- **Active** is set true in the *same transaction* that flips the old one false
  at the `health_checking → running` boundary, and otherwise corrected only by
  the reconciler reading the host's `current` symlink. "At most one" is a DB
  invariant; "exactly one" is true except in a narrow, self-healing window you
  close with reconciliation + an `active_verified_at` staleness alert — you
  cannot put Postgres and a remote filesystem in one transaction.

**Write model.** `deployments.state` is a denormalized cache of the last
`state_change` event. `deployment_events` is the authority. Every transition
writes both in one transaction (CAS on `state_seq`, fenced by
`lease_generation`). The hot path stays a single-row read; the audit trail is
unlosable. ~8 events/deploy × ~1,440 deploys/yr ≈ 8 MB/yr — a rounding error for
an unlosable failure timeline.

---

## 4. Claiming & locking: lease + fencing, no queue table

**The work list is a query, not a table.**

```sql
-- claim: the deployments row IS the queue item
SELECT id, project_id, server_id, state_seq, environment_revision_id, log_path
FROM deployments
WHERE state NOT IN ('running','failed','canceled')
  AND (lease_expires_at IS NULL OR lease_expires_at < now())
ORDER BY coalesce(lease_expires_at, '-infinity')   -- most-overdue first
FOR UPDATE SKIP LOCKED
LIMIT 1;
-- then: lease_owner=$worker, lease_expires_at=now()+ttl, lease_generation=lease_generation+1
```

**Why no `deployment_jobs` queue table** (the backend design's proposal,
explicitly rejected): a second table holding a copy of "what needs work" is a
table that can disagree with `deployments`, and a queue that is only drained by a
healthy worker is exactly the thing that silently grows forever during an outage.
The `deployments` row *is* the queue item.

**Fencing, not advisory locks.** `lease_generation` is a monotonic integer
bumped on every claim. A zombie worker that wakes up holding a stale
`lease_owner` fails the CAS (`WHERE … AND state_seq = $prev AND lease_owner =
$worker`) and is harmless. A Postgres trigger
(`SET LOCAL shipyard.worker_id` GUC == `OLD.lease_owner`) makes "only the lease
holder advances this run" a **database** guarantee, not a code-review comment.
An advisory lock per server is fine as an optional belt-and-braces on a single
node, but it is not the primary primitive — it dies with the session and leaves
no audit trail.

> **The `FOR UPDATE SKIP LOCKED` CTE trap — verified.** Putting the locking
> clause *outside* a CTE reference makes Postgres **silently ignore it**:
> `WITH cte AS (SELECT …) SELECT … FROM cte FOR UPDATE SKIP LOCKED` returns rows
> that are **not locked** (confirmed: no `LockRows` node in the query plan).
> The correct form puts the lock **inside** the CTE (or filters inline):
> `WITH cte AS (SELECT … FOR UPDATE SKIP LOCKED) SELECT … FROM cte`
> (confirmed: `LockRows` present). This is a correctness bug, not a perf one.

### 4.1 Why the lease exists at all (corrected after experiment)

The original rationale — "`SKIP LOCKED` hides a dead worker's row forever" — is
**false**, and was disproved by experiment on PostgreSQL 18.6. Row locks are
**transaction-scoped** and released when the transaction ends *or the backend
dies*. Verified sequence:

1. Worker A: `BEGIN; SELECT … FOR UPDATE;` → holds the lock.
2. Worker B: `FOR UPDATE SKIP LOCKED` → correctly skips (lock is real).
3. Worker A is **crashed mid-transaction** (`pg_terminate_backend`).
4. Worker B retries → **immediately claims the row.** Locks were released.

The lease is still mandatory — but for a *different* reason. **The claim
commits, and then the worker spends minutes doing external work** (SSH clone,
build, health check). A crash *after* commit leaves durable in-flight state with
**no lock and nobody to reclaim it**. So the two mechanisms solve orthogonal
problems:

- `FOR UPDATE SKIP LOCKED` → prevents **concurrent** claims.
- `lease_expires_at` + `lease_generation` → recovers **committed-but-abandoned**
  claims (the common crash: worker dies minutes after claiming).

**Reconciliation** (every 15s + once at boot): any non-terminal run with a
dead/absent lease is reconciled *against the host* (does the release dir
exist? is the artifact there? is the unit active?) before re-queueing — not
blindly resumed. Decisions (in priority order): `abort_requested_at` →
`canceled`; unit active+healthy but non-terminal → `running`; unit inactive
but release exists → restart or `failed(systemd_start_failed)`; release
missing mid-build → resume or `failed(build_interrupted)`; no `current` at all
→ `failed(release_missing)`.

---

## 5. Decision log (the 12 adjudications)

| # | Decision | Rejected | Because |
|---|---|---|---|
| D1 | No queue table; `deployments` row is the queue | `deployment_jobs` + SKIP LOCKED (backend) | A second table holding "what needs work" can disagree with `deployments`; a queue only drained by a healthy worker grows forever during an outage |
| D2 | Lease + `lease_generation` fencing (primary) | Session advisory lock (backend) | Advisory lock dies with the session and leaves no audit trail; the lease recovers *committed-but-abandoned* work — see §4.1 |
| D3 | 9 lowercase states incl. `health_checking`, `canceled` | 8 uppercase states (backend, migration) | Need the promote-gap state and cancel; one canonical list |
| D4 | Three axes: `state` / `slot_busy` / `is_active` | Single `status` or `active` boolean | In-flight ≠ live-on-host; conflating them is the recurring bug |
| D5 | `deployment_events` audit spine is mandatory | none | 8 MB/yr for an unlosable failure timeline + rollback graph |
| D6 | Build logs = **files** via `LogSink` interface | `deployment_logs` table (migration) | 10–20× storage for zero capability; but `LogSink` is an interface so S3/B2 can land later |
| D7 | `services` is **per-project** (postgres-pro draft had per-server) | per-server unique (migration) | `unit_name` is a host contract; one definition, many servers |
| D8 | Secrets: encrypted in DB (AES-GCM), **never** in API responses; expose `env_fingerprint` only | sentinels / `content_hash` on the wire (api draft) | Wire can never carry values; fingerprint enables drift detection without them |
| D9 | Log streaming = **SSE from day one** (cursor + resume) | polling (platform MVP) | Build logs are real-time; polling needs a cursor anyway for reconnect → SSE is less total code |
| D10 | Keep env + service tables; MVP works without them | "cut to 3 entities" (SRE) | SRE's *spirit* is right (zero-config demo path) but the tables are what make it production-grade |
| D11 | Claim with inlined enum literals + partial index on `coalesce(lease_expires_at,'-infinity')`; `FOR UPDATE SKIP LOCKED` **inside** the CTE | Param-driven claim; lock outside a CTE | Verified: inlined form → `Index Scan` (O(queue depth)); lock outside CTE → silently not locked |
| D12 | Status column: `text` + `CHECK` (not native ENUM) | `CREATE TYPE … AS ENUM` | `ALTER TYPE … ADD VALUE` can't run in the same txn that uses the value; enums are forward-only and painful to evolve |

**The schema does not exist yet — you write it by hand in Phase 2.** An earlier
agent-produced migration was analysed, found to violate D2, D4, D11, and D12, and
removed; it remains in git history (`git show b3fa356`) as a record of a rejected
design. There is no `db/` directory. The spec for what you will build is §3 (the
three axes) and §4 (claim/lease) above, constrained by
`reference/Shipyard build primitives/VERIFIED.md` §1, which contains the
PostgreSQL traps that are otherwise invisible.

---

## 5.1 House conventions — inherited from `tenantflow`

Shipyard deliberately reuses the engineering conventions already proven in
`/home/ssk/Code/Projects/building/tenantflow`. Consistency across projects is worth
more than theoretical purity. These are inherited *as-is* unless noted.

### Go

| Convention | Rule |
|---|---|
| **Router** | stdlib `net/http` `ServeMux` with Go 1.22+ method+pattern routing (`"POST /api/v1/deployments/{id}/cancel"`). **No gin/chi/echo.** |
| **Interfaces at the consumer** | Each handler package declares the interfaces it needs (`type DeploymentStore interface{…}`). Concrete implementations live in the owning package. Dependency inversion without a DI framework. |
| **Middleware** | Plain closures wrapping `http.HandlerFunc` (`reader := func(h http.HandlerFunc) http.Handler`). No middleware framework. |
| **Config** | Plain struct + `Load() (Config, error)`. Helpers `getEnv`/`getEnvInt`/`getEnvBool` with defaults; invalid values return an error rather than silently defaulting. |
| **Logging** | `log/slog`, injected as `*slog.Logger`. Env switch: JSON in production, human-readable text otherwise. `io.Writer` injected, not global. |
| **Errors** | `fmt.Errorf("action: %w", err)` to wrap; `errors.As` for typed errors; handlers map domain errors to status codes at the edge via `writeError(w, status, msg)`. No error string parsing. |
| **Context** | `r.Context()` threaded through every layer; context is the first parameter, never stored in a struct. |
| **Integration tests** | Build-tagged: `//go:build integration`, run via `go test -tags integration ./internal/...` against **real** services. Unit tests use hand-written stubs, not mocks from a framework. |
| **Makefile = the CI contract** | Targets mirror CI gates exactly: `fmt-check`, `vet`, `build`, `test`, `integration`, `race`, `check`. |

### Docker / Compose

| Convention | Rule |
|---|---|
| **All values interpolated** | Every port, image version, and credential comes from `.env` (`.env.example` committed, `.env` gitignored). Nothing hardcoded in compose. |
| **Pinned versions** | `postgres:18.6`, not `postgres:18`. Verified behaviour must be reproducible. |
| **`container_name` always set** | So `docker exec`/logs commands are predictable. |
| **Restart policy by role** | `unless-stopped` for long-running; `on-failure:N` for one-shot init jobs. |
| **`depends_on` with a condition** | `condition: service_healthy` or `service_completed_successfully`. **Never a `sleep`.** Ordering is declared, not hoped for. |
| **Every service gets a `healthcheck`** | Plus `logging: driver: local, max-size, max-file` — bounded logs, which matters when fault-injection repeatedly kills processes. |
| **Named networks and volumes** | `networks: {name: shipyard}` so the network is stable regardless of project directory. |
| **One-shot init as a service** | Schema/seed application is a first-class container, not a manual step. |

### Web (`web/`, not `ui/`)

| Convention | Rule |
|---|---|
| **Stack** | Next.js 16 App Router · React 19 · Tailwind 4 · shadcn 4 (`@base-ui/react`, not Radix) · TypeScript strict. |
| **Layout** | `web/app/api/*` proxy routes → Go engine, `web/app/dashboard/*` UI, `web/components/ui/*` shadcn primitives, `web/lib/{api,types,utils}.ts`. |
| **BFF** | The browser never talks to the Go engine directly. `web/lib/api.ts` wraps `fetch` and throws `ApiFetchError` **preserving the upstream HTTP status** so proxy routes pass `409` through accurately. |
| **Types** | `web/lib/types.ts` mirrors the Go models. Hand-maintained, generated later only if it becomes a proven pain point. |

### Deliberate deviations from `tenantflow`

These are conscious, not accidental.

1. **Vertical slices, not horizontal layers.** `tenantflow` uses
   `model/repository/service/handler`. Shipyard has one complex aggregate with a
   state machine, a work queue, and a reconciler; horizontal slicing scatters a
   single state machine across three packages. Shipyard instead owns the aggregate
   whole:
   ```
   cmd/shipyard/        single binary: API + worker goroutine + reconciler goroutine
   internal/config/     env → Config
   internal/logger/     slog construction
   internal/database/   pgx pool + go:embed migrations
   internal/deployment/ the aggregate: types, state machine, queries, CAS transitions
   internal/exec/       SSH client, script running, output streaming
   internal/reconcile/  lease detection, host inspection, repair, is_active writer
   internal/httpapi/    handlers + router (thin, no business logic)
   web/                 Next.js + shadcn UI
   db/migrations/       SQL files — source of truth, also embeddable
   deploy/phases/       the Bash execution plane, one script per phase
   infra/lab/           lab fleet: Dockerfile + compose.yaml
   ```
   The *conventions* (stdlib router, consumer-side interfaces, ctx-first, slog,
   wrapped errors) are inherited unchanged — only the package boundaries differ.

2. **One binary, not `cmd/api` + `cmd/worker`.** Splitting is defensible, but the
   crash-recovery story is stronger when a single process is the whole engine:
   killing it stops everything, and restarting it triggers reconciliation. The
   counter-argument (a worker panic must not kill the reconciler) is deferred —
   if it ever bites, supervised processes split cleanly along this boundary.

3. **Migrations are embedded, but the SQL files remain the source of truth.** Same
   files run under `psql` for debugging and under `go:embed` at boot for a
   self-contained binary. Not two migration systems — one file set, two consumers.

4. **SSE transport is still open.** `tenantflow` proxies through Next.js route
   handlers; route handlers can buffer, which is fatal for a live event stream.
   Preferred: a Next.js `rewrites()` proxy, which streams. See §9.

---

## 6. API surface (shape, not spec)

REST + OpenAPI 3.1 under `/v1` (Go boundary → no tRPC). Full endpoint list in
the API design; the load-bearing decisions:

- `POST /deployments` → `201 {state: "pending"}` immediately; work is async.
- Read state with polling + **ETag** (`If-None-Match` → `304`).
- Build logs stream over **SSE** with a monotonic `seq` cursor + `Last-Event-ID`
  resume; server is authoritative for reconnection.
- Env writes are **write-only** (no GET returns values); optimistic concurrency
  via revision `ETag`.
- Idempotency-Key on every mutating call; `409` carries a machine `reason`
  (e.g. `deploy_in_flight`, `lease_conflict`).
- Error envelope is uniform and stable: `{error:{code,message,details}}`.
- Opaque cursors everywhere; never a real timestamp in a page token.

---

## 7. Roadmap — lab-first, each phase independently demonstrable

**`docs/ROADMAP.md` is the single authoritative build plan.** Do not maintain a
second phase list here — a duplicated roadmap is a divergent roadmap, which is
how this project already produced three incompatible designs.

The shape, in one line: the moat is the lab (a real, proven Linux deploy loop);
everything after it is a viewer. Bottom-up from the atomic release swap, and
every phase ends in something you can *do*, not something you can *diagram*.

| Phase | Deliverable |
|---|---|
| 0 | Toolchain + a real Linux host you can SSH into |
| 1 | Golden path: `deploy.sh <sha>` clone → build → swap → restart → health → rollback |
| 2 | Go engine: schema + claim/lease + state machine + SSH driver |
| 3 | `/v1` REST + SSE logs |
| 4 | Next.js deploy dashboard |
| 5 | Hardening: the six production-grade tests, secrets, nginx |

Phases 1 and 2 are the load-bearing ones. **Do not start Phase 3 (API) or 4
(UI) until Phase 2's kill -9 → reconciler test passes.** A control plane that
can't survive its own crash isn't "production-grade," it's a demo with extra
steps.

---

## 8. What "production-grade" is measured against

Not a vibe. Six properties, each with a test (from the SRE analysis):

1. **Terminality** — every run reaches exactly one of running/failed/canceled,
   on its own or via reconciliation. Test: kill the DB, kill the engine, let
   expire, restart → no run is ever stuck non-terminal.
2. **Write-ahead** — state is written *before* the host is touched. Test: power
   loss mid-`mv` → reconciler sees intent, converges.
3. **Convergence** — a crashed step is resumed by *inspecting the host*, not by
   retrying blindly.
4. **Fail-closed** — bad nginx config never reaches `reload` (test `nginx -t`
   first); a half-written release never becomes `current` (ready-marker gate —
   you build this in Phase 1).
5. **Reversibility** — any deployment rolls back to any prior SHA, reproducibly.
6. **Reproducibility** — deploy #N of a SHA produces a byte-identical release.

### 8.1 Executor constraints (verified — these are load-bearing)

Property 4 (fail-closed) and 5 (reversible) are only true because of specific
Linux behaviours. Each was verified; details and citations in
`reference/Shipyard build primitives/VERIFIED.md`. Do not "simplify" these.

- **Explicitly `systemctl restart` after the swap.** `.path` units do **not**
  reliably fire on atomic symlink replacement — the swap gives the symlink a new
  inode, inotify emits `ATTRIB`+`DELETE_SELF`, and `PathChanged=`/
  `PathModified=` miss it (systemd [#17727](https://github.com/systemd/systemd/issues/17727),
  [#31941](https://github.com/systemd/systemd/issues/31941); still broken on
  256.8). The unit file is **stable** and points at `current/`; `daemon-reload`
  is needed only when the unit *file* changes, never when the symlink target
  does. systemd resolves `ExecStart` at exec time, so restart picks up the new
  release. **Never** put the unit file inside `releases/` — deploy #2 breaks
  its paths.
- **Fetching a specific commit SHA is not one reliable command.** Shallow
  fetch-by-SHA requires server-side `allow-reachable-sha1-in-want`: GitHub.com
  has it, **GitHub Enterprise does not enable it by default**, and without it the
  deploy fails on a repo that works fine in a browser. Use a **fallback ladder**
  (shallow-by-SHA → blobless/full clone → fetch the SHA) so the engine is
  portable across git hosts.
- **journalctl cursors fail open across boots.** A `--after-cursor` resume
  cursor is boot-scoped and its format is "private and subject to change." A
  garbage cursor fails *closed*, but a cursor from a **different boot ID fails
  open silently** — so exit-status checking alone is insufficient. Persist and
  compare `/proc/sys/kernel/random/boot_id` and re-read fully on mismatch. (Also
  avoid `journalctl -I <id>`: short `-I` takes no argument. Use
  `_SYSTEMD_INVOCATION_ID=<id>` (v232+) or `--invocation=<id>` (v257+).)
- **A detached remote job needs a subshell.** `exit` inside a remotely-run
  script skips the wrapper's exit-code write, so run it as `( script )`. Use
  **TERM** for cancellation — POSIX makes async background jobs inherit
  `SIG_IGN` for INT/QUIT, so `SIGINT` cannot be trapped. `SIGKILL` is
  unreportable, so the poller must also check liveness rather than waiting
  forever for a result file that will never appear.
- **Nginx is fail-closed only if you make it so**: write the new config to a
  temp file *in the same directory*, `mv -T` it into place, `nginx -t`, and
  only `systemctl reload` on success. `reload` (not `restart`) keeps live
  connections.

---

## 9. Open questions (deliberately deferred, not blocking)

- **Multi-server projects** — schema supports it (`project_id, server_id` slot
  per server); MVP ships single-server. The cutover-across-servers flow
  (two-phase, `supersedes_deployment_id`) is designed-in but unfinished.
- **Log second sink** — `LogSink` interface exists; S3/B2 impl lands only if
  the control plane ever runs multi-node or on evictable disk.
- **`Environment` → `desired_state` promotion** — `abort_requested_at` covers
  the one real operator-forced transition (cancel). Promote to
  `desired_state` only if a real pause/resume/force surface appears.
- **Auth** — single admin bearer token for MVP; the API's auth model is a
  boundary, not a design.
- **Migrate-vs-redeploy** — not designed. Rollback (re-run a prior SHA) is the
  MVP answer; true zero-downtime migrate is a v2+ problem.
