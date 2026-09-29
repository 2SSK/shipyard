# Verified findings — Shipyard build primitives

All claims below were **empirically tested on PostgreSQL 18.6** (2026-09-29) or
confirmed against authoritative docs. These are the load-bearing facts. Anything
not listed here should be treated as unverified until tested.

---

## 1. Postgres — verified by experiment

### 1.1 `slot_busy` as a STORED generated column: **LEGAL** ✅

The DBA design was right; an earlier research note claimed this was impossible
and was **wrong** (it conflated a generated column over `now()` with one over an
enum membership test).

```sql
CREATE TYPE deployment_state AS ENUM
 ('pending','cloning','building','configuring','starting','health_checking',
  'running','failed','canceled');

ALTER TABLE deployments ADD COLUMN slot_busy boolean
  GENERATED ALWAYS AS (
    state IN ('pending','cloning','building','configuring','starting','health_checking')
  ) STORED;                                    -- ✅ CREATED

CREATE UNIQUE INDEX d_one_inflight
  ON deployments (project_id, server_id) WHERE slot_busy;   -- ✅ CREATED
```

- Generated column expressions must be **immutable**. An ENUM membership test is
  immutable → legal.
- Negative control: `GENERATED ALWAYS AS (lease_expires_at > now())` →
  `ERROR: generation expression is not immutable` (now() is STABLE). So
  **never** build a generated column over `now()`.
- **Enforcement verified**: a second in-flight deploy to the same
  `(project_id, server_id)` raises
  `ERROR: duplicate key value violates unique constraint "d_one_inflight"`.
  When the first row reaches a terminal state the slot frees automatically.
  This is the whole "one in-flight deploy per server+project" rule, in the
  database.

### 1.2 A crashed worker does NOT leave rows locked forever ✅ (proves the lease's real purpose)

Two-session experiment:

1. Session A: `BEGIN; SELECT ... FOR UPDATE;` (holds the lock)
2. Session B: `FOR UPDATE SKIP LOCKED` → **gets NULL** (lock is real, correctly skipped)
3. Session A is **crashed mid-transaction** (`pg_terminate_backend`)
4. Session B retries → **immediately claims the row**

Row locks are **transaction-scoped** and released when the transaction ends or
the backend dies. A crashed worker's lock does **not** hide a row forever.

> **Correction to the original mental model.** The claim that "`SKIP LOCKED`
> hides a dead worker's row forever, therefore you need a lease" is **false**.
> The lease is still mandatory, but for a *different and correct* reason:
> **the claim COMMITS, then the worker spends minutes doing external work** (SSH
> clone, build, health check). A crash *after* commit leaves durable in-flight
> state with **no lock and nobody to reclaim it**. The lease recovers
> **committed-but-abandoned** claims; `FOR UPDATE SKIP LOCKED` prevents
> **concurrent** claims. Two orthogonal problems. Keep both.

### 1.3 The CTE trap ✅ (visible in query plans)

```sql
-- WRONG: locking clause is IGNORED for CTE references. No LockRows node.
WITH cte AS (SELECT id FROM deployments WHERE state='pending')
SELECT id FROM cte FOR UPDATE SKIP LOCKED;      -- plan: Seq Scan (no LockRows!)

-- RIGHT: put the lock INSIDE the CTE. LockRows appears.
WITH cte AS (SELECT id FROM deployments WHERE state='pending' FOR UPDATE SKIP LOCKED)
SELECT id FROM cte;                             -- plan: CTE Scan -> LockRows -> Seq Scan
```

The wrong form looks plausible and silently returns rows that are **not locked** —
a correctness bug, not a performance one. Always lock inside the CTE (or skip
the CTE and filter inline).

### 1.4 Claim query uses the partial index ✅

With 4,000 terminal rows + 6 claimable rows and the index
`ON deployments (coalesce(lease_expires_at,'-infinity')) WHERE state NOT IN (...)`,
the claim plan is:

```
Limit -> LockRows -> Index Scan using d_claimable on deployments
```

i.e. **O(queue depth)**, not O(history). Keep the `coalesce(lease_expires_at,
'-infinity')` expression-matching index so the index predicate is *identical* to
the query's.

### 1.5 Parameterized partial-index predicates: "always ignored" is TOO STRONG ⚠️

An earlier note claimed `WHERE status = $1` always bypasses a partial index.
Testing shows that is **not** always true: with a `PREPARE`d param on an ENUM,
Postgres 18 still chose `Index Scan using d_claimable`. The real rule is
narrower: the planner uses a partial index when it can *prove* the parameterized
predicate is a subset of the index predicate. **The inlined `NOT IN (...)` form
is provably safe — use it** and do not rely on the planner for a param.

### 1.6 Isolation level for the claim

`READ COMMITTED` is the target. Under `REPEATABLE READ` the claim is more prone
to `40001` serialization aborts on contention (clean skips become aborts). Use
`READ COMMITTED` and lean on its re-evaluation of the `WHERE` clause after a
lock wait. (Not empirically stress-tested here; treat as the documented guidance
to validate under real contention.)

