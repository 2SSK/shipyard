# Product Requirements Document — Shipyard

**Status:** v1 (approved for build)
**Owner:** sskbtw
**Canonical docs:** `README.md` (goal) · `docs/MENTAL-MODEL.md` (architecture) · `docs/ROADMAP.md` (sequencing — authoritative for build order) · `reference/` (verified facts + citations)

> **Precedence.** Where this PRD and another document disagree, `docs/MENTAL-MODEL.md` wins on architecture and `reference/Shipyard build primitives/VERIFIED.md` wins on empirical fact. This PRD is authoritative on *product intent only*.

---

## 1. Problem Statement

Managed deployment platforms (Vercel, Netlify, Render) hide the machine. A developer pushes code and receives `Ready`. No git clone is observable, no build log is trustworthy, no `systemctl restart` is visible, and a crash mid-deploy requires a human.

**Shipyard inverts this: the machine is the point.** Every step of a deployment — clone, build, configure, symlink swap, service restart, health check — is visible, auditable, and recoverable after a crash without human intervention.

## 2. Product Thesis

> *What does a deployment platform look like when it is built from Linux primitives instead of abstractions?*

This thesis is only defensible if the control plane is genuinely host-agnostic. Therefore:

**Constraint (non-negotiable):** The Go engine reaches every target over **SSH**. It never imports a Docker client, never calls a container API, never knows its targets are containers.

The lab fleet is Docker containers; the engine cannot tell. This is what makes the project a *control plane for Linux servers* rather than a Docker orchestrator — a claim that must survive a `git remote add` and a real VPS with zero engine changes.

**Portability acceptance test:** deploying to a real VPS requires adding a `servers` row and a file path change. **No Go code changes.**

## 3. Personas

| Persona | Role | Needs |
|---|---|---|
| **Primary — the Operator** | The person running Shipyard (likely the author). Wants to see and trust every deploy. | Per-step logs, honest state, ability to cancel, evidence of crash recovery. |
| **Secondary — the Viewer** | A peer or hiring manager evaluating the project. Arrives with no context. | A single live page that shows a real deployment progressing step by step, and a clear story of why it survives a crash. |

## 4. Goals

- **G1 — Visible deploys.** Every phase transition produces a durable, ordered event within one second of occurring.
- **G2 — Crash recovery.** Killing the engine mid-deploy at any phase must resolve to a correct terminal or recoverable state with **no human action**.
- **G3 — One writer per fact.** Any given fact has exactly one writer. Go records intent; the host reports reality; the reconciler is the sole writer of host-observed state.
- **G4 — Portability.** Zero engine changes to target a non-Docker Linux host.
- **G5 — Educational clarity.** A reader can follow one deployment end-to-end through the schema and the shell without external documentation.

## 5. Non-Goals (explicitly out of scope for v1)

| Excluded | Why |
|---|---|
| Docker SDK / container API integration | Violates the thesis (§2). |
| Kubernetes, Terraform, Ansible | Different categories; would dilute the primitives thesis. |
| Multi-tenant auth, OAuth, teams | Deployment correctness is the deliverable. |
| Rollback strategies (canary, blue/green) | v2+. Symlink flip is a prerequisite, not the feature. |
| Managed TLS / domain provisioning | Scope. Manual certbot acceptable in v1. |
| Managed databases, backups, object storage | Scope. |
| Zero-downtime deploys | v1 accepts brief downtime on `systemctl restart`. Honest limitation. |

## 6. Core Concept — Three Questions, Three Answers

The central design discipline. Conflating any two of these produces bugs this system exists to prevent.

| # | Question | Column | Written by | Meaning |
|---|---|---|---|---|
| 1 | What are we **trying** to do? | `state` (+ `state_seq`) | Go engine | Intent |
| 2 | Is a worker on it **right now**? | `slot_busy` (generated) | **Postgres** | Concurrency guard |
| 3 | Is it **live on the host**? | `is_active` (+ `active_verified_at`) | **Reconciler only** | Observed reality |

**Why a generated column.** `slot_busy` answers "is this deployment in flight?", which is a pure function of `state` and therefore immutable — the only kind of expression a generated column accepts. The database computes it, so it can never drift from `state`.

**Why not derive it from the lease.** `lease_expires_at > now()` contains `now()`, which is `STABLE` not `IMMUTABLE`. Postgres rejects it:
```
ERROR:  generation expression is not immutable
```
It is also semantically wrong: generated columns are frozen at write time, so a lease-derived value would never change — a permanent lie. Lease liveness belongs in the **claim query**, not in a stored column.

