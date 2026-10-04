# Shipyard Roadmap — Learning by Building

**Owner:** sskbtw
**Status:** v1 — living document
**Canonical roles:** this file is authoritative for **what to build next**. `docs/MENTAL-MODEL.md` wins on architecture. `docs/PRD.md` wins on product intent. `reference/Shipyard build primitives/VERIFIED.md` wins on empirical fact.

> **How to use this.** Each phase has **Goal** (what "done" looks like), **Why it matters** (the lesson), **Steps** (ordered, each with a concrete acceptance check), and **Deliverable** (what you commit).
>
> Work sequentially. Commit after every step. If an acceptance check fails twice, stop and ask — that's the learning moment.

---

## Phase 0 — Lab Fleet (M0)

**Goal:** Three systemd containers (`shipyard-01/02/03`) reachable over SSH on ports 2201/2202/2203.
**Why it matters:** "The machine is the point." If SSH doesn't work, nothing downstream is real.

> **Status: done.** `make lab-up` ends with `Lab read.` — three hosts reachable, each
> verified as a usable Linux deployment target (systemd readable unprivileged,
> nginx active, `/health` answering, `/var/www` writable, sudo allowlist live).
> `make lab-check` is the acceptance test and it fails loudly, which is the part
> that matters.

### Steps

**0.1 Write `infra/lab/Dockerfile`**
- Base `ubuntu:24.04`. Install `systemd`, `systemd-sysv`, `openssh-server`, `nginx`, `git`, `dbus`.
- PID 1 must be systemd: `CMD ["/sbin/init"]`, `STOPSIGNAL SIGRTMIN+3`.
- Create a dedicated unprivileged **`deploy`** user with `sudo` rights limited to the systemd/nginx commands the phases need.
- **Ship `dbus`.** Without it `/run/systemd/private` is root-only and unprivileged `systemctl` over SSH fails with `Failed to connect to bus`. A real VPS does not do that, and the engine will read host state unprivileged.
- Keep config in real files (`sshd-lab.conf`, `sudoers-deploy`, `entrypoint.sh`), not Dockerfile heredocs — they can be read, diffed and linted on their own. Validate the sudoers file with `visudo -c` at build time.
- Acceptance: `docker build` succeeds; `docker history` shows `git` present.

**0.2 Write `infra/lab/compose.yaml`**
- Three services. Ports `2201/2202/2203` → 22, `8081/8082/8083` → 80. Named volume per server for `/var/www`, `/var/log/shipyard` and `/etc/ssh/hostkeys`.
- Required for systemd: `privileged: true`, `cgroup: host`, `tmpfs: [/run, /run/lock]`.
- Two one-shot init containers bracket the fleet: `keys` must complete before any host starts, `known-hosts` after all hosts are healthy.
- Set `hostname:` per service to the container name. Without it `hostname` returns a container ID and the acceptance test in 0.7 cannot prove `2201 → shipyard-01`.
- Acceptance: `make lab-up` starts all three, captures host keys, and ends with `Lab read.`

**0.3 Verify systemd is PID 1**
```bash
docker exec shipyard-01 systemctl is-system-running   # expect: running
docker exec shipyard-01 systemctl is-active ssh.socket # expect: active
docker exec shipyard-01 nginx -v
```
- Acceptance: `running` / `active` on **all three**.
- **Probe `ssh.socket`, not `ssh`.** Ubuntu 24.04 activates sshd by socket and starts `ssh.service` per connection, so `ssh.service` is inactive by design and never becomes active while you poll. Probing it marks every host permanently unhealthy.

**0.4 Give each host its own identity**
- `rm -f /etc/ssh/ssh_host_*_key*` in the image, then `entrypoint.sh` generates an ed25519 host key on first boot into the `/etc/ssh/hostkeys` volume.
- An image that ships host keys hands its private keys to anyone who pulls it *and* makes every host built from it indistinguishable. Bake none.
- Acceptance: three distinct host key fingerprints. Volume-backed, so `down` keeps them and only `down -v` rotates.

**0.5 Bootstrap the login keypair (`Dockerfile.init` + `init.sh keys`)**
- Generate `infra/lab/keys/lab_key` on the host, reused if already present, `chmod 600`, and owned by the host user so `ssh -i` works.
- sshd reads it via `AuthorizedKeysCommand /usr/bin/cat /keys/lab_key.pub` with `AuthorizedKeysCommandUser nobody` — no `authorized_keys`, so there are no `~/.ssh` permission rules to get wrong.
- Acceptance: `ssh -i infra/lab/keys/lab_key -p 2201 deploy@127.0.0.1 'id'` succeeds with no password, with no `~/.ssh` present at all.

