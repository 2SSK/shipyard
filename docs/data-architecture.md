# Shipyard — Data Architecture

**Owner:** database-administrator · **Status:** authoritative design, hand-off to `postgres-pro` for DDL
**Scope:** data model, ownership of every fact, lifecycle, locking, retention, secrets, migrations, backup, reconciliation.
**Explicitly out of scope here:** column-by-column index tuning, query plans, partition counts. `postgres-pro` decides those from the requirements below.

---

## 0. The one axiom everything hangs off

> **Postgres is the source of truth about *intent*. The Linux host — its filesystem and systemd — is the source of truth about *what is actually running*.**

Every column in the system is tagged with exactly one owner:

| Tag | Meaning | Written by | May be stale? |
|---|---|---|---|
| `I` **intent** | A decision a human or the API made. The control plane's memory. | API / operator only | No — the DB is authoritative |
| `O` **observed** | A fact about the real world, reported by a worker after it *looked*. | The lease holder, after reading the host | **Yes, always.** That is what makes it an observation |
| `D` **derived** | Computed from `I` + `O`. Never an input to a decision. | SQL generated column, view, or Go | By construction, no |

**Hard rule: if two components can write a field, it is `D` and exactly one designated function writes it.** No shared mutable truth. This is what makes reconciliation tractable — there is no ambiguity about who is allowed to be right.

A corollary that shapes the whole schema: **control-plane state is a cache of the past, host state is a sample of the present.** A crashed control plane is recoverable because the cache can be rebuilt from the present. A host that disagrees with Postgres wins, and Postgres gets corrected.

### The three questions, and which column answers each

| Question | Answered by | NOT answered by |
|---|---|---|
| "What did the operator ask for?" | `I` columns | anything on the host |
| "What did the last run actually do?" | `O` columns on `deployments` | `state` alone |
| "What is *live on that box right now*?" | `deployments.is_active`, written by **reconciliation** from the host's `current` symlink | `state = 'running'` |

`is_active` and `state` are **deliberately separate columns** because they answer different questions and diverge in exactly the interesting case: a deploy whose unit started, whose health check then failed, is `state='failed'` while the *previous* deployment is still `is_active=true`. And after a rollback, two deployments can be `state='running'` with only one of them active. Collapsing these into one column is mistake #3 in §11 and it wrecks both the UI and the reconciler.

---

## 1. The data model

Naming: `snake_case` plural tables, `uuid` (v7 — time-ordered, so B-tree inserts stay on the right edge) PKs everywhere except append-only logs. All timestamps `timestamptz`, never `timestamp`. All enums native Postgres enums (not `text` + `CHECK`), so a typo is a compile error at the type level and `ADD VALUE` in a new enums is a forward-compatible migration.

### 1.1 `servers`

One row per Linux host. **Never hard-deleted** (§2.4).

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `I` | v7 |
| `name` | `text` UNIQUE | no | `I` | slug; used in unit names and paths — the human handle |
| `provider` | `server_provider` enum | no | `I` | `local`, `vps`, `cloud`, `lab` |
| `hostname` | `text` | no | `I` | DNS name or IP |
| `ssh_user` | `text` | no | `I` | |
| `ssh_port` | `int` | no | `I` | default 22 |
| `ssh_identity_path` | `text` | no | `I` | **path to** a key on the control plane, never key material |
| `agent_token_hash` | `bytea` | yes | `I` | `sha256` of the host-agent token; plaintext shown once at provisioning |
| `labels` | `jsonb` | no (default `{}`) | `I` | free-form targeting (`env=prod`, `gpu=true`) |
| `lifecycle` | `server_lifecycle` enum | no | `I` | `provisioning`,`active`,`draining`,`decommissioned`. **Operator-declared, not observed** |
| `os_release` | `text` | yes | `O` | last heartbeat |
| `kernel` | `text` | yes | `O` | |
| `cpu_count` | `smallint` | yes | `O` | |
| `memory_total_bytes` | `bigint` | yes | `O` | |
| `disk_total_bytes` | `bigint` | yes | `O` | |
| `disk_used_bytes` | `bigint` | yes | `O` | |
| `nginx_version` | `text` | yes | `O` | |
| `openclaw_version` | `text` | yes | `O` | runner agent version |
| `last_seen_at` | `timestamptz` | yes | `O` | reachability signal |
| `ssh_error` | `text` | yes | `O` | last SSH failure verbatim |
| `capacity_used_bytes` | `bigint` | yes | `D` | `disk_used_bytes - <sum of live release sizes>`; nullable because it is only computable when the release inventory is known |
| `created_at` / `updated_at` | `timestamptz` | no | `I` | |
| `archived_at` | `timestamptz` | yes | `I` | soft delete |

Note the deliberate name split: `lifecycle` = intent ("I declare this box is draining"), `last_seen_at` = observation ("it answered 40s ago"). A common and expensive mistake is one `status` column trying to be both. Reachability is then a `D` view expression, not a stored column.

**No time-series table for metrics.** CPU/disk history goes to Prometheus. Postgres gets the last sample as a snapshot for the UI's "how full is this box" display and nothing else. A `server_metrics` table is the single most common form of Postgres abuse in deployment tools and it buys nothing here.

### 1.2 `projects`

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `I` | |
| `name` | `text` UNIQUE | no | `I` | slug; appears in unit names and release paths, so **renaming a project is forbidden once a deployment exists** (§1.9 trigger) |
| `repo_url` | `text` | no | `I` | |
| `default_branch` | `text` | no | `I` | |
| `build_config` | `jsonb` | no | `I` | `{image, build_cmd, build_args[], target, context}` — evolves with the builder, so `jsonb` with a Go-side validated struct is correct here, *not* a `text` dump |
| `deploy_key_ciphertext` | `bytea` | yes | `I`+secret | same AEAD as §6, `key_version` alongside |
| `workspace_dir` | `text` | no | `D` | `<data_dir>/projects/<project name>` |
| `created_at` / `updated_at` | `timestamptz` | no | `I` | |
| `archived_at` | `timestamptz` | yes | `I` | soft delete |

### 1.3 `services`

A project runs one or more systemd units. A deployment touches all of them. This child table exists because "deploy" ≠ "restart one unit" the moment a project has a web + a worker.

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `I` | |
| `project_id` | `uuid` FK→`projects` | no | `I` | `ON DELETE RESTRICT` |
| `name` | `text` | no | `I` | unique per project |
| `unit_name` | `text` | no | `D` | deterministic: `shipyard-<project>-<service>.service`. **Stored, not computed at read time**, because the unit name is a contract with the host: reconciliation must compare a stored expectation against `systemctl show` output, and a name computed differently on either side is a silent outage |
| `exec_start` | `text` | no | `I` | usually a symlink into the release dir |
| `healthcheck` | `jsonb` | yes | `I` | `{type:"http", path:"/healthz", expect_status:200, timeout_ms:2000, interval_s:5, retries:3}` |
| `restart_policy` | `text` | no | `I` | `always` / `on-failure` |
| `managed` | `boolean` | no | `I` | `false` for units Shipyard observes but does not create (e.g. `nginx`, `docker`) |
| `created_at` / `updated_at` | `timestamptz` | no | `I` | |
| `archived_at` | `timestamptz` | yes | `I` | |

### 1.4 `deployments` — the crux

**Identity rule (immutable, enforced by trigger — §2.1): `commit_sha` and `server_id` never change after INSERT. `number` is never reused.** Deployment #42 means `a81c92e` on server `web-1`, forever. "Move to another server" and "roll back" are therefore *new rows*, not updates (§1.9).

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `I` | v7; clusters by creation time, good for the "recent for project" index |
| `project_id` | `uuid` FK | no | `I` | `ON DELETE RESTRICT` |
| `server_id` | `uuid` FK | no | `I` | `ON DELETE RESTRICT` |
| `number` | `bigint` | no | `I` | per-project, gapless. `UNIQUE (project_id, number)`. The human ID |
| `commit_sha` | `char(40)` | no | `I` | **immutable** |
| `requested_ref` | `text` | no | `I` | the branch/tag/SHA the user actually typed. Stored separately so history reads honestly without weakening the SHA guarantee |
| `commit_meta` | `jsonb` | yes | `O` | `{message, author, committed_at, tree}` read from the cloned repo |
| `commit_message` | `text` | yes | `O` | flattened out of `commit_meta` because every list view needs it and a `jsonb`→>text extraction per row is silly |
| `trigger` | `deploy_trigger` enum | no | `I` | `manual`, `api`, `schedule`, `rollback` |
| `requested_by` | `text` | no | `I` | API key name or operator |
| `environment_revision_id` | `uuid` FK | no | `I` | **immutable**. The env this deploy will render. See §6.3 |
| `state` | `deployment_state` enum | no | `O` | `pending`,`cloning`,`building`,`configuring`,`starting`,`health_checking`,`running`,`failed`,`canceled`. Default `pending`. **Immutable-append: only ever moves forward, never rewinds** |
| `state_seq` | `int` | no | `O` | monotonic per deployment; CAS token. `state = (state at state_seq)` |
| `state_event_seq` | `int` | yes | `D` | seq of the `state_change` event that produced the current `state`. Drift detector, §9.4 |
| `state_changed_at` | `timestamptz` | no | `O` | |
| `abort_requested_at` | `timestamptz` | yes | `I` | operator asks to stop; worker observes and transitions to `canceled`. The cheap version of a `desired_state` column — see §3.4 |
| `is_active` | `boolean` | no | `D` | "the `current` symlink on this server points at this deployment's release". Written **only** by reconciliation, from the host. Backed by `UNIQUE (project_id, server_id) WHERE is_active` |
| `active_verified_at` | `timestamptz` | yes | `D` | when the host last confirmed it. `now() - active_verified_at` is the staleness that drives the drift alert |
| `observed_current_release` | `text` | yes | `O` | last release path the host reported, verbatim. Lets the reconciler answer "what did we last believe" before it can re-ask |
| `observed_release_sha` | `char(40)` | yes | `O` | what the host says is live — may differ from `commit_sha` if someone `git`'d on the box by hand |
| `lease_owner` | `text` | yes | `I` | worker id holding the run |
| `lease_expires_at` | `timestamptz` | yes | `I` | |
| `lease_generation` | `int` | no (default 0) | `I` | **fencing token**, bumped on every claim, §4.4 |
| `worker_id` | `text` | yes | `O` | last writer, for forensics |
| `release_dir` | `text` | no | `D` | `<shared>/releases/<project>/<number>-<sha7>` |
| `started_at` | `timestamptz` | yes | `O` | |
| `finished_at` | `timestamptz` | yes | `O` | set on terminal state |
| `duration_ms` | `bigint` | yes | `D` | `finished_at - started_at` |
| `error_code` | `text` | yes | `O` | machine-readable: `git_clone_failed`, `build_failed`, `health_timeout`, `systemd_start_failed`, `aborted` |
| `error_message` | `text` | yes | `O` | first line of the failure, for list views; full detail lives in events + log file |
| `rollback_of_deployment_id` | `uuid` FK→self | yes | `I` | set when this deploy reverts another |
| `supersedes_deployment_id` | `uuid` FK→self | yes | `I` | the deployment this one replaces |
| `retry_of_deployment_id` | `uuid` FK→self | yes | `I` | manual re-run |
| `log_path` | `text` | yes | `O` | absolute path on the **control plane**, §5.4 |
| `log_bytes` | `bigint` | yes | `O` | |
| `log_lines` | `bigint` | yes | `O` | |
| `log_sha256` | `bytea` | yes | `O` | tamper-evidence on the artifact |
| `log_truncated` | `boolean` | no (default false) | `O` | hit the 200 MB cap; head+tail retained |
| `env_rendered_sha256` | `bytea` | yes | `D` | hash of the rendered `shared/.env` as written to the host — proves the box got what we think it got, without storing plaintext |
| `created_at` / `updated_at` | `timestamptz` | no | `I` | |
| `slot_busy` | `boolean` GENERATED STORED | — | `D` | `state IN (non-terminal set)`. Serialization primitive, §2.2 |

