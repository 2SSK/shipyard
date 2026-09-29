# Shipyard — Build Roadmap (hand-written, line by line)

> **How to use this document.** Each phase has a *deliverable* you can run, a
> *test* that proves it, and a *done when* line. Do them in order. Do not start
> a phase until the previous one's test passes on a real machine.
>
> **Rule zero:** if you can't `run` it, you haven't built it. Every phase ends in
> something that executes on a real Linux box.
>
> Companion docs: `docs/MENTAL-MODEL.md` (why), `research_notes/…/VERIFIED.md`
> (proven facts). Trust VERIFIED.md over any recollection.

---

## The honest scope

You are building a **deployment control plane**: Next.js UI → Go control plane
→ Bash executor → Linux hosts (git, systemd, nginx, journalctl). You write every
line by hand. That means:

- **No Docker/K8s in the product** (Docker is only a lab to get a throwaway Linux
  host). The engine talks SSH to plain Linux.
- **Fewer dependencies.** The Go side needs `x/crypto` (SSH) and `pgx` (Postgres).
  The UI is Next.js. The executor is Bash. That's it.
- **The lab is the product.** A real, proven `deploy.sh` that clones, builds,
  swaps a symlink, restarts a unit, and health-checks is the hard part. The UI
  is a viewer over it.

Build bottom-up, from a real deploy, because the hardest correctness risks are
in the Linux/git/systemd primitives — and those are all in Phase 1–2, before any
Go or Postgres code exists.

---

# Phase 0 — Toolchain & a throwaway Linux host

**Goal:** a real Linux box you can SSH into and break, plus a Postgres you own.

**Why first:** every later phase deploys *to a host*. You need one, and you need
`systemd` + `sudo` on it. This is where the "production-grade" tests will run.

## 0.1 Get a target host (pick one)

- **Docker** (fastest, disposable, recommended to start):
  ```bash
  docker run -d --name shipyard-target --hostname target \
    --privileged --cap-add SYS_ADMIN \
    -p 2222:22 -v shipyard-data:/var/www \
    ubuntu:24.04
  ```
  then install `systemd`, `openssh-server`, `git`, `nginx` inside it.
  *(Containers are the lab only — the deploy engine itself is host-agnostic SSH.)*
- **A VPS** (Hetzner/DigitalOcean/Linode free tier) — most realistic.
- **Your own Linux box** — fine for a laptop, but systemd behavior differs.

> **Note:** systemd inside Docker needs care (`--privileged` + cgroup mount, or
> use an image that boots systemd, e.g. `jrei/systemd-ubuntu`). If that's
> fighting you, use a VPS — the whole point is real systemd.

## 0.2 Toolchain (install once)

- **Go** 1.22+ (`go version`)
- **PostgreSQL** 15+ locally (`psql --version`) — or use Docker for DB
- **Node** 20+ / npm
- **git**, **openssh-client**, a code editor
- An SSH keypair you can use for the target

## 0.3 Success test

```bash
ssh -p 2222 root@localhost 'systemctl --version && git --version && nginx -v'
```
Prints versions. **You can SSH in and run systemd commands.** That's the gate.

**Done when:** you have a reachable Linux host with systemd, git, nginx, and a
`ssh` alias (put it in `~/.ssh/config` as `Host target`).

---

# Phase 1 — The Lab: one deploy, by hand, on the target

**Goal:** a single Bash script that takes a commit SHA and makes it *live*,
correctly, on the target host. No Go, no Postgres, no UI. Pure Linux.

This phase is the moat. Everything else is a viewer. Spend real time here.

## 1.1 The release layout (create once on the target)

```bash
APP=myapp
sudo mkdir -p /var/www/$APP/{releases,shared}
sudo chown -R deploy:deploy /var/www/$APP   # a non-root 'deploy' user
```

```
/var/www/myapp/
  releases/
    1712345678/        # one dir per deploy (name = <epoch>-<sha7>)
      .shipyard-ready  # marker: built + health-checked
  shared/
    .env               # secrets, 0600, lives OUTSIDE any release
  current -> releases/1712345678   # the atomic pointer systemd/nginx follow
```

**Key invariants to internalize:**
- `current` is a **symlink**, swapped atomically (never `rm`+`ln`).
- `.env` lives in `shared/`, **never** in a release dir (releases are disposable).
- A release dir is only linked to `current` after it contains `.shipyard-ready`.

## 1.2 The atomic symlink swap (the heart of the whole system)

You already have a draft at `docs/swap_link.sh`. Verify and adopt it:

```bash
ln -s "releases/$NEW" /var/www/myapp/.current.tmp
mv -Tf /var/www/myapp/.current.tmp /var/www/myapp/current
```

