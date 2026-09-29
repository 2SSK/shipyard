# Shipyard

A **deployment control plane**: Next.js UI → Go control plane → Bash executor →
Linux hosts (git, systemd, nginx, journald).

> **Shipyard is a write-ahead intent ledger plus a single serial Bash executor.**
> Postgres records what we *meant* to do. The target host's filesystem and
> systemd record what is *actually true*. Reconciliation is the self-healing gap
> between them. The UI, API, and state machine are read models over that gap.

**This repo is currently documentation only.** All code is written by hand, by
one person, guided step by step. There is no `db/`, no `internal/`, no
`cmd/` yet — and that is deliberate.

---

## Start here

| Document | What it is |
|---|---|
| **[`docs/ROADMAP.md`](docs/ROADMAP.md)** | **The build plan.** Six phases, each ending in something you can *run*. Authoritative order of work. |
| [`docs/MENTAL-MODEL.md`](docs/MENTAL-MODEL.md) | **Why.** The canonical design: the three status axes, the 12 adjudications that settled the arguments, the executor constraints. |
| [`reference/Shipyard build primitives/VERIFIED.md`](reference/Shipyard%20build%20primitives/VERIFIED.md) | **Proven facts.** Empirically tested on PostgreSQL 18.6 or confirmed against authoritative docs. Wins over recollection. |
| [`reference/README.md`](reference/README.md) | The research library, and why certain files were deleted. |

**Precedence:** `VERIFIED.md` > `MENTAL-MODEL.md` > `ROADMAP.md` > deep dives.
Where they disagree, the higher one wins.

---

## The build order

```
Phase 0  toolchain + a real Linux host you can SSH into
Phase 1  deploy.sh by hand: clone → build → swap → restart → health → rollback
Phase 2  Go engine: schema + claim/lease + state machine + SSH driver
Phase 3  /v1 REST + SSE log streaming
Phase 4  Next.js deploy dashboard
Phase 5  hardening: the six production-grade tests, secrets, nginx
```

**Phases 1 and 2 are load-bearing.** Do not start Phase 3 (API) or 4 (UI) until
Phase 2's `kill -9` → reconciler test passes. A control plane that cannot survive
its own crash is not production-grade; it is a demo with extra steps.

If you only ever do one phase, do **Phase 1**. It is the product. Everything else
is a control panel and a ledger over a deploy that actually works.

---

## The three status axes (the crux)

Orthogonal, and the single most common source of bugs. Do not merge them:

| Axis | Question | Source of truth |
|---|---|---|
| `state` + `state_seq` | What are we *trying* to do? | Postgres (intent) |
| `slot_busy` (derived) | Is a worker on it *right now*? | Generated column — never drifts |
| `is_active` + `active_verified_at` | Is it *live on the host*? | The target host (reality) |

---

## The lab

The target host is **this machine** — it already runs systemd 262 and nginx
1.30.5, and `sshd` is active. No Docker-based lab is used: containers need
`--privileged` and a cgroup dance, and they would teach container-systemd
quirks that real VMs do not have. The engine reaches the target over real SSH
to `localhost`, so the code works unchanged when later pointed at a VPS.

---

## Status

Pre-implementation. Phase 0 in progress.