### 1.7 Always write `STORED` explicitly

In PG ≤ 17 a generated column is `STORED` by default; in **18** bare
`GENERATED ALWAYS AS (...)` means **`VIRTUAL`**. Write `STORED` explicitly so the
schema is identical across versions.

### 1.8 Status column: `text` + CHECK over native ENUM (recommendation)

`ALTER TYPE ... ADD VALUE` cannot run in the same transaction that uses the new
value, and ENUMs are forward-only (no easy delete/rename). For a solo project
that will add states, a `text` column with a `CHECK (status IN (...))` constraint
is more evolvable. Either works; if ENUM is kept, all DDL adding values must be
its own migration. **Decision deferred to the build; prefer `text` + CHECK.**

---

## 2. systemd — verified from docs/issues

### 2.1 `.path` units do NOT fire on atomic symlink swap ⚠️ (broken through 256.8)

- systemd [#17727](https://github.com/systemd/systemd/issues/17727),
  [#31941](https://github.com/systemd/systemd/issues/31941): the
  `ln -s new tmp; mv -T tmp current` idiom replaces the symlink inode;
  inotify emits `ATTRIB` + `DELETE_SELF`, which `PathChanged=`/`PathModified=`
  do not catch.
- **Design consequence**: the deploy must **explicitly `systemctl restart`** the
  unit after the swap. Do **not** rely on a `.path` unit to auto-trigger.

### 2.2 Stable unit file, swap the symlink, then restart

- The unit references `/var/www/<app>/current/...` in `WorkingDirectory=` /
  `ExecStart=`. systemd resolves the path at exec time, so `restart` picks up the
  new symlink target.
- `daemon-reload` is required **only when the unit file changes**, NOT when the
  symlink target changes. Putting the unit file *inside* the release directory
  is the classic bug (deploy #2 breaks the paths).

### 2.3 `Type=` for a service that must be "up" only when serving

- `Type=simple`: active as soon as exec'd. `Type=notify`: active only after
  `sd_notify(READY=1)` — the right choice when "started" should mean "serving".
  `Type=notify-reload` needs systemd **253+**.

### 2.4 Reconciling via `systemctl show`

Read true host state with
`systemctl show <unit> -p ActiveState -p SubState -p Result -p ExecMainStatus -p NRestarts`
(`NRestarts` needs **235+**). `NRestarts` distinguishes a crash-looping service
from a healthy one — the deploy health check must not race with systemd restarts.

### 2.5 journalctl resumable logs + the cursor caveats ✅

- `--after-cursor=<c>` (v206+) resumes after a cursor; `--show-cursor` prints it;
  `--cursor-file=FILE` (v242+) is the "read, then persist last cursor" idiom.
- **Cursor format is "private and subject to change"** and is **scoped to a
  boot**. Empirically-documented split behaviour:
  - garbage cursor → rc=1 (fail-closed)
  - empty → rc=0 (fallback)
  - **wrong/unknown boot ID → rc=0, silent, fail-OPEN** ⚠️
  - `-b <unknown-boot>` fails closed
- **Consequence**: exit-status checking alone is insufficient. A client must
  compare the cursor's boot ID against `/proc/sys/kernel/random/boot_id` to
  detect a stale cursor and fall back to a full re-read.

### 2.6 Invoking a specific unit invocation's logs ⚠️ (arity trap)

- `journalctl -I <id>` is **broken**: short `-I` takes no argument (≡
  `--invocation=0`), so the id is treated as a positional match →
  `Failed to add match '<ID>': Invalid argument`.
- Portable fix: `journalctl _SYSTEMD_INVOCATION_ID=<id>` (works from **232+**) or
  `journalctl --invocation=<id>` (**257+**).

---

## 3. git — verified from docs

### 3.1 Fetching a specific commit SHA is NOT one reliable command ⚠️

- `git fetch --depth=1 origin <sha>` needs the server to advertise
  `allow-reachable-sha1-in-want` (i.e. `uploadpack.allowReachableSHA1InWant=true`
  server-side). GitHub.com **has** it; **GitHub Enterprise does not enable it by
  default** (bazel #12174). A single command is not portable.
- **Robust recipe** (reoclo/checkout): `git init` → `git remote add origin URL` →
  `git fetch --depth 1 origin <ref-or-sha>` → `git checkout --detach FETCH_HEAD`.
- **Shipyard must use a fallback ladder**, e.g.: (1) shallow fetch by SHA →
  (2) if it fails, `git clone --filter=blob:none` (or full) → `git fetch` the SHA
  → checkout. Never assume step 1 works.

---

## 4. Go SSH — from research (API-level; end-to-end SSH not run in sandbox)

- Dependency set is just `golang.org/x/crypto` (+ transitive `x/sys`).
- `Output` lives on `*Session`, not `*Client`.
- Non-PTY exec: `session.CombinedOutput` for small outputs, or
  `StdoutPipe`/`StderrPipe` + `io.Copy` to stream large logs to a file without
  unbounded memory. Exit code via `*ssh.ExitError.ExitStatus()`.
- **Detached remote job traps** (empirically found by the researcher, both fixed
  and tested):
  1. `exit` inside the script swallows the wrapper's exit-code write → run the
     script in a **subshell** `( script )`.
  2. A cancelled/killed wrapper writes no rc file → per-signal `trap` writing
     `128+signo`.
  3. **`SIGINT` cannot be trapped in a detached job** (POSIX makes async
     background jobs inherit `SIG_IGN` for INT/QUIT). Use **TERM** for cancel.
  4. `SIGKILL` is unreportable → the poller must also check `kill -0` for
     liveness, not just wait for the rc file. (Caveat: PID reuse on a long-lived
     host can read as a false "dead"; a job-unique token file beats bare PID.)

---

## 5. SSE / API — from research (verify library specifics before relying on them)

- SSE wire format (`event:`/`data:`/`id:`/`retry:`), headers
  `Content-Type: text/event-stream`, `Cache-Control: no-cache`,
  `X-Accel-Buffering: no`; flush via `http.Flusher` / `ResponseController`.
- Resumption: prefer an explicit `?after=<seq>` cursor (query param) in addition
  to / over `Last-Event-ID` — `Last-Event-ID` is only resent by the browser on
  *automatic* reconnect to the *same* URL, and `EventSource` cannot set headers.
- Backpressure: bound per-subscriber buffers; disconnect slow consumers.
- `bufio.Scanner` default 64 KiB token limit → `Scanner.Buffer()` for long lines.
- Keepalives: SSE comments (`: ping`) through idle proxies; respect nginx
  `proxy_read_timeout`.
- ETag/`If-None-Match`→304, `If-Match`→412 (stale update) vs 409, and
  `Idempotency-Key` (store key+fingerprint+response; replay stored response;
  409 on same key/different payload).
- **GOTCHA to respect later**: a Next.js Route Handler must auth-proxy the Go
  SSE stream (same-origin) because `EventSource` can't send an `Authorization`
  header.

---

## 6. Secrets — from research (code was built + 24 tests passing)

- AES-256-GCM: ciphertext layout is `nonce(12) || ciphertext || tag`; nonce must
  never repeat under the same key. Use `crypto/rand` for the nonce.
- AAD must be **case-sensitive**; if the env-var name column is `citext`, then
  `DATABASE_URL` vs `database_url` makes a valid ciphertext fail authentication
  (indistinguishable from corruption). Either drop `citext` on the name or
  normalize before AAD.
- Redactor wiring order: `session.Wait()` → `wg.Wait()` → `Flush()`; flushing
  before the copy goroutine finishes truncates the log tail.
- `env_fingerprint` = SHA-256 over sorted (name, value). For low-entropy secrets
  a plain hash is brute-forceable; HMAC with a key if that matters. For a solo
  project, sha256 of a secret is acceptable but HMAC is the hardened choice.
- Simplest defensible design for solo/self-hosted: AES-256-GCM in Postgres with
  the master key from an env var or `sops`/`age` file. Full KMS is overkill.

---

## 7. nginx — from research (official `ngx_http_proxy_module` citations)

- Fail-closed apply: write new config to a temp file **in the same directory**,
  `mv -T` it into place (atomic rename), `nginx -t`; only on success
  `systemctl reload nginx` (reload ≠ restart; reload keeps connections).
  A failed `nginx -t` leaves the running config untouched.
- `proxy_set_header` defaults: `Host $proxy_host`, `Connection close` — set
  `Host`/`X-Real-IP`/`X-Forwarded-For`/`X-Forwarded-Proto` explicitly.
- `proxy_pass` with a URI part rewrites paths; `proxy_read_timeout` default 60s;
  `proxy_buffering on` (relevant to the SSE `X-Accel-Buffering: no`).
- Static roots following the `current` symlink: verify nginx resolves the
  symlink at request time (not pinned at config load) on the target host —
  **flagged as needing target-host validation**.

---

## Corrections to the original mental model (docs/MENTAL-MODEL.md)

1. **§4 / decision D1+D2 rationale was wrong** (though the conclusion — lease,
   no queue table — is right). `SKIP LOCKED` does **not** hide a crashed
   worker's row forever; row locks release on transaction end. The lease
   recovers **committed-but-abandoned** work. See §1.2.
2. **`slot_busy` generated column IS legal** (DBA was right; an intermediate
   research claim that it was impossible was wrong). See §1.1.
3. Add the CTE locking trap to the write model — put `FOR UPDATE SKIP LOCKED`
   inside the CTE or filter inline, never outside a CTE reference. See §1.3.
4. Status column: prefer `text` + `CHECK` for evolvability (D-new). See §1.8.
5. git: fetching a specific SHA needs a fallback ladder, not one command (§3.1).
6. Deploy must explicitly `systemctl restart` after the swap; `.path` units are
   unreliable for symlink swaps (§2.1–2.2).
7. journalctl: stale/foreign-boot cursors fail **open**; compare boot_id (§2.5).
8. Secrets: env-name AAD is case-sensitive — watch for `citext` (§6).