### 1.5 `deployment_services`

Per-deployment, per-unit observations. This is the join that makes "one deployment" fan out to N systemd units.

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `uuid` PK | no | `I` | |
| `deployment_id` | `uuid` FK | no | `I` | `ON DELETE CASCADE` (safe — parent is never deleted, §2.4) |
| `service_id` | `uuid` FK | no | `I` | `ON DELETE RESTRICT` |
| `desired_action` | `deploy_action` enum | no | `I` | `start`,`restart`,`stop` |
| `systemd_active_state` | `text` | yes | `O` | verbatim `ActiveState=` |
| `systemd_sub_state` | `text` | yes | `O` | verbatim `SubState=` |
| `active_entered_at` | `timestamptz` | yes | `O` | from `ActiveEnterTimestamp` — "crashed 3 times in the last 10s" is visible here |
| `restart_count` | `int` | yes | `O` | `NRestarts=` |
| `health_status` | `health_status` enum | no | `I` default `unknown` | `unknown`,`passing`,`failing` — the *slot* the orchestrator maintains |
| `health_checked_at` | `timestamptz` | yes | `O` | |
| `health_fail_count` | `smallint` | no (default 0) | `O` | |
| `health_detail` | `text` | yes | `O` | last probe result (status code, latency), no response body — bodies can hold secrets |
| `last_error` | `text` | yes | `O` | |
| | | | | `UNIQUE (deployment_id, service_id)` |

**No `health_checks` history table.** The health *time series* is a debugging tool, not a record; it goes to Prometheus as a gauge. The last N transitions are already in `deployment_events`.

### 1.6 `environment_revisions` + `environment_variables` (§6, detailed there)

| `environment_revisions` | Type | Null | Tag |
|---|---|---|---|
| `id` | `uuid` PK | no | `I` |
| `project_id` | `uuid` FK | no | `I` |
| `version` | `int` | no | `I` — `UNIQUE (project_id, version)` |
| `content_hash` | `bytea` | no | `D` — `sha256` over sorted `(key, scope, ciphertext, nonce)`. Enables "did the env actually change?" without decrypting |
| `comment` | `text` | yes | `I` |
| `created_by` | `text` | no | `I` |
| `revoked_at` | `timestamptz` | yes | `I` — set when a value in this revision is known-leaked. Revocation blocks *selection* for new deploys; the row and its ciphertext stay, because old deployments must remain reproducible |
| `created_at` | `timestamptz` | no | `I` |

| `environment_variables` | Type | Null | Tag |
|---|---|---|---|
| `id` | `uuid` PK | no | `I` |
| `revision_id` | `uuid` FK | no | `I` — `ON DELETE CASCADE` |
| `key` | `text` | no | `I` — `UNIQUE (revision_id, key)`; must match `[A-Z_][A-Z0-9_]*` |
| `scope` | `env_scope` enum | no | `I` — `build`, `runtime`, `both`. A build-time `NPM_TOKEN` must not be written to `shared/.env` |
| `ciphertext` | `bytea` | no | `I`+secret |
| `nonce` | `bytea` | no | `I` |
| `key_version` | `smallint` | no | `I` |
| `created_at` | `timestamptz` | no | `I` |

**There is no `value` and no `value_preview` column.** Not `is_secret`, not "mask all but the last four" — a masked value still leaks a length and a prefix, and every masking implementation eventually gets a `WHERE value LIKE 'sk_%'` shipped by accident. The DB has ciphertext; the render path has plaintext for ~200 ms.

### 1.7 `deployment_events` — the audit spine

Append-only. No `UPDATE`, no `DELETE`, no `ON DELETE CASCADE` from `deployments` (that combination would let a `DELETE` on a project wipe audit; §2.4).

| Column | Type | Null | Tag | Notes |
|---|---|---|---|---|
| `id` | `bigint` PK (`bigserial`) | no | `I` | |
| `deployment_id` | `uuid` FK→`deployments` | no | `I` | `ON DELETE RESTRICT` |
| `project_id` | `uuid` FK | no | `I` | **denormalized** — one index serves both "one deployment's timeline" and "project activity feed" without a join |
| `seq` | `int` | no | `I` | `UNIQUE (deployment_id, seq)`. Total order that does not depend on clock resolution |
| `type` | `event_type` enum | no | `I` | `state_change`, `claim`, `release`, `lease_lost`, `error`, `abort_requested`, `log_tail`, `reconcile_apply`, `note` |
| `from_state` / `to_state` | `deployment_state` | yes | `I` | null for non-transition events |
| `attempt` | `smallint` | yes | `I` | ties events to a lease generation |
| `worker_id` | `text` | yes | `I` | |
| `message` | `text` | yes | `I` | human sentence, already redacted |
| `error_code` / `error_detail` | `text` | yes | `I` | |
| `metadata` | `jsonb` | no (default `{}`) | `I` | unit names, symlink paths, host-reported values |
| `created_at` | `timestamptz` | no | `I` | `now()` — wall clock, for humans |

### 1.8 `reconcile_runs`, `audit_log`

`reconcile_runs`: `id uuid`, `server_id`, `trigger` (`startup`,`scheduled`,`manual`,`post_deploy`), `started_at`, `finished_at`, `outcome` (`clean`,`drift_fixed`,`drift_unfixable`,`unreachable`), `changes jsonb` (before → after per row), `error text`. Retained 90 days (§5). This table is what makes the reconciliation story *legible* in a portfolio demo instead of a hidden code path.

`audit_log`: `id bigserial`, `at`, `actor`, `action` (`project.delete_requested`, `server.decommissioned`, `env.revision_purged`, `migration.applied`, `restore.drill`), `target_type`, `target_id`, `payload jsonb`. **Kept forever.** Not append-only-triggered, but nothing in the app has a code path that writes to it other than the admin surface.

### 1.9 Extension points for the two named future features

Deliberately designed in now, exercised later, zero rework:

- **Rollback to previous release** = a *new* deployment row with `rollback_of_deployment_id` set and `commit_sha` copied from the target. It runs the identical lifecycle, and when it goes `running`, `is_active` moves. The reverted row keeps `state='running'` and gets `is_active=false`; `is_active` is what the UI renders as "Live". Storing rollback as a column on the old row would have violated the "one immutable (sha, server) pair" axiom and would have made #42 ambiguous.
- **Migrate to another server** = a new row on the *target* server with `supersedes_deployment_id` pointing at the source. The cutover is two-phase: target reaches `health_checking`→`running` on the new server, then reconciliation observes the source's symlink and flips its `is_active=false`. Nothing in the schema changes; the only new thing needed is a cutover step in the state machine that knows about the sibling row, plus a `cutover_state` if you want it visible. Flagged as known-unfinished, not designed.

### 1.10 Host-side state files (the second half of the data model)

The Bash layer owns a small amount of state on the target, and the control plane treats it as authoritative for the *observed* facts:

```
/srv/shipyard/
  shared/.env                     # rendered, 0600, owner=service
  shared/current -> releases/<project>/<number>-<sha7>   # THE liveness symlink
  releases/<project>/<number>-<sha7>/
      .shipyard/state.json        # {commit_sha, units[], built_at, env_sha256}
  leases/<deployment>/<gen>.json  # fencing tokens, §4.4
```

`current` is the single source of truth for "what is live". No unit ever points at a release directory directly; `ExecStart` always goes through `shared/current/<service>`. This is what makes "what is running right now" a one-`readlink` question instead of a systemd archaeology exercise, and it makes the host self-describing even when the control plane is down. `releases/` is pruned by a Bash GC that only ever deletes directories not pointed to by `current` and not referenced by any non-terminal deployment.

---

## 2. Invariants and constraints

### 2.1 Immutability (trigger-enforced, not convention)