**Why `state_seq` exists.** It is the compare-and-swap token. Without a monotonic sequence you cannot detect "someone advanced this while I was away," so you cannot detect a zombie worker overwriting newer state.

**Why `is_active` has exactly one writer.** If both the Bash script and the reconciler wrote it, they could disagree — reintroducing the two-sources-of-truth problem that §5 exists to prevent. Bash writes only to `deployment_events` (immutable audit). The reconciler alone writes `is_active`.

## 7. State Machine

**9 states.** Rejected a 4-state collapse (`pending → building → running`) because it discards the phase information required to choose a correct recovery action. See §7.2.

### 7.1 Transitions

```
                    ┌──────────────────────────── cancel ───────────┐
                    │                                              ▼
  pending ──▶ cloning ──▶ building ──▶ configuring ──▶ starting ──▶ health_checking ──▶ running
                    │          │            │             │              │
                    └──────────┴────────────┴─────────────┴──────────────┴──▶ failed
                                                                            terminal
  any non-terminal ──▶ canceled (terminal)
```

Terminal states: `running`, `failed`, `canceled`.
Occupies slot: `pending`, `cloning`, `building`, `configuring`, `starting`, `health_checking`.

### 7.2 Why 9 and not 4

A crash **during** `health_checking` — service already started, not yet verified — is the most instructive failure case in the system.

- With 9 states: the reconciler knows the service is up, and only needs to re-run the health check. Cheap, seconds.
- With 4 states: the reconciler sees `building`, cannot distinguish "never started" from "started, unverified," and the only safe action is a **full redeploy from clone** — minutes, and unnecessary.

State granularity *is* the recovery strategy. Each additional phase converts a rebuild into a targeted repair.

## 8. Crash-Safety Model

```
t0  INSERT deployment (state='pending')   ← intent committed BEFORE any host contact
t1  Go claims it: lease taken, state='cloning', lease_generation++
t2  Bash over SSH: git clone … pnpm build …     ← slow, minutes
t3  💥 power loss
t4  Reconcile loop: "non-terminal row, lease_expires_at < now() - grace"
    → SSH and INSPECT the host: does the release dir exist? is the service active?
    → the HOST answers, not the database
    → apply the phase-appropriate repair
```

**Invariant:** the database never records an outcome the host did not report. Absence of a terminal state means *"unknown, investigate"* — never *"assumed fine."*

**Failure injection is a first-class test:** killing the engine at every phase and asserting recovery is a required acceptance test (§11), not an optional extra.

## 9. System Architecture

```
┌─────────────────┐
│   Next.js UI    │  renders state + event stream. mutates nothing directly.
└────────┬────────┘
         │ HTTP (JSON + SSE for events)
┌────────▼────────┐
│   Go engine     │  THE BRAIN — decides, records, schedules. Never touches a host.
│  cmd/shipyard   │
└────────┬────────┘
         │ SSH  (golang.org/x/crypto/ssh)
┌────────▼────────┐
│  Bash on host   │  THE HANDS — git, build, systemd, nginx, symlink swap. Mutates only.
│  "shipyard-01"  │
└─────────────────┘
        ┌──────────────┐
        │  PostgreSQL  │  write-ahead intent ledger + event log
        └──────────────┘
```

**The rule: only Bash mutates a host.** The engine never writes a systemd unit, never flips a symlink, never restarts a service. Go's only host capability is *running a script and reading its exit code and output.*

**Consequence to honor:** because Bash's success is the sole source of `running`, a Bash script that exits 0 without doing the work is a *silent correctness failure*. Scripts must be idempotent and self-verifying, and the reconciler is the backstop (§8).

## 10. Database Schema

Verified against **PostgreSQL 18.6**. Non-obvious properties were proven empirically; see `reference/Shipyard build primitives/VERIFIED.md` and `postgres-claim-lease.md`.