**0.6 Capture the known host keys (`init.sh known-hosts`)**
- Runs after all three report healthy. Writes `infra/lab/keys/known_hosts`, keyed by `[127.0.0.1]:220N` so it matches the address the engine dials. Key on the literal address, **not** `localhost` — OpenSSH matches host keys on the string it was handed, so the two would be separate entries, and `localhost` resolves through `/etc/hosts` (`::1` first on some images), which the loopback-only port binding does not serve.
- Must write atomically and **refuse to write a capture that collapsed to one identity** — that means the fleet is sharing a host key and known_hosts has quietly stopped verifying anything.
- Acceptance: three distinct entries, one per port.

**0.7 `init.sh check` — the acceptance test as code**
- Asserts key presence, `0600`, three distinct identities, and that what `known_hosts` claims is what each host presents *right now*.
- **Then prove the real invariant end to end.** Everything after the keyscan must be observed *through* an SSH session as `deploy` — one connection per host, `StrictHostKeyChecking=yes`, `BatchMode=yes` — so a pass proves authentication + host identity + network reachability **together**, which is the only thing the engine actually relies on. Asserting that three files contain three strings is not an acceptance test for a deployment target.
- The per-host assertions: the port resolves to the right host (`2201 → shipyard-01`, so a swapped mapping cannot pass), the login user is `deploy`, `systemctl is-system-running` is readable **unprivileged** (the reconciler will read host state that way), nginx is active, `curl -fsS http://localhost/health` answers, `/var/www` is writable by `deploy`, and `sudo -n systemctl show` succeeds against the shipped allowlist.
- Must exit non-zero when a host key has rotated underneath a stale file, and a real SSH connection must then fail. A check that only passes is not a check.
- Acceptance: passes after `up`; fails after discarding one host-key volume; fails if any host is down, reporting *which*; passes again after re-running `known-hosts`.

**0.8 One command per operation (`Makefile`)**
- `lab-up` · `lab-check` · `lab-down` · `lab-reset` · `lab-rotate-key`. The contributor interface is the deliverable, not the compose file.
- `lab-check` passes `--no-deps`: a check must report the lab as it finds it, never quietly start the fleet it was asked to verify. Both lab targets pass `--build`, because `init.sh` is baked into the init image and a stale one would silently assert last week's behaviour.
- Acceptance: `make lab-up` on a clean checkout prints `Lab read.`; `make lab-check` after `make lab-down` exits non-zero.

**0.9 Publish the lab on loopback only**
- `127.0.0.1:2201:22`, not `2201:22`. Unqualified publication puts a live `sshd` on every interface, including the office LAN.
- Acceptance: `ss -ltn` shows `127.0.0.1:2201`; nothing answers on the host's routable address.

**0.10 Write the server seed**
- Seed into Postgres in Phase 1, not a JSON file in `reference/`. `reference/` holds *documentation of facts*, not runtime configuration — the `servers` table is the single source of truth for connection details.
- Acceptance: deferred to Phase 1.4.

### Deliverable
- `infra/lab/` contains `Dockerfile`, `Dockerfile.init`, `compose.yaml`, `entrypoint.sh`, `init.sh`, `sshd-lab.conf`, `sudoers-deploy`.
- `Makefile` with the five `lab-*` targets.
- 30-second recording: `make lab-check` → `Lab read.`, then `ssh -p 2201` → `systemctl status ssh.socket` on all three.

> **Nothing generated is committed.** `infra/lab/keys/` holds the login keypair and `known_hosts`, both derived state, ignored by `infra/lab/keys/.gitignore`. Regenerate with `make lab-up`; rotate with `make lab-rotate-key`. Committing private keys is a habit worth never forming.

> **The `deploy` sudoers file is not a security boundary, and does not pretend to be.** `deploy` has group write on `/etc/systemd/system`, so it can add a unit and then start it as root — unavoidable for this workflow, fine on a disposable lab host, and not a pattern to copy onto a shared or production host. D13 in `docs/MENTAL-MODEL.md` §5 is the shape that replaces it; step 3.5 does the replacing.

---

## Phase 1 — Ledger (M1)

**Goal:** Schema migrated; claim, CAS transition, and event append covered by integration tests against real Postgres.
**Why it matters:** This is the write-ahead intent ledger. If the ledger is wrong, everything is wrong.