A `BEFORE UPDATE` trigger on `deployments` raises `23514` if any of these changed: `project_id`, `server_id`, `number`, `commit_sha`, `requested_ref`, `environment_revision_id`, `rollback_of_deployment_id`, `supersedes_deployment_id`, `retry_of_deployment_id`. A second trigger on `projects` raises if `name` changed while any deployment exists (the name is baked into unit names, release paths, and log paths — renaming it is a migration, not an UPDATE).

A third trigger, `deployments_assert_lease()`, raises unless the `SET LOCAL shipyard.worker_id` session GUC equals `OLD.lease_owner` **for any change to `state`, `state_seq`, or any `observed_*` column**. This is the single highest-value trigger in the schema: it makes "only the lease holder advances this run" a *database* guarantee rather than a code review comment, and it makes a zombie worker harmless even if it comes back to life holding a stale `lease_owner` in its string.

### 2.2 The exclusivity rule: "exactly one active Deployment per (Project, Server)"

> **Precisely one** is the business rule. **At most one** is what can be enforced, and it is enforced by Postgres:

```sql
-- the whole mechanism, in one line:
CREATE UNIQUE INDEX deployments_one_active_per_slot
  ON deployments (project_id, server_id) WHERE is_active;
```

Everything else about the rule is orchestrator policy, and the split is worth stating precisely because the gap is *intentional*:

| Layer | Guarantees | Mechanism |
|---|---|---|
| **DB** | At most one `is_active` row per (project, server). At most one in-flight run per slot. | Two partial unique indexes (§2.2, below) |
| **Orchestrator** | At most one *in practice*; exactly one whenever the project is supposed to be live. Flip-old-to-false and flip-new-to-true **in one transaction** at the `health_checking`→`running` boundary. | `UPDATE deployments SET is_active=false WHERE ... AND is_active; UPDATE deployments SET is_active=true WHERE id=$new;` in one tx |
| **Reconciler** | Repairs the gap. Reads the host's `current` symlink, sets `is_active` to match, sets `active_verified_at`. This is the only writer besides the deploy transaction. | §9 |
| **Nobody** | Guarantees the host is live. If the project was never deployed, the correct number is zero. | — |

The gap between "at most one" and "exactly one" is a real, narrow, and *self-healing* window: between the moment the symlink is swapped on the box and the moment reconciliation confirms it. Do not try to close it with a transaction — you cannot put Postgres and a remote filesystem in one. Close it with reconciliation, and alert on `active_verified_at` staleness.

**Serializing in-flight runs**, same idea, no queue table:

```sql
-- slot_busy is a STORED generated column: state IN (pending,cloning,building,configuring,starting,health_checking)
CREATE UNIQUE INDEX deployments_one_inflight_per_slot
  ON deployments (project_id, server_id) WHERE slot_busy;
```

A second `INSERT` to the same slot raises `23505` on the generated column, which the API maps to `409 {reason: "deploy_in_flight", deployment_number: 41}`. It is derived, so it cannot drift, and it disappears entirely when the row reaches a terminal state. Deploys to *different* servers of the same project proceed in parallel, which is exactly the required behaviour.

### 2.3 Referential integrity and delete behaviour

| Parent → Child | On delete | Why |
|---|---|---|
| `projects` → `deployments` | `RESTRICT` | A project with history cannot vanish. Deletion is a two-step, audited flow (§2.4) |
| `servers` → `deployments` | `RESTRICT` | A server that hosted a deploy is part of the audit record forever |
| `projects` → `services` | `RESTRICT` | a service with units on hosts is not garbage |
| `services` → `deployment_services` | `RESTRICT` | ditto |
| `deployments` → `deployment_services` | `CASCADE` | **Safe.** Child rows have no meaning without the parent, and the parent is never hard-deleted, so the cascade never fires. Use it for schema correctness, not as a deletion policy |
| `deployments` → `deployment_events` | `RESTRICT` | Never cascade across an audit boundary — see below |
| `environment_revisions` → `environment_variables` | `CASCADE` | Same reasoning as `deployment_services` |
| `deployments` → `environment_revisions` | `RESTRICT` | A revision referenced by any deployment is permanent |

**The cascade rule, stated once:** *CASCADE is appropriate only where the parent is itself undeletable. It is never appropriate where the parent is audit-bearing.* `deployments` is audit-bearing and hard-deletable only through the purge flow below — and that flow deletes events explicitly, in its own transaction, with an `audit_log` row written first, so the deletion itself is recorded in the only place that is not being deleted.

### 2.4 Deletion policy: soft by default, purge is an explicit, rare, audited act

- **Servers.** `lifecycle='draining'` → block new deploys to it, let in-flight ones finish, existing services keep running. `lifecycle='decommissioned'` + `archived_at=now()` → excluded from every scheduling/listing query by default. Rows are **never** hard-deleted. A `server_id` in a deployment must resolve forever, because the audit record's whole value is that it points at the machine that ran the code.
- **Projects.** `archived_at=now()`; the UI shows it read-only with a rollback history. Hard purge requires: archived, zero deployments, and an explicit confirmation typed with the project name. The API exposes `POST /projects/{id}/purge`, writes an `audit_log` row, and returns the exact `DELETE` statements it will run for your review. There will be no UI button that does this by accident.
- **Deployments.** There is no delete endpoint. There is a `scripts/purge_terminal_forever.sh` that deletes deployments in `state IN ('failed','canceled')` older than N years **only** when `--i-have-a-dump --confirm` is passed, and it refuses to run if any such deployment is `is_active` or referenced by a `rollback_of`/`supersedes` chain. It is a script, not an API, because it should be scary.

### 2.5 DB-guaranteed vs. orchestrator-enforced

| Guaranteed by Postgres | Guaranteed by the orchestrator |
|---|---|
| One active deployment per (project, server) | That one is the correct one |
| One in-flight run per (project, server) | That in-flight run makes progress |
| `(sha, server)` immutability after insert | That the built artifact corresponds to `commit_sha` |
| Env revision immutability; revision is never mutated | That the rendered `.env` on the host matches `env_rendered_sha256` |
| Only the lease holder can advance `state` | That the lease holder is alive and renewing |
| Event append-only; `(deployment_id, seq)` gapless & ordered | That state and events are written together (belt: CAS; braces: one tx) |
| No orphan references | That every `running` deployment has a healthy unit on a real host |
| `active` ⊆ terminal-success-or-observed-swap | That a `running` deployment is not silently killed by someone at a shell |

---

## 3. The state-transition write model

### 3.1 The three candidate designs

| | **(a) `status` column only** | **(b) Events only** | **(c) Both** |
|---|---|---|---|
| Point read "what state is #42 in" | `O(1)` single-row | `O(log n)` agg + type filter, needs care | `O(1)` single-row |
| "where was it when we crashed" | Impossible. You know it says `building`; you do not know if the build was at 5% or 95%, or whether the runner was still alive | Full timeline, but you must *derive* current state from the tail, and the derivation is a decision made at read time in the wrong place | `O(1)` for state, full timeline for explanation |
| Operator story for a failure | "it says failed" | Rich | Rich, plus a scannable current state |
| Write cost | 1 UPDATEs | 1 INSERT | 1 UPDATE + 1 INSERT in one tx |
| Drift risk | none | high (state is computed) | low, and **detectable** (§9.4) |
| Audit signal | none | strong | strong |

**(a) is disqualified by the crash requirement.** When the control plane dies at `state='building'`, the row tells you a *label* and nothing about progress, lease liveness, or which step was mid-flight. That is exactly the information reconciliation needs, and it is gone.

**(b) is the wrong primary.** Making the event tail authoritative means the scheduler's hot path is a `max(seq)` aggregate with a type discriminator over a growing table, and every reader — including the reconciler, under pressure — has to reimplement state derivation identically. Two implementations of the same rule is how you get a reconciler that decides a deployment is running when the UI says it failed. That class of bug is unacceptable in a system whose whole thesis is "reconcile against reality".

### 3.2 Recommendation: **(c), with a precise division of authority**

- `deployments.state` is a **denormalized cache of the last `state_change` event**. The events table is the authority; the column exists so the hot path stays a single-row read.
- `deployments.state_event_seq` records which event produced the current column value. That single integer turns a cache into a *verifiable* cache: one query (§9.4) finds every row where the cache and the log disagree, forever, for one index scan. In a portfolio, "we made it impossible for our cached state to silently diverge from the audit log, and here is the query that proves it" is a better sentence than either pure design.
- Events are ordered by `seq`, never by `created_at`. Wall clocks jump backwards; sequence numbers do not. `created_at` is for humans only.

### 3.3 The write, exactly

One transition = one transaction, two statements, and the CAS is the safety property:

```sql
BEGIN;
  -- CAS: only advances if state_seq is still what the worker last saw.
  UPDATE deployments
     SET state = $new, state_seq = state_seq + 1, state_event_seq = $next,
         state_changed_at = now(), updated_at = now()
   WHERE id = $id AND state_seq = $prev AND lease_owner = $worker;
  -- 0 rows updated ⇒ someone else advanced it ⇒ the worker must stop, not retry blindly.
  INSERT INTO deployment_events (deployment_id, project_id, seq, type, from_state, to_state, worker_id, attempt, message, created_at)
  VALUES ($id, $project, $next, 'state_change', $prev, $new, $worker, $gen, $msg, now());
COMMIT;
```

Three properties fall out:

1. **Crash-safety.** Either both landed or neither did. There is no window where the state says `starting` and no event explains it, and none where an event exists with no state. WAL makes it durable at `COMMIT`.
2. **Idempotence under retry.** If the worker's network died after the commit, the retry's CAS matches 0 rows and the worker reads the current state instead of double-inserting the event. `UNIQUE (deployment_id, seq)` is the backstop that makes even a buggy retry impossible to double-write.
3. **Cheap staleness.** `now() - state_changed_at > expected_duration_for_this_state` is a liveness signal that needs no lease at all — useful as an independent check on the lease.

### 3.4 Why not a `desired_state` column