**Why this is correct** (teach this to yourself — it's the most important 5 lines
in the project):
- `ln -s` creates the new link under a **temp name**, leaving `current` intact.
- `mv -T` (rename) **atomically replaces** the `current` symlink in one syscall.
- A reader doing `readlink current` sees *either* the old or the new target,
  *never* a missing link. No window where `current` points nowhere.
- `mv -T` is required so it renames the **symlink itself** and doesn't move
  *into* a directory named `current`.

**Test it:** run a loop that reads `readlink current` 10,000 times in a tight
shell loop while you swap 100 times in another. You must **never** see an error
or a broken link.

## 1.3 The systemd unit (stable file, points at `current`)

Create **once** (`/etc/systemd/system/myapp.service`):

```ini
[Unit]
Description=myapp
After=network.target

[Service]
Type=notify                 # "started" == "actually serving" (needs sd_notify)
User=deploy
WorkingDirectory=/var/www/myapp/current
ExecStart=/var/www/myapp/current/bin/server
EnvironmentFile=-/var/www/myapp/shared/.env
Restart=always
RestartSec=2
KillSignal=SIGTERM          # drain in-flight requests on stop
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable myapp
```

**Critical understanding (VERIFIED):**
- The unit references `current/`, so it **never changes**. A deploy does **not**
  rewrite the unit or run `daemon-reload` — it swaps the symlink and runs
  `systemctl restart myapp`. systemd resolves `ExecStart` at exec time, so the
  restart picks up the new symlink target.