```sql
-- ── Targets ────────────────────────────────────────────────────────────
CREATE TABLE servers (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  ssh_host      TEXT NOT NULL,
  ssh_port      INTEGER NOT NULL DEFAULT 22,
  ssh_user      TEXT NOT NULL,
  ssh_identity  TEXT NOT NULL,          -- path to private key, in-repo for lab
  status        TEXT NOT NULL DEFAULT 'unknown'
                CHECK (status IN ('unknown','up','down')),   -- DERIVED rollup only
  last_seen_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Applications ────────────────────────────────────────────────────────
CREATE TABLE projects (
  id            BIGSERIAL PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  repo_url      TEXT NOT NULL,
  default_branch TEXT NOT NULL DEFAULT 'main',
  build_cmd     TEXT NOT NULL,          -- runs on host, e.g. 'pnpm install && pnpm build'
  health_path   TEXT NOT NULL DEFAULT '/healthz',
  release_root  TEXT NOT NULL DEFAULT '/var/www',
  unit_name     TEXT NOT NULL,          -- systemd unit to restart
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── Intent ledger ───────────────────────────────────────────────────────
CREATE TABLE deployments (
  id            BIGSERIAL PRIMARY KEY,
  project_id    BIGINT NOT NULL REFERENCES projects(id),
  server_id     BIGINT NOT NULL REFERENCES servers(id),

  -- Q1 intent. Written ONLY by the engine.
  state         TEXT NOT NULL DEFAULT 'pending'
                CHECK (state IN ('pending','cloning','building','configuring',
                                 'starting','health_checking','running',
                                 'failed','canceled')),
  state_seq     BIGINT NOT NULL DEFAULT 0,     -- CAS token; monotonic

  -- Q2 derived by Postgres. Immutable expression — required for STORED.
  slot_busy     BOOLEAN GENERATED ALWAYS AS (
                  state IN ('pending','cloning','building','configuring',
                            'starting','health_checking')
                ) STORED,

  -- Lease: who is working, and until when. Not a stored predicate.
  lease_owner      TEXT,
  lease_expires_at TIMESTAMPTZ,
  lease_generation BIGINT NOT NULL DEFAULT 0,  -- the fence

  -- Q3 observed reality. Written ONLY by the reconciler.
  is_active          BOOLEAN NOT NULL DEFAULT FALSE,
  active_verified_at TIMESTAMPTZ,

  -- Resolved target of this attempt.
  commit_sha    TEXT,
  release_path  TEXT,
  error_message TEXT,

  requested_by  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at    TIMESTAMPTZ,
  finished_at   TIMESTAMPTZ
);

-- One in-flight deployment per (project, server). Enforced by Postgres;
-- the API translates the violation into 409 deploy_in_flight.
CREATE UNIQUE INDEX d_one_inflight
  ON deployments (project_id, server_id) WHERE slot_busy;

-- Claim path support.
CREATE INDEX d_claimable ON deployments (id) WHERE slot_busy;

-- ── Append-only audit log ───────────────────────────────────────────────
CREATE TABLE deployment_events (
  id            BIGSERIAL PRIMARY KEY,
  deployment_id BIGINT NOT NULL REFERENCES deployments(id) ON DELETE CASCADE,
  seq           INTEGER NOT NULL,           -- 0,1,2… within one deployment
  phase         TEXT NOT NULL,              -- lifecycle phase this event belongs to
  level         TEXT NOT NULL CHECK (level IN ('info','warn','error')),
  message       TEXT NOT NULL,
  data          JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (deployment_id, seq)
);
```

### 10.1 Claim — `FOR UPDATE SKIP LOCKED` must be **inside** the CTE

```sql
WITH d_claimable AS (
  SELECT id FROM deployments
  WHERE slot_busy
    AND (lease_expires_at IS NULL OR lease_expires_at < now())
  ORDER BY id
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE deployments d
SET state           = 'cloning',
    lease_owner     = $1,
    lease_expires_at = now() + interval '30 seconds',
    lease_generation = d.lease_generation + 1,
    state_seq        = d.state_seq + 1,
    started_at       = COALESCE(d.started_at, now())
FROM d_claimable
WHERE d.id = d_claimable.id
RETURNING d.*;
```

Two empirically verified requirements:

1. `FOR UPDATE SKIP LOCKED` **inside** the CTE. Placed outside it, Postgres emits **no `LockRows` node** and silently permits concurrent execution — the exact double-run this guards against.
2. The predicate must be `slot_busy` (an immutable generated column), not `lease_expires_at > now()` (non-immutable), or the partial index is unusable.

### 10.2 State transition — compare-and-swap plus fence

```sql
UPDATE deployments
SET state           = $2,
    state_seq       = state_seq + 1,
    lease_expires_at = CASE WHEN $2 IN ('running','failed','canceled')
                            THEN NULL ELSE lease_expires_at END,
    finished_at      = CASE WHEN $2 IN ('running','failed','canceled')
                            THEN now() ELSE finished_at END
WHERE id             = $1
  AND state_seq      = $3    -- nobody advanced it
  AND lease_generation = $4  -- I am not a zombie
RETURNING *;
```

**Zero rows returned means another actor won.** The worker must abort immediately and must not attempt a fallback write. This is the mechanism that prevents a network-partitioned zombie from overwriting a newer, correct state.

## 11. API Requirements