The textbook version of this problem is a two-column state machine: `desired_state` (operator writes `cancel`) + `observed_state` (worker writes `canceled`). It is more general, and it is how Argo and Flux do it. It is also two columns that can disagree forever, plus a derivation rule that every reader must implement.

Shipyard's only real operator-forced transition is *cancel*. That is one nullable timestamp — `abort_requested_at` (`I`) — plus one terminal state the worker can choose. It gives the same expressiveness for 1 column instead of 2, and the reconciliation query is trivially readable: *a non-terminal deployment with `abort_requested_at IS NOT NULL` should be `canceled`.* If Shipyard ever grows a real "pause / resume / force" surface, promote it to `desired_state` then; the events table already holds the history either way.

### 3.5 The crash/audit-trail cost question, answered honestly

Cost of the events table at solo-project scale: ~20 events per deployment, ~1,400 deployments/year → **~28,000 rows/year, ~8 MB/year**. A nightly `pg_dump` compresses the whole database to under 10 MB. The write amplification is one extra INSERT per state transition — 8 per deployment, against an SSH clone that takes tens of seconds.

That is a rounding error, and it buys: a readable failure timeline, a durable audit trail, a verifiable state cache, and a `rollback_of` story you can point at. **Yes, it is worth it.** The general principle: *event-sourcing pays when the state machine is long, slow, externally-affected, and crash-prone. Deployment is all four.* The counter-example — a state machine with six states that all change inside one 5 ms transaction — should absolutely stay a single column.

---

## 4. Claiming and locking

### 4.1 Comparison

| Mechanism | Verdict | Reason |
|---|---|---|
| `pg_try_advisory_lock` keyed on `(project_id, server_id)` | **Reject** | Session-scoped and invisible. A network-partitioned control plane holds the lock until TCP keepalive gives up — potentially minutes — and you cannot see it in any table, so the UI shows "nothing running" while a deploy is actually running. Debugging that is miserable, and there is no expiry you control. Excellent for "serialize a short critical section", wrong for "own a 4-minute job" |
| `SELECT ... FOR UPDATE SKIP LOCKED` on a queue table | **Reject as primary** | A great pattern, but a dead worker's row stays locked by a dead transaction and `SKIP LOCKED` then hides it *forever*. It still needs a lease to be safe, and it adds a second table that must be reconciled against `deployments`. You pay the complexity and still need the thing we rejected |
| **Lease column + CAS, with `SKIP LOCKED` used only to avoid claimant contention** | **Adopt** | The lease is visible in the table (so the UI can show it), it has an explicit expiry (so a crash self-heals), and `lease_generation` is a fencing token (so a zombie cannot corrupt state). One table, no new concepts |
| Message broker (NATS/Redis streams) | **Reject** | A second datastore with its own durability, backup, and failure modes, for a workload of ~0.001 deploys/second. It would be the least reliable component in the system |

### 4.2 The exact claim

```sql
BEGIN;
  -- Step 1: pick candidates without blocking other claimants. Non-blocking, so N workers
  -- never queue behind each other; the WHERE clause is the real filter.
  SELECT id, project_id, server_id, state_seq, environment_revision_id, log_path
    FROM deployments
   WHERE state = 'pending'
     AND slot_busy
   ORDER BY created_at
   FOR UPDATE SKIP LOCKED
   LIMIT $n;

  -- Step 2: take the lease. This UPDATE is itself a CAS: two claimants serialized on the
  -- same row will see the second one's WHERE clause fail.
  UPDATE deployments
     SET lease_owner = $worker, lease_expires_at = now() + interval '60 seconds',
         lease_generation = lease_generation + 1, worker_id = $worker, updated_at = now()
   WHERE id = ANY($ids) AND slot_busy
  RETURNING *;
COMMIT;
```

`RETURNING` hands each worker exactly the rows it owns, with the new `lease_generation`. There is no separate "claim" row, no queue table, and no advisory lock — the `deployments` row *is* the queue item, and the `slot_busy` partial index is the ready-set index.

### 4.3 Renewal and the fenced worker

Every worker renews every 15 s against a 60 s TTL (4 missed beats before anyone else may take over — enough to ride out a GC pause or a brief network blip, short enough that a crashed deploy is picked up within a minute):

```sql
UPDATE deployments SET lease_expires_at = now() + interval '60 seconds'
 WHERE id = $id AND lease_owner = $me AND lease_generation = $gen;
```

**Zero rows updated means the lease was lost. The worker must abort immediately** — no "let me finish this SSH call", no "I'm 95% through". It stops touching the host and drops the goroutine. The `deployments_assert_lease()` trigger (§2.1) is the backstop that turns a missed check into a failed write instead of corrupted state.

### 4.4 Fencing on the host (the half people forget)

A lease that has expired in Postgres may still be held by a worker that is alive but partitioned. Database fencing stops it corrupting the row; it does **not** stop it swapping a symlink. So the lease generation is also written to the host:

```
/srv/shipyard/leases/<deployment_id>/<lease_generation>.json
```

The Bash layer's destructive operations — symlink swap, `systemctl restart`, `rm -rf` of a release dir — read the current generation file and **refuse to act if the acting generation is lower than the highest generation on disk**. A zombie at generation 7 cannot clobber a legitimate generation 8. This is the Lamport-style fencing token, applied where it actually matters, and it is roughly fifteen lines of Bash. It is also the most impressive fifteen lines in the repo.

### 4.5 How a lease "that outlives its holder" is retired

Three independent mechanisms, in order of speed:

1. **Expiry is the primary mechanism.** `lease_expires_at` is a fact in the row; no process has to notice anything. The claim query's predicate `lease_expires_at < now()` *is* the reaper. There is no cleanup job to forget to write.
2. **Startup + periodic sweep.** Every 15 s, and once at boot, run the reconciliation query in §9.3. Any non-terminal deployment with a dead or absent lease is one the control plane must reconcile against the host before re-queueing — not blindly resume. A crashed `building` step is resumed by *checking the host* (does the build dir exist? is the artifact there? is the unit running?) and then continuing, discarding, or failing it explicitly.
3. **Generation monotonicity.** Generations never reset, so a resurrected old worker's writes are always detectably stale.

**Explicit decision: no `queue` table and no `reconcile_queue` table.** The work list *is* the query `state NOT IN (terminal) AND (lease_expires_at IS NULL OR lease_expires_at < now())`. A second table holding a copy of "what needs work" is a table that can disagree with the first, and a queue table that is only drained by a healthy worker is exactly the thing that silently grows forever during an outage.

---

## 5. Retention and lifecycle policy

### 5.1 Per-table classification

| Table | Authoritative | Keep | Why |
|---|---|---|---|
| `projects`, `servers` | Yes (intent) | **Forever** | Named entities in the audit record |
| `deployments` | Yes | **Forever** | The product's entire value. "Deployment #42" is the artifact. `failed` rows are arguably more valuable than `running` ones |
| `deployment_events` | Yes (audit) | **Forever**; partition-ready | ~8 MB/yr. If it ever needs retention, partition by month and drop partitions older than 7 years — a decision you can defer indefinitely |
| `environment_revisions` + `_variables` | Yes (ciphertext) | **Forever** | Old deployments must stay reproducible. `revoked_at` handles leaks without rewriting history |
| `audit_log` | Yes | **Forever** | Tiny |
| `deployment_services` | Yes (last observation) | **Forever** | 1–5 rows per deployment |
| `reconcile_runs` | No (operational telemetry) | **90 days** | Keeps the table at ~30k rows forever. Nothing downstream needs more |
| `servers.observed_*` | No (snapshot) | Overwritten in place | Last-known-host-state. History is Prometheus's problem |
| Build log files | No (diagnostics) | **Bounded — §5.2** | Rebuildable by re-running the build |
| Host metrics / health history | No | **Not in Postgres** | Prometheus |

Nothing is disposable except: expired lease fields (overwritten), `reconcile_runs` past 90 days, superseded env ciphertext on explicit purge, and log files past policy.

### 5.2 Build logs: the policy

**Storage: plain files on the control-plane host. Not Postgres. Not object storage (yet).**

Path: `/var/lib/shipyard/logs/<project-name>/<number>-<sha7>.log`, mode `0600`, appended by the Go worker as it streams the SSH channel's stdout/stderr.

| Rule | Value | Why |
|---|---|---|
| Hard cap per deployment | **200 MB** (head 50 MB + tail 5 MB, `log_truncated=true`) | One pathological `npm install` log cannot fill the disk |
| Hot retention | **30 days** | Realistically nobody reads a build log after a month |
| Cold retention | **180 days**, gzipped, same filesystem | Cheap (25:1 on build logs), and "I broke it in March" is a real question |
| Pinned | **Last 50 per project, forever** | A portfolio project always has something to show, and this is ~50 × 150 KB × 5 = 37 MB total |
| In DB | path, bytes, lines, `sha256`, `truncated` flag | Just enough to find and verify the file, and to notice a missing one |
| Also in DB | last 100 lines as a `log_tail` event at terminal time (~8 KB) | The UI timeline renders without any file I/O; the list view stays a pure SQL query |

**The math, honestly.** Assumptions: 3 projects, 40 deploys/project/month = 120/month = **1,440/year**. Average build log 150 KB (verbose `go build`, `npm install` output, `docker build` context lines) → **210 MB/year raw, ~25 MB/year gzipped**. Steady-state disk after the policy: ~10 MB hot + ~10 MB gzipped tail + 37 MB pinned ≈ **under 60 MB**. This is a rounding error on any control-plane host.

Now the same logs as Postgres rows: 150 KB ÷ ~180 bytes/line ≈ 830 lines → **1.2 M rows/year**. At ~300 bytes/row including indexes that is **~360 MB/year**, on top of TOAST chunks for long lines and the bloat/churn of a table being written to in bursts during deploys. That is **~10–20× the storage for zero capability gained** — you still cannot usefully `LIKE`-search a 60,000-line build log, and you have now coupled your most-bursty, least-relational workload to the same `pg_dump` as your ledger. The decision is not close.