### Steps

> All steps in Phases 1–5 follow the house conventions in `docs/MENTAL-MODEL.md` §5.1.

**1.1 Create `.env` / `.env.example` and the `postgres` service**
- Every port, image tag, and credential interpolated from `.env`. Pin `postgres:18.6`.
- `healthcheck: pg_isready`, `logging: driver local` with `max-size`/`max-file`, named `networks` and `volumes`.
- Acceptance: `psql` connects; `docker compose ps` shows `healthy`.

**1.2 Write `db/migrations/001_initial.sql`** — exactly PRD §10.
- Acceptance: applied cleanly; `\d deployments` shows `slot_busy` as `GENERATED ALWAYS AS (…) STORED`.

**1.3 Verify `slot_busy` is immutable**
- Insert with `state='building'` → `slot_busy` must be `true`.
- Update to `state='running'` → must become `false`.
- Acceptance: `slot_busy` always equals the `state IN (…)` predicate.

**1.4 Write the claim query** — PRD §10.1.
- `FOR UPDATE SKIP LOCKED` **inside** the CTE.
- Test: two concurrent claims against one row → exactly one succeeds.
- Acceptance: `EXPLAIN` shows a `LockRows` node. Without it the lock is not being taken at all.

**1.5 Write the CAS transition** — PRD §10.2.
- Test: stale `lease_generation` → **zero rows**.
- Acceptance: test asserts "zero rows = another actor won, abort".

**1.6 Append-only events** — 3 events with increasing `seq`.
- Acceptance: ordered read returns them in `seq` order.

**1.7 Seed the three lab servers** into `servers`.
- Acceptance: `SELECT * FROM servers` returns three rows using the real lab values from 0.5/0.6.

**1.8 Set up the build contract**
- `internal/database/` with `//go:embed migrations/*.sql`, applied in filename order at boot.
- `Makefile` targets mirroring CI: `fmt-check`, `vet`, `build`, `test`, `integration`, `check`.
- Integration tests carry `//go:build integration` and run via `go test -tags integration ./internal/...` against the real Postgres.
- Acceptance: `make check` passes; `make integration` runs green.

### Deliverable
- `db/migrations/001_initial.sql`, `internal/database/` with embedded runner
- `internal/deployment/claim_test.go`, `internal/deployment/transition_test.go` (`//go:build integration`)
- `Makefile` + README section: *"Ledger — how we prevent double-execution"*

---

## Phase 2 — SSH Execution (M2)

**Goal:** Engine runs a script remotely, streaming output and capturing the exit code.
**Why it matters:** "Go never mutates a host" made concrete — Go only runs scripts and reads exit codes.

### Steps

**2.1 Add `golang.org/x/crypto/ssh`**
- Acceptance: in `go.mod`.

**2.2 Implement `SSHClient` with host key verification**
- Take a `Target` exactly as specified in `docs/MENTAL-MODEL.md` §2.1 — do not re-derive the shape from the `servers` row, and do not let a dial helper accept a bare `host:port` string, or the address literal stops being the thing that is pinned.
- `ssh.PublicKeys(signer)` for authentication.
- `HostKeyCallback` is `knownhosts.New(<Target.KnownHosts>)`. Non-default ports appear as `[127.0.0.1]:2201` — the brackets are part of the key, and `127.0.0.1` is a different entry from `localhost` (§2.1).
- Acceptance: connects to `shipyard-01`.
- **Do not use `ssh.InsecureIgnoreHostKey()`.** A deployment platform that accepts any host key is trivially MITM-able, and a reviewer will find it. Verify from step one — the cost is one file read.
- **Distinguish "not enrolled" from "presented a different key".** `errors.As` for `*knownhosts.KeyError`; an empty `Want` is an enrollment gap, a non-empty one is a rebuilt or compromised host and deserves a very different operator response. The classification helper is written out in `reference/Shipyard build primitives/secrets-and-key-management.md` §8.2.

**2.3 Run a remote command**
- `session.CombinedOutput("uname -a")`.
- Acceptance: output captured, exit code 0.

**2.4 Stream output in real time**
- Pipe `session.Stdout`/`Stderr` into an `io.Writer` as bytes arrive. Use `io.MultiWriter` when the same bytes must both reach the terminal and be captured for `deployment_events`.
- Acceptance: `sleep 5 && echo done` shows `done` after 5 s, not at exit.

**2.5 Non-zero exit returns an error with output attached**
- Acceptance: `bash -c 'exit 3'` errors, and the error carries the output.