| Method | Endpoint | Purpose | Errors |
|---|---|---|---|
| `POST` | `/api/projects` | Register an application | `409` name taken |
| `POST` | `/api/servers` | Register a target | `409` name taken |
| `GET` | `/api/servers` | Fleet list | — |
| `GET` | `/api/projects` | Project list | — |
| `POST` | `/api/projects/:id/deployments` | **Record intent.** Body: `{server_id}`. Returns `409 deploy_in_flight` if the slot is occupied. | `404`, `409` |
| `GET` | `/api/deployments/:id` | Current read model | `404` |
| `GET` | `/api/deployments` | Recent list; filter by `project_id`, `server_id`, `state` | — |
| `GET` | `/api/deployments/:id/events` | Ordered event log | `404` |
| `GET` | `/api/deployments/:id/events/stream` | **SSE** live tail. Must send heartbeat comments and clean up on disconnect. | — |
| `POST` | `/api/deployments/:id/cancel` | Revoke lease → `canceled` | `409` already terminal |
| `GET` | `/api/healthz` | Liveness | — |

**`POST /deployments` must commit intent before responding.** It performs no host work. Latency target: < 50 ms, independent of build duration — this is what makes the UI honest.

## 12. Acceptance Criteria

| # | Criterion | How it is proven |
|---|---|---|
| A1 | Deploy a Next.js app to `shipyard-01`; every phase visible in order | UI shows `pending→cloning→building→configuring→starting→health_checking→running` |
| A2 | A second concurrent deploy to the same server is refused by the **database** | Integration test asserts the partial unique index rejects it; API returns `409` |
| A3 | Engine killed mid-`building` → recovers, no human action | Fault-injection test: `SIGKILL` at each phase, assert recovery |
| A4 | Engine killed mid-`health_checking` → health check re-run, **not** a full rebuild | Assert elapsed time and absence of a new `cloning` event |
| A5 | A zombie lease holder cannot corrupt state | Test: stale `lease_generation` write returns 0 rows |
| A6 | Two engines racing on one queue never run the same deployment twice | Parallel workers, assert single execution |
| A7 | Deploy to a real VPS requires **no engine code change** | Manual, documented in README |
| A8 | Nothing in `cmd/` or `internal/` imports `github.com/docker/docker` | Grep-based CI check |
| A9 | Backends crash mid-claim → no permanent lockout | Integration test: `pg_terminate_backend` during claim; lease expires and re-claim succeeds |
| A10 | Log stream survives long deploys without memory growth | Bounded-buffer soak test |

## 13. Success Metrics

| Metric | Target |
|---|---|
| Intent-to-durable-event latency | < 1 s |
| `POST /deployments` latency | < 50 ms |
| Crash recovery, no human intervention | 100% across all 9 phases |
| Duplicate execution under race | 0 |
| Engine code changes to add a non-Docker target | 0 |
| Lines of Go that can mutate a host directly | 0 |

## 14. Milestones

Sequencing detail is authoritative in `docs/ROADMAP.md`. This is the acceptance gate per milestone.

| # | Milestone | Done when |
|---|---|---|
| M0 | **Lab fleet** | 3 systemd containers up; `make lab-check` prints `Lab read.` — SSH key works on 2201/2202/2203 and each host answers as a deployment target |
| M1 | **Ledger** | Schema migrated; claim, CAS transition, and event append all covered by integration tests against real Postgres |
| M2 | **SSH execution** | Engine runs a script remotely, captures streamed output + exit code |
| M3 | **Deploy pipeline** | Real deploy lands on a lab container; A1 passes |
| M4 | **UI + SSE** | Live phase-by-phase view; A1 verified visually |
| M5 | **Reconciler** | A3, A4, A9 pass |
| M6 | **Portability proof** | A7 passes against a real VPS; README documents it |

## 15. Documentation

A PRD alone does not make a portfolio project credible. Required artifacts:

- `README.md` — thesis, 60-second demo, architecture diagram
- Live demo recording or GIF showing a deploy progressing
- A crash-recovery demo: kill mid-deploy, show self-heal
- Architecture decision log (`docs/MENTAL-MODEL.md`) — already written
- Hosted at `sskbtw.xyz` as a case study

## 16. Open Questions

1. **Health check semantics** — is HTTP 200 sufficient, or must response body match a pattern? Affects the health-check Bash fragment.
2. **Zero-downtime** — v1 accepts restart downtime. When does that become unacceptable?
3. **Retention** — how long are `deployment_events` retained? Unbounded growth is a real operational risk.
4. **Single-process assumption** — the claim query is built for multiple workers, but v1 runs one. When is multi-process actually needed?
5. **SSH key custody** — lab uses an in-repo key. Real deployments need encrypted-at-rest credentials, which forces the secrets design in `reference/…/secrets-and-key-management.md`. Scope for v2.