**What the file choice costs the rest of the system — stated, not glossed:**

| Cost | Mitigation |
|---|---|
| Logs live outside the DB backup | Deliberate: logs are diagnostics, rebuildable by re-running the build. A dump that contains logs is a dump that is 20× larger and slower to restore for zero restore value. Back them up with restic on the same schedule if you want them; the drill in §8 must not depend on them |
| No SQL access to log content | Accepted. You have `less`, `grep`, `zgrep`, `jq` on the box — better tools than any SQL function, and they work while the DB is down |
| Search across all logs for a string | Out of scope until someone needs it. The right answer then is object storage + a log index, **not** a Postgres table and **not** a read replica |
| A host that loses its disk loses the logs of deploys it ran | Accepted, and mitigated by the `log_sha256` + pinned-50 rule: you know *that* you had a log and what it hashed to |
| No replication for logs | Fine. RPO for a diagnostic artifact is "re-run the build" |

**The honest counter-argument, and when it wins.** If the control plane ever runs on more than one node, or the logs are on a provider whose disk can vanish without warning, files lose. At that point the fix is a `LogSink` interface with a second implementation writing to S3-compatible object storage (Backblaze B2, ~$6/TB/mo, with lifecycle rules doing the 30/180-day tiers *for free, declaratively, in the provider*). That is why the writer must be an interface from day one even though the first implementation is `os.File`. The rule: **one interface, one implementation, written as if the second is coming** — because the second is coming eventually and rewriting a log writer that is sprinkled through the deploy loop is annoying.

### 5.3 Why keep the deployment record but discard the log

They answer different questions. The record answers *"what was the intent, what did it do, did it succeed, and what happened"* — that is the audit obligation, the rollback source of truth, the portfolio artifact, and the thing a schema migration three years from now has to be able to query. It is ~1 KB per deployment.

The log answers *"what exactly did line 4,812 print"* — that is a debugging convenience, valid only until someone pushes the fix. A 200 MB log for a failed build is 99.9% noise; the 0.1% that mattered is `error_code` and `error_message` on the row plus the `error` event. **Deleting a log destroys no information anyone will ever need; deleting a deployment row destroys the reason the project exists.**

### 5.4 Journald

Runtime logs are a different animal and belong in systemd, not here. `journalctl -u shipyard-<project>-<service> --since <deploy.finished_at>` is a *host-side, live, unbounded* stream. Shipyard does not copy it, does not index it, does not store it. It may set `StandardOutput=journal` + `SyslogIdentifier=shipyard-<project>` on managed units so filters are pleasant, and that is the entire extent of runtime log handling. If a runtime log is ever needed as evidence, capture it as an *artifact of a specific event* (`journalctl ... > /var/lib/shipyard/logs/.../runtime-<n>.log`) and record the path — an explicit, bounded, on-demand copy rather than a continuous pipeline.

---

## 6. Secrets at rest

### 6.1 Is Postgres the right home?

**Yes, for a solo project, with application-layer encryption.** The case for keeping them in the same database as the deployment rows is not "Postgres is a secret store" — it is transactional:

- A deployment and the exact env revision it will render must be created **atomically**. Create the deployment, render its `.env`, and you must not be able to end up with a deploy referencing a revision that was never committed, or a revision that no deploy references. `env_revision_id` is a `NOT NULL` FK. In an external secret store you would be hand-rolling a two-phase commit between two systems to get the same guarantee.
- The control plane is the only component that ever needs the plaintext. It needs it for ~200 ms, in memory, to write a file over an already-encrypted SSH channel.
- Backup and restore are one unit. A restored database is a fully working system.

The case against is real but bounded: an SQL injection, an accidental `SELECT *` into a log line, or a leaked `pg_dump` reveals the secrets — *unless* the application encrypts before writing, which is the design below.

### 6.2 The design

- **AEAD at the application layer: AES-256-GCM.** Not `pgcrypto` in the database. The reason is not crypto expertise — it is that if the database process can decrypt, then a `psql` session as any role with table access can decrypt, and so can every tool that can read the heap. Application-layer encryption means the key is a secret the database *does not have*.
- **Key custody:** `SHIPYARD_MASTER_KEY` supplied by the systemd unit via `LoadCredential=` (a `0600` root-owned file) or a `EnvironmentFile` marked `0600`. Never in the repo, never in a compose file, never in an env var visible in `/proc` to other users. Back it up in a password manager, **separately from the database** — see §8.3 for why that separation is the whole point.
- **AAD binds ciphertext to its row:** `AAD = project_id ‖ revision_id ‖ key ‖ scope`. Consequence: an attacker with write access to the table cannot move a `DATABASE_URL` from project A to project B, cannot swap two values within a revision, and cannot change a `scope` to smuggle a build-time secret into a runtime file. Without AAD, `pgcrypto`-style encryption is just base64 with extra steps.
- **Key rotation** via `key_version smallint`. Read path tries the current key, falls back to older ones; a background `re-encrypt` command rewrites rows and bumps the version. Rotation is a command, not a migration.
- **Zero plaintext columns, no preview, no masking, no admin "reveal" endpoint.** There is no `is_secret` flag because everything is secret. A break-glass decrypt feature is not worth it here: it is an endpoint whose existence is the vulnerability.
- **Roles and views, so the UI cannot read ciphertext even by accident.** The app connects as `shipyard_app` (owner of the tables); a separate `shipyard_readonly` role is used by psql, backups review, and any analytics. `GRANT SELECT (key, scope, revision_id, created_at)` — column-level, or better, expose a view `environment_keys` and grant only that. Add RLS on `environment_variables` with a policy for the service role only, as defence in depth against a future migration that accidentally grants broadly.
- **Logging:** the Bash layer greps for and redacts `=`-bearing lines matching known secret keys before anything reaches a log stream, and the Go layer never logs env values. This is imperfect and is stated as such — redaction of arbitrary program output is not fully solvable. The mitigation is that the *primary* protection is the ciphertext, not the redaction.
- **Threat model, stated so a reviewer can check the reasoning:** the realistic attacker is someone who reaches the control-plane host, or a laptop theft. Both are covered by 0600 key custody, provider disk encryption, and app-layer AEAD. KMS/Vault covers a *different* threat: dozens of services, automated rotation, audit of who-read-what. **Recommendation: do not adopt a KMS or Vault.** For one service, one operator, it adds an availability dependency, a second backup obligation, and a second thing to page about, in exchange for protection against a threat model that does not apply here. Keep the key in an env var so a KMS-backed key source is a config change, not a code change, and the reviewer can see the migration path is one line away.

### 6.3 Env versioning: resolving write-only vs. reproducible

The tension is real and the resolution is that **"write-only" is an API-surface property, not a storage property.** The API never returns plaintext. The *database* holds immutable, versioned ciphertext, permanently.

- `environment_revisions` are **append-only and never mutated**. Editing an env value creates version `N+1`; it does not touch `N`.
- `deployments.environment_revision_id` is `NOT NULL` and **immutable** (trigger, §2.1). The environment is frozen at creation, because "env changes are a deploy boundary" is enforced by the schema rather than by the API remembering to check.
- Therefore "reproduce the exact environment deployment #42 ran with" is `SELECT ... WHERE revision_id = d.environment_revision_id`, with no decryption required to *find* it, and decryption possible only with the key.
- `content_hash` makes the common question — "did anything actually change?" — answerable by comparing two 32-byte hashes instead of decrypting and diffing.
- `deployments.env_rendered_sha256` closes the loop to the host: after rendering, hash the bytes written to `shared/.env` and store the hash. If the two ever disagree, the host was tampered with or a partial write happened. The plaintext still never enters the database.

**The one honest cost:** retaining ciphertext forever means retaining the ability to decrypt forever. If a key leaks, the only complete remediation is to destroy the ciphertext of that revision — which *does* break reproducibility of the deployments that used it. The design makes that trade explicit rather than accidental:

1. `revoke` the revision (`revoked_at`) — blocks it from being selected by new deployments. Historical fidelity is preserved. This is the normal path.
2. If the secret itself is compromised (not the DB), destroy the ciphertext for that revision via a maintenance command that writes an `audit_log` row naming the revisions destroyed and the deployments affected. Past deploys are then marked `env_unreproducible` rather than silently lying.
3. Accept that the trade is "audit trail with holes beats a key that stays valid forever", and say so in the README.

---

## 7. Migrations and schema evolution

### 7.1 Position

- **Use a tool.** `golang-migrate` — versioned files on disk, embedded in the binary, `up`/`down`, `dirty` state detection, a single `schema_migrations` table, and a CLI that is exactly what CI needs. It is boring, has no daemon, no dependency on a running app, and works on a database you just restored from a dump. (Atlas is the better choice if you want declarative schema-as-code diffing; the trade is a build step and a declarative file that can disagree with the migrations. For a solo project, migrations-as-files is the smaller surface.)
- **Migrations are files in the repo, applied in order, never hand-edited after they touch a shared or production database.** `make db-migrate` locally; the same binary runs migrations on boot under a `pg_advisory_lock` so two replicas (or two deploys of the control plane) cannot race.
- **Forward-only in production. Down migrations exist for local dev and are never run by the deploy pipeline.** The reason: a down migration is written once, at a moment when you believe you understand the data, and it is correct exactly in the environments that resemble the one you tested. A production rollback of a bad migration is a *forward* migration that undoes it, written with full knowledge of what the bad one did to real rows. Keeping down files costs a few minutes and buys `make db-reset` for free.
- **Zero-downtime: state the position rather than ignore it.** The control plane is a single binary serving one operator; thirty seconds of downtime during a control-plane deploy is acceptable and not worth a dual-binary dance. The one hard rule that *is* about the database:

  > **Never ship a schema change and a code change that depends on it in the same control-plane deploy.**

  During a restart, the old and new binary can both be running. The migration must be backward-compatible with the *old* binary. This forces the expand/contract pattern for anything non-additive:

  | Step | Operation | Safe against old binary? |
  |---|---|---|
  | 1 | `ADD COLUMN ... NULL` (or new table) | Yes |
  | 2 | Deploy code that writes both / reads new-or-old | Yes |
  | 3 | Backfill in bounded batches, with `updated_at` touched | Yes |
  | 4 | Deploy code that reads only new | Yes |
  | 5 | `DROP COLUMN` in a *later* release | Yes — nothing reads it |

  For this schema the only realistic version of this dance is a `deployments.state` rename or a `jsonb` field becoming a column. Do the five steps, take the extra day, and put it in the commit message.