### Deliverable
- `internal/exec/client.go` — connect, run, stream, close (context-first, `*slog.Logger` injected)
- `cmd/shipyard/ssh-demo/main.go` — loads config, connects, runs `uname -a`
- 15-second recording: `go run ./cmd/shipyard/ssh-demo` → remote output

---

## Phase 3 — Deploy Pipeline (M3)

**Goal:** A real deploy lands on a lab container; every phase visible.
**Why it matters:** The thesis becomes real.

### Steps

**3.1 Seed a `projects` row** — name, `repo_url`, `build_cmd`, `health_path`, `release_root`, `unit_name`.

**3.2 Resolve the ref to an immutable SHA**
- Resolve `branch | tag | commit` → a 40-char SHA **before** touching the host, and store it in `deployments.commit_sha`.
- Acceptance: the recorded SHA is 40 hex chars and does not change for the life of the deployment.
- **Why this step exists:** a branch tip is a moving target. Deploying "whatever `main` was when the clone happened" means the ledger recorded one intent and the host received another. The whole crash-recovery story depends on knowing exactly which commit reality is supposed to match.

**3.3 Record intent** — `POST /api/v1/projects/{id}/deployments` returns `201 {state:"pending"}` and performs no host work.

**3.4 Claim** — claim query → `state='cloning'`, `lease_owner` set, `lease_generation` bumped.
- Acceptance: `slot_busy=true`.

**3.5 Replace the lab's privilege shortcut with the `shipyard-apply` helper**
- Remove `deploy`'s group write on `/etc/systemd/system` and the nginx site dirs from `infra/lab/Dockerfile`; both become root-owned again.
- Ship one root-owned, no-argument-list helper (D13). `deploy` may `sudo` exactly it. Its whole job is the privileged half of a deploy, in order: take the candidate unit and site config from a `deploy`-writable staging directory → `systemd-analyze verify` and `nginx -t` → **abort on either failure** → install root-owned into `/etc/systemd/system` and the nginx site dir → `daemon-reload` → `systemctl restart`.
- This is the fail-closed property (§8.4) with a place to live. It is also why the sudoers file becomes a real boundary: one root command, one argument, validated inside.
- **This is the step where the lab stops teaching the wrong lesson.** Until it exists, `configure.sh` may write unit files directly — the lab's group-write shortcut is a deliberate Phase 0 affordance, not the production shape.
- Acceptance: `configure.sh` still installs and restarts a unit; a deliberately broken unit is rejected with a non-zero exit and the running service is untouched; `deploy` can no longer write `/etc/systemd/system` (`test -w` fails).

**3.6 Write the phase scripts** in `deploy/phases/`
- `clone.sh` — `git clone` the repo, then `git checkout "$COMMIT_SHA"`. Use the shallow-fetch fallback ladder from `reference/…/git-and-fetch-fallback.md`; a bare `--depth=1` of a branch tip can omit the requested SHA entirely.
- `build.sh` — `cd "$RELEASE_DIR" && $BUILD_CMD`
- `configure.sh` — stage the systemd unit + nginx site config in the deploy-writable staging dir, then hand them to `shipyard-apply` from 3.5. Never write to `/etc` directly.
- `start.sh` — `systemctl restart $UNIT_NAME`. After 3.5 that is inside the helper, not a separate `sudo` line.
- `healthcheck.sh` — `curl -sf "http://localhost$HEALTH_PATH"`
- Acceptance: each exits 0 on success, non-zero on failure, and is safe to re-run.

**3.7 Use the release layout + symlink swap**
```
/var/www/<project>/releases/<sha>/     ← built here
/var/www/<project>/current -> releases/<sha>
```
- Swap atomically, then explicitly `systemctl restart`.
- Acceptance: `readlink /var/www/<project>/current` shows the new SHA; the previous release directory is untouched.

**3.8 Advance state via CAS only**
- Every transition uses `WHERE state_seq = $3 AND lease_generation = $4` from 1.5.
- Zero rows → abort immediately, do not retry the write.
- Acceptance: the deploy progresses `pending → cloning → building → configuring → starting → health_checking → running`, and a stale worker cannot corrupt it.

### Deliverable
- `internal/deployment/executor.go` — phase runner + event appender
- `deploy/phases/*.sh`
- 60-second recording of a full deploy progressing through all 9 states

---

## Phase 4 — UI + SSE (M4)