- **Never** put the unit file inside `releases/` — deploy #2 breaks its paths.
- `.path` units do **not** fire on atomic symlink swap (VERIFIED, systemd
  #17727/#31941). The deploy must **explicitly restart**.

## 1.4 The deploy script (the golden path)

Write `deploy.sh`, run it **on the target** by SSH. It takes a SHA:

```bash
#!/usr/bin/env bash
set -euo pipefail            # -e exit on error, -u unset var is error, pipefail
umask 022
APP=myapp
SHA="$1"                     # full commit sha
ROOT=/var/www/$APP
REL="$ROOT/releases/$(date +%s)-${SHA:0:7}"
LOG=/var/log/shipyard-deploy.log

# 1. CLONE the exact commit
git clone --depth 1 --branch "$SHA" https://github.com/you/repo.git "$REL"
#    (or: git init "$REL" && cd "$REL" && git remote add origin URL &&
#     git fetch --depth 1 origin "$SHA" && git checkout --detach FETCH_HEAD)
#    NOTE: fetching a bare SHA may need server support; see VERIFIED.md §3.1

# 2. BUILD
cd "$REL"
./build.sh                   # your app's build

# 3. LINK shared resources (secrets stay in shared/)
ln -sf "$ROOT/shared/.env" "$REL/.env"

# 4. HEALTH CHECK the new release BEFORE exposing it
curl -fsS http://127.0.0.1:PORT/healthz || { echo "health failed"; exit 1; }

# 5. MARK READY, then atomically swap
touch "$REL/.shipyard-ready"
ln -s "releases/$(basename "$REL")" "$ROOT/.current.tmp"
mv -Tf "$ROOT/.current.tmp" "$ROOT/current"

# 6. RESTART the service (NOT a .path unit — explicit)
sudo systemctl restart myapp

# 7. Verify
sleep 2
systemctl is-active --quiet myapp || { echo "service not active"; exit 1; }
echo "deployed $SHA as $(basename "$REL")"
```

Run it against a real git repo **twice** and confirm: the second deploy replaces
`current`, the service restarts onto the new release, and both deploys are
reproducible (same SHA → same release contents).

## 1.5 The rollback (must exist before the UI does)

Rollback = re-point `current` at the previous release and restart. Literally the
same steps 5–6 with the *old* release name. Prove it: deploy, break something,
roll back, verify you're healthy. **This is a Phase-1 gate, not a Phase-6 feature.**

## 1.6 Success test (all must pass)

- [ ] `deploy.sh <sha>` deploys a real commit, live, on the target.
- [ ] The symlink-swap race test (1.2) shows zero broken reads.
- [ ] `systemctl restart` (not daemon-reload) picks up the new release.
- [ ] Rollback to the previous SHA restores health.
- [ ] A **failed** build or health check leaves `current` on the *old* release
      (fail-closed — this is the whole point of `.shipyard-ready`).

**Done when:** you can deploy and roll back a real app to a real server, by
hand, reliably. This is the foundation. Do not proceed until it's solid.

---

# Phase 2 — The Go control plane: ledger, state machine, claim/lease

**Goal:** wrap the lab deploy in a Go program that (a) records intent in
Postgres, (b) claims work safely across crashes, (c) drives `deploy.sh` over SSH,
(d) streams logs.

This is the heart of the "production-grade" story. Build it before any API/UI.

## 2.1 The schema (from `docs/data-architecture.md`, corrected per VERIFIED.md)

Write `db/migrations/0001_init.sql`. Minimum viable schema (add env/secrets later):

- `servers`, `projects` (id, name).
- `deployments`: `id`, `project_id`, `server_id`, `commit_sha`, `state` (text +
  CHECK), `state_seq`, `lease_owner`, `lease_expires_at`, `lease_generation`,
  `abort_requested_at`, timestamps.
  - `slot_busy` as a `STORED` generated column over the non-terminal states.
  - `UNIQUE (project_id, server_id) WHERE slot_busy` (VERIFIED: enforced).
  - `is_active` (host-observed "this is live"), separate from `slot_busy`.
- `deployment_events`: append-only audit spine (`deployment_id`, `seq`, `type`,
  `from_state`, `to_state`, `worker_id`, `message`, `created_at`).

**Test the schema against a real PG before building Go on it** (this is where I
found the gotchas — you should too):
```sql
-- insert two in-flight to same slot → expect `duplicate key ... slot_busy`
-- claim query → confirm EXPLAIN shows "Index Scan" (not Seq Scan)
```

## 2.2 The Go module + SSH transport

- `go mod init shipyard`; add `golang.org/x/crypto/ssh`, `jackc/pgx/v5`.
- **`internal/sshx`**: dial a host by key with `known_hosts` verification, open a
  non-PTY session, run `deploy.sh <sha>`, stream combined output to a local log
  file, return the exit code. (VERIFIED notes: `Output` is on `*Session`;
  `*ssh.ExitError.ExitStatus()`; use a dedicated `deploy` user with
  passwordless `sudo` for just `systemctl restart myapp` via a sudoers drop-in.)
- **Detached remote job** (if you want the deploy to survive an SSH drop): run
  `( deploy.sh ... )` in a **subshell** on the remote, `nohup`/`setsid`, write an
  exit-code file, and poll for it. (VERIFIED: `exit` in a script swallows the rc
  write unless in a subshell; `SIGINT` can't be trapped in a detached job — use
  `TERM`; also poll `kill -0` for liveness since `SIGKILL` writes no rc.)

## 2.3 The state machine + write model

- `internal/deploy/state.go`: the 9-state enum + a pure function
  `Next(state) → state` allowed transitions, and `IsTerminal(state)`.
- **Every transition** is: a fenced CAS write to `deployments.state` **and** an
  `INSERT` into `deployment_events`, in **one transaction**. The
  `deployments.state` column is a cache; the events table is the authority.
  ```sql
  UPDATE deployments SET state=$new, state_seq=state_seq+1
   WHERE id=$id AND state_seq=$prev AND lease_owner=$worker;
  INSERT INTO deployment_events (...) VALUES (...);
  ```

## 2.4 Claim / lease (the crash-safety core)

- **Claim** (must match the partial index; lock INSIDE the CTE — VERIFIED):
  ```sql
  WITH cte AS (
    SELECT id FROM deployments
     WHERE state NOT IN ('running','failed','canceled')
       AND (lease_expires_at IS NULL OR lease_expires_at < now())
     ORDER BY coalesce(lease_expires_at,'-infinity')
     FOR UPDATE SKIP LOCKED LIMIT 1)
  UPDATE deployments SET lease_owner=$w, lease_expires_at=now()+ttl,
                        lease_generation=lease_generation+1
    FROM cte WHERE deployments.id=cte.id
  RETURNING deployments.*;
  ```
- **Renew** the lease on a heartbeat; **fence** writes on `lease_generation`.
- A **reconciler** goroutine: every 15s, find non-terminal rows with a dead
  lease, inspect the *host* (release dir? unit active?), and resume/fail/cancel.

**Why both SKIP LOCKED and the lease (VERIFIED — this corrected the design):**
row locks do **not** survive a crashed worker (they release on txn end), so
SKIP LOCKED only prevents *concurrent* claims. The lease recovers
*committed-but-abandoned* work — the worker that claimed, committed, then died
minutes later mid-SSH. Both are needed; they solve different problems.

**Test:** in a psql harness, (a) two workers never claim the same row; (b) kill
a worker *after* it commits a claim → within TTL the reconciler reclaims it;
(c) a stale worker's fenced write is rejected.

## 2.5 Log streaming to a file + a `LogSink` interface

- `internal/logsink`: `interface { Write(line); Close() }`, first impl = local
  file (append build output as it streams from SSH). Later: S3.
  - Cap size (head+tail, `truncated` flag); store path/bytes/`sha256` in DB.
  - Keep last ~100 lines in DB at terminal time so the UI needs no file I/O.

**Done when:** a Go program, pointed at your Phase-1 target, can deploy a SHA by
itself, survives being killed mid-deploy (reconciler converges), and writes a
log file. This is the single most important milestone.

---

# Phase 3 — The API (`/v1`)

**Goal:** expose the control plane over HTTP so anything (curl, a script, the
UI) can trigger and observe deploys.

## 3.1 The endpoints (from the API design)

- `POST /v1/deployments` → `201 {id, state:"pending"}` immediately (async work).
  - `Idempotency-Key` supported; same key+payload replays the same response.
- `GET /v1/deployments` — list, cursor-paginated (`?after=<cursor>`), never a
  real timestamp in the page token.
- `GET /v1/deployments/{id}` — full state; strong `ETag` (hash of
  `state+state_seq`); `If-None-Match` → `304`.
- `GET /v1/deployments/{id}/events` — the audit timeline.
- `GET /v1/deployments/{id}/logs` — **SSE stream** of build output.
  - `?after=<seq>` cursor for resume; keepalives (`: ping`) through proxies.
  - `Content-Type: text/event-stream`, `X-Accel-Buffering: no`, flush per line.
- `POST /v1/deployments/{id}/rollback` → redeploys a prior SHA.
- `POST /v1/deployments/{id}/cancel` → sets `abort_requested_at`.
- Errors: uniform `{error:{code,message,details}}`; `409 {reason:"deploy_in_flight"}`
  from the `slot_busy` unique violation.

## 3.2 Auth (MVP)

A single admin bearer token from an env var, checked in middleware. The boundary
matters more than the scheme; do not over-build it.

**Test:** `curl` a deploy end-to-end; `kill -9` the API mid-deploy; confirm the
reconciler converges and the stream reports a real terminal state.

**Done when:** you can deploy via `curl` and watch it live in `curl -N`.

---

# Phase 4 — The UI (Next.js)

**Goal:** a deploy dashboard. Read-model only; all mutations go through the API.

- **Stack:** Next.js (App Router) + TypeScript. Server Components fetch state;
  a **client component** owns the `EventSource` for live logs (Server Components
  can't use `EventSource`). A Next.js **Route Handler proxies** the Go SSE
  stream same-origin (so it can attach the auth header `EventSource` can't set).
- **Screens:**
  - Fleet: servers + what's active on each (reconcile `is_active`).
  - Project: deploy list (state, sha7, time, who/what triggered).
  - Deploy detail: state timeline (from `events`), live build log (SSE), runtime
    log (`journalctl` — separate!), release link (`current` symlink target),
    rollback button.
- **Design thesis** (from the UI design): a dense, honest infrastructure console.
  Show the three status axes distinctly. Show the SHA, the unit, the paths. A
  failed deploy must tell you *what* broke and *where* in seconds — that's the
  whole value prop.

**Test:** trigger a failing deploy in one tab, watch the state + log update live
in another, click rollback, see it go healthy.

**Done when:** a non-expert can watch a deploy and roll it back from the browser.

---

# Phase 5 — Hardening (make it honest "production-grade")

Each item has a **test** (from the SRE definition of production-grade):

1. **Terminality** — kill the DB, kill the engine, let TTLs expire, restart →
   no run is stuck non-terminal. *Test: `docker kill` things mid-deploy.*
2. **Write-ahead** — power-loss mid-`mv` → reconciler converges (the `.tmp` symlink
   is orphaned but harmless; `current` is never broken).
3. **Convergence** — a crashed `building` step resumes by *inspecting the host*,
   not blind-retrying.
4. **Fail-closed config** — generate nginx config → write via temp+mv → `nginx -t`
   → only `systemctl reload` on success. *Test: a bad config never takes effect.*
5. **Reversibility** — every deployment rolls back to any prior SHA.
6. **Reproducibility** — same SHA deploys to a byte-identical release.

Also in this phase (each verified in VERIFIED.md):
- Secrets: AES-256-GCM in Postgres, key from env/`sops`. Watch the AAD
  case-sensitivity gotcha. `.env` written `0600` into `shared/`, never a release.
- Multi-service per project; `services.unit_name` stored, not computed.
- Env revisions (which revision a deploy used; `env_fingerprint` for drift).
- nginx: `proxy_set_header` explicitly; `/healthz`; static root follows `current`.

**Done when:** all six tests pass on a real host, including a hard `kill -9`
mid-build with no human intervention.

---

# The build order, one line

```
Phase 0  toolchain + a real Linux host you can SSH
Phase 1  deploy.sh by hand (clone→build→swap→restart→health→rollback)  ← the moat
Phase 2  Go: schema + claim/lease + SSH driver + state machine           ← crash-safety
Phase 3  API: /v1 REST + SSE logs
Phase 4  UI: deploy dashboard
Phase 5  hardening: the six production-grade tests + secrets + nginx
```

**If you only do one phase**, do Phase 1. It is the product; the rest is a
control panel and a ledger over a deploy that actually works.