### 7.2 When a migration is wrong and already applied

The procedure, in order:

1. **Do not edit the applied file.** Shared dev databases and any restored copy have that version recorded; editing creates a version whose content differs from its number, which is a corruption of the migration history that will bite you during a restore six months from now. Exception: if the migration has not been committed or shared, editing is fine — run `migrate force <version>` on your own DB afterwards.
2. **Check the dirty flag first.** If `schema_migrations` says `dirty = true`, the migration failed partway. `migrate force <version>` to the last good version, then repair by hand, then re-apply.
3. **Write a corrective forward migration** (`0007_revert_0006_wrong_default.sql`) that returns the schema to where it was. For DDL, mirror the original statements. For data damage, write the repair as data — `DELETE FROM deployments WHERE created_at < '2026-01-01' AND state = 'pending'`, or an `UPDATE ... FROM` for a corrupted column.
4. **Separate schema from data.** A migration that both changes a column type and backfills 40 M rows is a migration that will time out. Keep backfills in their own numbered step, batched (`LIMIT 10000` in a loop, or a `pg_cron` job), and make every backfill idempotent (`WHERE ... IS NULL`).
5. **Deploy the corrective migration before the code fix** if the code depends on the corrected shape; otherwise a running old binary may write the old shape back. In practice: migration, then code, and if the bad migration is causing *active* damage, put the control plane into maintenance mode (reject new deploys, let in-flight ones finish) rather than racing it.
6. **Record it.** `audit_log` gets a `migration.reverted` row with the versions involved. A schema rollback that is not in the audit log is a schema rollback that will be re-attempted by the next person.

### 7.3 The test that saves you

Because the whole system is declarative about intent-vs-observed, a migration that flips the meaning of a column (`is_active` from intent to derived, say) is the dangerous kind. Add a CI check that runs `migrate up` on a scratch database seeded by `seed --fake --days 90` and then asserts the invariants from §2 still hold — one `is_active` per slot, no orphans, event/state agreement. **Invariant assertions in CI, not only in a dashboard.** It converts "we changed the schema" from a leap of faith into a test result.

---

## 8. Backup, restore, and dev/prod data

### 8.1 What RPO/RTO actually means here

Be honest about what the loss scenarios are, in order of expected damage:

| Scenario | Impact | RPO that matters | Target |
|---|---|---|---|
| Laptop dies (has the DB *and* the master key) | Catastrophic: ledger gone **and** env secrets unrecoverable | Irrelevant if not backed up off-machine | Key in a password manager, nightly dump off-machine |
| VPS disk lost by the provider | Ledger gone, keys fine, hosts fine | 1 minute | WAL archiving to off-site object storage |
| Bad migration, table dropped | Recent deploy ledger gone | 1 minute | WAL archiving + PITR |
| Worker crash mid-deploy | One deployment's run state | 0 — reconciliation fixes it | 60 s lease |
| Build log lost | Nothing | 0 | Rebuildable |
| A host vanishes | One server row + its observed fields | 0 | Re-provision from the script |

**Committed position: RPO 5 minutes, RTO 30 minutes.** Nightly `pg_dump` alone gives RPO 24 h and is *not* good enough for the one table that matters, so:

```bash
# Nightly, cron, 03:17 (off the :00 spike)
pg_dump -Fc -Z6 shipyard > /backup/shipyard-$(date -Iseconds).dump.zst   # custom format → pg_restore
pg_dumpall --globals-only > /backup/globals-$(date -Iseconds).sql          # roles, so restore is complete
pg_dumpall --globals-only --no-role-passwords >> ...                       # no secrets in the backup dir
```

```conf
# postgresql.conf — continuous, so RPO is minutes, not a day
archive_mode = on
archive_command = 'rclone -q --config /etc/rclone/rclone.conf archive %p s3-b2:shipyard-wal/%f'
archive_timeout = 300        # force a segment every 5 min even when idle
restore_command = 'rclone -q --config /etc/rclone/rclone.conf copy s3-b2:shipyard-wal/%f %p'
```

Point-in-time recovery is then `recovery_target_time = '<when>'` and a `pg_wal` restore. Off-site, so the "provider lost the disk" scenario is survivable. At ~25 MB/year of data, the entire archive costs cents per month and a full restore is a `pg_restore` of a 5 MB file.

### 8.2 What is genuinely backed up vs. rebuildable

| | Backed up? | Why |
|---|---|---|
| `deployments`, `deployment_events`, `servers`, `projects`, `services` | **Yes** — nightly dump + continuous WAL | Unreproducible. This is the product. It *is* the portfolio |
| `environment_revisions` ciphertext | **Yes** | Same, plus reproducibility of past deploys. The master key is backed up **separately** (password manager) so a stolen backup is useless without it |
| `audit_log` | **Yes** | Legal/audit obligation |
| Build logs | Optional (restic, same schedule) | Diagnostics. RPO 0 by re-running the build |
| Hosts | **No** | Rebuildable from a provisioning script / cloud-init in ~10 min. Store the scripts in git; the *data* is the servers table, and the boxes are disposable |
| The lab (Docker Compose stack) | **No** | The compose file *is* the definition. It is in git. This is the answer to "nobody depends on a private dump" |
| Prometheus metrics | No | 15-day retention upstream, by design |
| SSH keys | **No** — backed up to a password manager | Never in the DB, never in a dump |

### 8.3 Restore drill (monthly, 30 minutes, timed, on a calendar)

Non-negotiable, because a backup nobody has restored is a rumour. Written as a script (`scripts/restore-drill.sh`) so it is repeatable and the wall-clock becomes a measured number in the README rather than an aspiration.

1. **Provision a scratch host** — a throwaway 2 GB VM or a container. Record the start time. *(This is the RTO clock.)*
2. `apt-get install postgresql-<ver>`, create the `shipyard` role and empty database.
3. `pg_restore --clean --if-exists --jobs 4` the newest dump. `psql -f globals.sql` for roles.
4. **Integrity assertions** — this is the part people skip:
   - `SELECT count(*) FROM deployments` matches the `audit_log` high-water mark from the dump date.
   - The §2.2 invariant query returns zero violations: no (project, server) with more than one `is_active`; no (project, server) with two `slot_busy` rows.
   - Zero orphans: `NOT EXISTS` on both sides of every FK.
   - The §9.4 drift query returns zero rows: no deployment whose `state_event_seq` disagrees with its event log.
   - Every `terminal` state has a matching `state_change` event; no `running` deployment is older than 7 days.
5. **Decrypt check** — pick the newest environment revision, decrypt one value with the master key from the password manager, assert the AEAD tag verifies and the value round-trips. This proves the key backup is real, which is the step everyone discovers is broken during a real incident.
6. **Functional check** — point the restored DB at a scratch host, register it, and run one real end-to-end deploy of a throwaway project. Confirm the UI shows `running` and `is_active=true`, and that `readlink shared/current` on the box agrees.
7. **Record** the elapsed time into `docs/runbooks/restore-drill.md` with the date. If it exceeds 30 minutes, that number is the RTO and the README should say so.

### 8.4 Reproducible dev database — the no-dumps rule

The rule is: **no database dump is ever committed to the repository, and no developer is ever blocked on someone else's dump.** A `pg_dump` in git is a fork of the schema that nobody reviews, contains real environment data by accident, and goes stale within a week.

```bash
docker compose up -d db            # postgres:17, pinned digest, port from .env
make db-migrate                    # up from zero, always
make db-reset                      # drop + create + migrate + seed
```

- `shipyard seed --fake --days 90` is a real command in the Go binary (not SQL, not fixtures) that generates: 3 projects, 5 servers, ~360 deployments spread over 90 days with a realistic success/failure distribution, a `failed` deploy with a `health_timeout` and 40 log lines, a `running` deploy, a rollback chain, 40 environment revisions, and — critically — **two deployments stuck mid-flight with expired leases**, because that is the fixture the reconciliation tests need and the one nobody ever thinks to write.
- Deterministic seed (`-seed 42`) so failures reproduce.
- `make test-integration` runs against this database. The reconciliation test asserts that after boot, the two expired-lease deployments are picked up, checked against a fake host, and resolved to a definite state.
- A CI job runs the whole sequence from an empty volume every commit, so "works on my machine, dump was newer" is structurally impossible.

The seed command is worth more than it looks: it is simultaneously a dev fixture, a test fixture, a demo-data generator, and a demonstrable answer to "how do you develop against real data without real data".

---

## 9. The reconciliation read path

Two audiences, two shapes.

### 9.1 Operator: "deployment #42 of project X — what is it doing, and why did it fail?"

Three cheap reads, all primary-key or single-index seeks:

```sql
-- 1. The current state. One row.
SELECT number, commit_sha, requested_ref, state, state_changed_at, is_active, active_verified_at,
       lease_owner, lease_expires_at, release_dir, log_path, log_bytes, log_truncated,
       error_code, error_message, started_at, finished_at, duration_ms
  FROM deployments
 WHERE project_id = $1 AND number = $2;
```

```sql
-- 2. The timeline. THE query for understanding a failure.
SELECT seq, created_at, type, from_state, to_state, worker_id, attempt, message, error_code, metadata
  FROM deployment_events
 WHERE deployment_id = $1
 ORDER BY seq;                          -- (deployment_id, seq) is already indexed; this is an index scan
```