**Goal:** Live phase-by-phase view.
**Why it matters:** The "Viewer" persona's proof — a hiring manager sees the machine move.

Stack is fixed: Next.js 16 App Router · React 19 · Tailwind 4 · shadcn 4 (`@base-ui/react`) · TypeScript strict, in `web/`.

### Steps
- **4.1** Scaffold `web/` with the house stack and the shadcn primitives this UI needs: `card`, `badge`, `table`, `button`, `separator`, `tooltip`, `sheet`.
- **4.2** `web/lib/api.ts` — `apiFetch` wrapper throwing `ApiFetchError` that **preserves the upstream HTTP status**, so a `409 deploy_in_flight` survives the proxy.
- **4.3** `web/lib/types.ts` — mirror the Go deployment model.
- **4.4** `GET /api/v1/deployments` → table: `id | project | server | state | created_at`.
- **4.5** `web/app/dashboard/deployments/[id]/page.tsx` → state, `commit_sha`, `release_path`.
- **4.6** **SSE transport decision — resolve this first.** Next.js route handlers can buffer, which is fatal for a live stream. Preferred: a `rewrites()` proxy to the Go engine's `/events/stream`, which streams cleanly. Verify with a `curl -N` smoke test before building any UI on top of it.
- **4.7** `EventSource` client appends events as they arrive; heartbeat comments keep the connection alive; clean up on unmount.
- **4.8** Horizontal phase timeline; highlight advances as events arrive. Terminal states `failed` and `canceled` must render **distinctly**, not as a generic error.

### Deliverable
- `web/app/dashboard/deployments/[id]/page.tsx`
- Screen recording: timeline advancing, events streaming

---

## Phase 5 — Reconciler (M5)

**Goal:** A3, A4, A9 pass — crash recovery with no human intervention.
**Why it matters:** "Crash-safe by design" — the core differentiator.

### Steps
- **5.1** Detect abandoned work: non-terminal rows whose `lease_expires_at` is well past `now()`. Grace period configurable via `Config` (`--reconcile-grace`, default 5 m) against a 30 s lease.
- **5.2** Inspect the host over SSH: does the release dir exist? what does `systemctl is-active $UNIT_NAME` say? which SHA does `current` point at?
- **5.3** Phase-appropriate repair: `health_checking` + service active → re-run only the health check. `building` + release dir missing → restart from clone.
- **5.4** Write `is_active` + `active_verified_at` — the reconciler is the **only** writer of these.
- **5.5** Fault-injection suite: for each non-terminal state, start a deploy, `docker kill --signal=SIGKILL shipyard-engine`, restart, assert recovery.
- **5.6** **Put the engine in a container** so step 5.5 is deterministic. Killing a `go run` process by hunting PIDs is not a reproducible test.

### Deliverable
- `internal/reconcile/reconcile.go` (a goroutine in the single `cmd/shipyard` binary)
- Recording: kill mid-deploy, show self-heal

---

## Phase 6 — Portability Proof (M6)

**Goal:** A7 passes — a real VPS, zero engine code changes.
**Why it matters:** The portfolio thesis is only credible if it survives a non-Docker target.

### Steps
- **6.1** Provision any Linux VPS with SSH access. Install the lab public key.
- **6.2** Insert a `servers` row for it.
- **6.3** Deploy. Expect `running`.
- **6.4** README section: *"Deploying to a real VPS"* — exact commands, no engine changes.

### Deliverable
- README VPS instructions a peer can follow unattended
- Recording: same UI, different host

---

## Phase 7 — Polish & Portfolio

- **7.1** Case study (<1500 words): thesis, 3-plane diagram, crash-recovery demo.
- **7.2** Recordings: 60 s deploy, 30 s crash recovery, 30 s VPS deploy.
- **7.3** CI: `! grep -r 'github.com/docker/docker' cmd/ internal/` plus integration tests on PR.
- **7.4** Publish to `sskbtw.xyz`.

---

## Working rhythm

1. **One phase at a time.** Phase 1 tests pass before Phase 2 starts.
2. **Commit every step.** Small and atomic — you will thank yourself during debugging.
3. **Ask when blocked.** Two failed acceptance checks means stop and ask.
4. **Record as you go.** Every deliverable is a portfolio artifact. Don't defer them.

---

## Next action

**Phase 1, step 1.1** — add `.env` / `.env.example` and the `postgres` service. Pin `postgres:18.6`; every port, image tag and credential interpolated from `.env`. Acceptance: `psql` connects and `docker compose ps` shows `healthy`.