```sql
-- 3. Per-unit observed reality.
SELECT s.name, ds.desired_action, ds.systemd_active_state, ds.systemd_sub_state,
       ds.active_entered_at, ds.restart_count, ds.health_status, ds.health_checked_at, ds.health_detail
  FROM deployment_services ds JOIN services s USING (service_id)
 WHERE ds.deployment_id = $1;
```

Then, **outside the database**: `head -n 200` of `log_path` and `readlink /srv/shipyard/shared/current`. The deliberate point is that the DB answers *what and why* in three index seeks, and the host answers *what is true* in two shell commands. The UI composes them; it does not make Postgres a log viewer.

**Implied indexing** (design, not tuning — `postgres-pro` picks the exact form): `(project_id, number)` already unique and serving #1; `(deployment_id, seq)` already unique and serving #2 — **this is the single most important index in the database**, and it is free because it exists for correctness; `(deployment_id)` for #3. The honest note: three of the four reads are already covered by indexes that must exist anyway for integrity. This is what a well-chosen primary key buys you.

### 9.2 Control plane, startup: find work to reconcile

Run once at boot, then every 15 s. **This is also the reaper — there is no separate cleanup job (§4.5).**

```sql
SELECT d.id, d.project_id, d.server_id, d.number, d.state, d.state_seq, d.lease_generation,
       d.observed_current_release, d.commit_sha, d.release_dir, d.abort_requested_at
  FROM deployments d
  JOIN servers s ON s.id = d.server_id
 WHERE d.state NOT IN ('running','failed','canceled')     -- non-terminal
   AND (d.lease_expires_at IS NULL OR d.lease_expires_at < now())
   AND s.lifecycle <> 'decommissioned'
 ORDER BY d.started_at NULLS FIRST
 LIMIT 200;
```

For each row, the reconciler then asks the **host**, in one SSH round trip per server (batched — do not open one connection per deployment):

```
readlink -f /srv/shipyard/shared/current
for u in <all units of this project on this server>: systemctl show $u -p ActiveState -p SubState -p NRestarts -p ActiveEnterTimestamp
ls /srv/shipyard/releases/<project>/           # what actually got built
cat .../releases/<...>/.shipyard/state.json
```

and then decides, in priority order: `abort_requested_at IS NOT NULL` → `canceled`; unit active and healthy but state is non-terminal → `running`; unit inactive and release dir exists → restart or fail with `systemd_start_failed`; release dir missing mid-`build` → resume or `failed` with `build_interrupted`; no `current` symlink at all → `failed` with `release_missing`. Each decision is an event (`reconcile_apply`) and an `is_active` update in the same transaction as the `state` update. Then `reconcile_runs` records the batch outcome.

**Implied indexing:** a **partial index over the non-terminal set**, ordered by the staleness key, so the startup sweep is an index scan touching only in-flight rows rather than a seq scan over all history forever:

- partial index on `deployments (started_at)` with predicate `state NOT IN ('running','failed','canceled')` — or, if `postgres-pro` prefers, `(coalesce(lease_expires_at, '-infinity'))` in the same partial form so the "most overdue first" ordering is index-ordered. Either is fine; the *requirement* is: **partial predicate = the non-terminal set, ordering = staleness.**
- `servers (lifecycle) WHERE archived_at IS NULL` — **do not create this one.** `servers` has tens of rows. A seq scan is optimal, an index is write overhead, and "index every foreign key" applied to a 40-row table is a smell that will be noticed in review.

### 9.3 Control plane, per-server health sweep (independent of deployments)

```sql
-- Which servers have not been reconciled recently? Small table, sequential is correct.
SELECT id, name, hostname, lifecycle, last_seen_at
  FROM servers
 WHERE lifecycle IN ('active','draining')
   AND (last_seen_at IS NULL OR last_seen_at < now() - interval '60 seconds')
 ORDER BY last_seen_at NULLS FIRST;
```

This is the "unreachable box" alarm and it needs no index.

### 9.4 The drift detector (weekly, and in CI)

```sql
-- Does the denormalized state cache agree with the authoritative event log?
SELECT d.id, d.number, d.state, d.state_seq, d.state_event_seq, max(e.seq) FILTER (WHERE e.type = 'state_change') AS log_seq
  FROM deployments d
  JOIN deployment_events e ON e.deployment_id = d.id
 GROUP BY d.id, d.number, d.state, d.state_seq, d.state_event_seq
HAVING d.state_event_seq IS DISTINCT FROM max(e.seq) FILTER (WHERE e.type = 'state_change');
```

Must return zero rows, always. This is the query that lets a reviewer believe the "events are authoritative, the column is a cache" design is not hand-waving. Served by `(deployment_id, seq)`.

---

## 10. Read/write separation and growth

### 10.1 The honest load analysis

| Path | Rate | Shape | Verdict |
|---|---|---|---|
| Append build log lines during a live deploy | 830 lines/deploy × 120 deploys/mo = **0.04 writes/second** average, in 1-minute bursts of ~14 writes/sec | Would be the hottest write path *if it were in Postgres* | **Not a Postgres problem — it is a file.** §5.2 |
| Transition writes during a deploy | 8 state transitions + 20 events = **~30 writes over ~4 minutes** | Row updates + inserts on one row | Trivial. The CAS is an index lookup on a PK |
| "Last N deployments for project X" | Every page view of the main screen | `(project_id, number DESC)` → index scan, already ordered, 20 rows | Trivial. This is what the PK cluster-ordering choice buys |
| "What is running right now across all servers?" | Every dashboard poll, every reconcile | Partial index `WHERE is_active` → at most one row per slot, so **the result set is bounded by the number of servers**, not by history | Trivial, and **cacheable in-process for 5 s** without a cache tier |
| Environment decrypt + render | 1 per deploy, ~20 values | 20 AES-GCM ops on ~100-byte values | Microseconds |
| Reconcile sweep | 1 per 15 s | ≤ in-flight rows, usually 0–3 | Trivial |
| Heartbeat renewals | 1 per 15 s per active deploy | PK lookup + update | Trivial |

**Total sustained write load on a solo project: well under 1 write/second, in bursts of tens.** Database size: **under 25 MB/year.** Autovacuum needs no tuning, connections need no pooler beyond Go's `pgx` defaults, and `shared_buffers` of 128 MB holds the entire working set. There is no hot path. Say that plainly rather than inventing one.

### 10.2 Where a read replica, cache, or second store is **wrong** here

- **A Postgres read replica.** A replica needs a second machine, its own backup, WAL shipping, monitoring, and failover — for a dataset that fits in a 128 MB buffer cache. It cannot make writes faster (the write path is not the bottleneck), it adds a replication-lag failure mode to reconciliation, and it introduces a *second* source of truth for the one question you must never have two answers to. Blatantly wrong at this scale. Revisit around 50 M event rows or a second reading application with a materially different query profile.
- **Redis / Memcached in front of Postgres.** There is nothing to cache. The hottest read returns ≤ #servers rows and is served from the page cache. A cache in front of a 25 MB database adds an invalidation problem and a new failure mode in exchange for microseconds you already have.
- **A message broker (NATS/Redis Streams/RabbitMQ) for deploy dispatch.** A second datastore with its own durability, backup, and partial-failure semantics, to carry ~1 message per 3 minutes. The `slot_busy` partial index *is* the ready queue, it is transactional with the work item, and it cannot get out of sync with it.
- **A second store for deployments.** Deployment creation must atomically bind `environment_revision_id`. Cross-store atomicity is hand-rolled 2PC. Postgres is the right tool precisely because it is the only place this transaction can be atomic.
- **A sharded or partitioned schema.** Not now, not for years. The schema is *partition-ready* (`deployment_events` keyed `(deployment_id, seq)` with a `created_at` column, so a future `PARTITION BY RANGE(created_at)` is a mechanical change), but shipping partitions at 25 MB/year buys nothing and costs a second thing to test.
- **Time-series in Postgres for host metrics.** Explicitly wrong. CPU, disk, memory, and health-probe latencies go to Prometheus, where retention, downsampling, and alerting already exist. Postgres gets the last sample as columns on `servers` and nothing else.

### 10.3 Where a second store **would** be right (triggers, not plans)

| Trigger | Then |
|---|---|
| Control plane runs on >1 node, or logs live on a disk that can vanish | Object storage for build logs via the `LogSink` interface (§5.2) — B2/S3 with lifecycle rules implementing the 30/180-day tiers declaratively |
| Someone needs full-text search across all historical build logs | Object storage + a log index (Loki/ClickHouse). **Not** Postgres `tsvector`, **not** a replica |
| `deployment_events` passes ~50 M rows | Monthly range partitions, then possibly a read replica for the UI if the read profile diverges from the write profile |
| A public status/history page needs to survive a control-plane deploy | Static export to object storage. Not a database |
| Health-probe latency needs a 90-day graph | Prometheus — already there. Never a table |

The general principle: **at this scale, Postgres is not the wrong tool — it is the only tool. Discipline is about not adding the fifth datastore, and about keeping metrics and byte-stream logs out.**

---

## 11. Ten data-modelling mistakes this project will make if built naively

Ordered by likely damage, worst first.

### 1. Destroying deployment history with a `DELETE` or a `CASCADE`
The instinct is "clean up the deployments table, it will grow forever" — or worse, an `ON DELETE CASCADE` from `projects` that nobody notices until a project is archived. Deployments *are* the product. Deleting them destroys the rollback target, the audit obligation, the demo material, and the answer to "why did the API time out on June 3rd". Unrecoverable, and no backup helps if the backup also predates it or you drop the table in the same command.
**Mechanism:** `RESTRICT` on every FK into `deployments` (§2.3); no delete API; purge only via `purge_terminal_forever.sh` for terminal, non-active, unreferenced rows older than N years, gated on an explicit dump; every purge writes `audit_log` first. Retention is *bounded* (90 days for `reconcile_runs`) not *destructive*.

### 2. Storing environment values in plaintext, with no revision, in a `settings` key/value table
`kv(project_id, 'env', '{"DATABASE_URL":"postgres://..."}')` is what a prototype does, and it is the single worst thing in this list. It leaks into `pg_dump`, into any SQL access, into a log line; it cannot be rotated without rewriting a blob that past deploys depend on; and it makes "reproduce the env of #42" impossible the moment anyone edits a value. A leaked `API_KEY` becomes a permanent, silent problem.
**Mechanism:** AEAD-encrypted, `NOT NULL` `environment_revision_id` on the deployment, immutable revisions, `content_hash` for change detection, no plaintext column, no preview, no reveal endpoint (§6). The *architecture* mistake here is a `key/value` table for structured data — it defeats every future query and every future constraint.

### 3. Inferring liveness from `status = 'running'`, and not enforcing the exclusivity invariant at all
Two failure modes in one: (a) `state='running'` is used as "this is live", so a crashed control plane leaves a permanently wrong live state and a health check that never re-runs; (b) the exclusivity rule lives only in Go code as `if !hasActive { ... }`, so two concurrent deploys, a manual SSH deploy, and a retry-after-timeout can both symlink and the DB happily holds two `running` rows. The bug is discovered during a demo, not a review.
**Mechanism:** separate `state` (run outcome) from `is_active` (host-derived, written only by reconciliation, with `active_verified_at`); the partial unique index for one-active and one-inflight per slot (§2.2); a *DB-generated* `slot_busy` so the serialization constraint is derived and cannot drift; a drift alert on `active_verified_at` staleness.

### 4. Holding a database transaction open across an SSH or systemd call
The instinct is "`BEGIN`, write state, call the host, write result, `COMMIT` — atomic!`" It is not atomic, and it is expensive: the row lock is held for the full 4-minute build, so the UI's own `SELECT` on that row can block, `idle in transaction` sessions accumulate, a crash mid-build leaves the lock held until TCP teardown, and you have built a de-facto lease out of a connection that dies with the process. It looks rigorous and is the worst of both worlds.
**Mechanism:** transactions of two statements, sub-millisecond, never spanning a remote call (§3.3). The DB records *that* an effect is about to happen; the host performs it; reconciliation closes the gap if the process dies in between. This is saga-with-reconciliation, and the design admits it in the schema (`is_active` is host-derived) rather than pretending to have distributed transactions.

### 5. Claiming work with a bare `SELECT ... FOR UPDATE` and no lease
`SELECT ... FROM deployments WHERE state='pending' FOR UPDATE SKIP LOCKED` inside a long-lived transaction is the idiomatic queue pattern and it is correct — *for a transaction that is short*. Wrapped around a multi-minute deploy, a worker crash wedges that (project, server) slot **permanently**: the row's state is `building` forever, the orchestrator will never re-pick it, and the only fix is manual SQL. The symptom in production is "one project just stopped deploying and nobody knows why", and there is no error message anywhere.
**Mechanism:** a lease with an explicit expiry, a `SKIP LOCKED` *selection* narrowed to short transactions, a CAS `UPDATE` that fences (`lease_owner` + `lease_generation`), renewal on a heartbeat, and the same `WHERE` clause doubling as the reaper so no cleanup job can be forgotten (§4). Plus a `deployments_assert_lease()` trigger and on-host fencing tokens, because a lease that is only enforced in the database is half a lease.

### 6. Build logs as rows in Postgres
`build_log_lines(deployment_id, seq, ts, stream, message)` looks tidy and is a trap. It is 10–20× the storage of files for no gained capability (§5.2), it puts the most bursty, least-relational workload on the same instance as the ledger, it bloats `pg_dump` and slows every restore, and — the real damage — it invites `WHERE message LIKE '%error%'` across millions of rows, which will be the one query that takes the control plane down. It also couples *retention of a diagnostic* to *retention of the record*, so the temptation returns to delete deployments to shrink the table. That is how mistake #1 happens.
**Mechanism:** files on the control plane behind a `LogSink` interface, path/size/sha256 in the row, a `log_tail` event for the UI, and an explicit note that a 200 MB cap plus head/tail beats an index you will never use.

### 7. Mutable deployment identity
Storing `branch` (not SHA), or updating `commit_sha` in place, or allowing `server_id` to change so you can "just move it" during a migration. Each of these silently redefines the meaning of history. The invariant that makes the system auditable — *deployment #42 means `a81c92e`, forever* — is destroyed, and rollback starts lying about what it rolled back to.
**Mechanism:** the immutability trigger (§2.1) covering `(project_id, server_id, number, commit_sha, requested_ref, environment_revision_id)`; `requested_ref` stored *separately* so the audit trail records what the user typed without weakening the SHA guarantee; migration and rollback expressed as **new rows** with `supersedes_` / `rollback_of` (§1.9). The design smell to watch for: any UPDATE to an identity column in a future migration.

### 8. No append-only event stream — or one that is not append-only
The `status` column alone means that when the control plane dies at `state='building'`, you know a label and nothing else: not which step, not whether the worker was alive, not how long it had been there, not what it did. The operator story becomes "it says failed", which is exactly the uninteresting demo. And a `status_history` table that the same code path can `UPDATE` is not an audit trail — it is a second status column with extra steps.
**Mechanism:** `deployment_events` with `(deployment_id, seq)` total ordering, `UPDATE`/`DELETE` revoked at the privilege level *and* blocked by trigger, one transaction per transition with a CAS, and `state_event_seq` so the denormalized `state` column is provably a cache of the log (§3). Cost: 8 MB/year. Benefit: a failure story, a rollback story, and a reconciliation anchor. Overwhelmingly worth it.

### 9. Reaching for the wrong tool: metrics in Postgres, and a broker/queue for work dispatch
The two scaling reflexes that arrive early. A `server_metrics(server_id, ts, cpu, mem, disk)` table because "we already have a database" — which is a 90-day-retention time series with no downsampling, alerting, or query language, growing 500 k rows/day, queried by `GROUP BY` on a growing window. And a NATS/Redis-stream deploy queue because "we need a queue" — a second datastore with its own durability, backup, and partial-failure modes, carrying one message every three minutes, that can disagree with `deployments` about what is pending.
**Mechanism:** Prometheus for metrics, and `servers.observed_*` as an in-place last-sample snapshot only (§10.2); the work queue *is* the `slot_busy` partial index, with the lease columns as its state — one table, transactional with the work item, impossible to desynchronize (§4.1).

### 10. Optimizing for scale you do not have, while skipping the primitives that matter
The failure mode is asymmetric. You will add a read replica or a cache layer or a partition scheme for a 25 MB/year database, and simultaneously ship without: `NOT NULL` on everything that must exist, `timestamptz` everywhere (never `timestamp` — a UTC bug in a UTC-only project is a bug that appears in somebody's else DST), native enums instead of `text` (so `varchar(32)` `'runnning'` is a *constraint violation* instead of a value that never matches a switch case), a monotonic `state_seq` on the state machine, a `uuid v7` (so PK inserts stay ordered instead of scattering B-tree pages on every v4), and `created_at`/`updated_at` on every table because you will need them in a `WHERE` during an incident at 2 a.m. None of these are optimizations; they are the difference between a bug that is a clear constraint violation at 3 p.m. and one that is a mystery at 2 a.m.
**Mechanism:** §7.3's CI job — migrate a fresh DB, seed 90 days, assert the §2 invariants *and* the §9.4 drift query. Encode the primitives as a review checklist in the PR template. The scale items can wait for a scale problem; the primitives cannot wait for a review.

---

## Appendix A — Ownership summary (the table to argue from)

| Question | Authoritative source | Postgres representation | Freshness |
|---|---|---|---|
| What was requested? | Operator / API | `I` columns on `deployments` | Instant, authoritative |
| What env did it run with? | The pinned revision's **ciphertext** + master key | `environment_revisions` (immutable) | Instant, authoritative |
| How far did the run get? | The worker, while it was alive | `state` (cached) + `deployment_events` (authoritative) | Accurate to the last commit; stale if the worker died |
| Which worker owned it, and is it alive? | The lease | `lease_owner`, `lease_expires_at`, `lease_generation` | Self-expiring |
| What is live on the box? | **The `current` symlink** | `is_active` + `active_verified_at` | Stale by one reconcile interval (15 s) |
| Are the units healthy? | systemd | `deployment_services.systemd_*` | Stale by one heartbeat |
| How full is the disk? | The filesystem | `servers.disk_used_bytes` (last sample) | Stale by one heartbeat; **history lives in Prometheus** |
| What did the build print? | A file on the control plane | `log_path` + `log_sha256` | Immutable once written |
| What is the system's *intent* vs its *reality*? | Postgres vs. the host, compared | — | The difference **is** the reconcile workload |

## Appendix B — Invariant checklist for review

1. `UNIQUE (project_id, server_id) WHERE is_active` — at most one live deployment per slot. *(DB)*
2. `UNIQUE (project_id, server_id) WHERE slot_busy` — at most one in-flight run per slot. *(DB, derived)*
3. `commit_sha`, `server_id`, `project_id`, `number`, `environment_revision_id` immutable after insert. *(DB trigger)*
4. `project.name` immutable once a deployment exists. *(DB trigger)*
5. `state` transitions are append-only, CAS-guarded by `state_seq`, one event per transition in the same transaction. *(DB + app)*
6. `state_event_seq` always equals the last `state_change` event's `seq`. *(DB, verifiable — §9.4)*
7. `deployment_events` cannot be updated or deleted. *(DB privileges + trigger)*
8. `environment_revisions` are immutable; a `revoked_at` revision cannot be selected for a new deployment. *(DB + app)*
9. Only the lease holder may write `state` or any `observed_*` column. *(DB trigger on the worker GUC)*
10. No deployment is hard-deleted; no audit-bearing table is ever cascade-deleted from. *(DB FKs + no API)*
11. `deployments` has exactly one writer per lease generation. *(DB trigger)*
12. Every non-terminal deployment with an expired lease is discovered within one reconcile interval. *(Derived from lease expiry — no job to forget)*
