# Shipyard

A deployment control plane: **Next.js UI → Go control plane → Bash executor →
Linux hosts** (git, systemd, nginx, journalctl).

> **Shipyard is a write-ahead intent ledger plus a single serial Bash executor.**
> Postgres records what we *meant* to do. The target host's filesystem and
> systemd record what is *actually true*. Reconciliation is the self-healing gap
> between them. The UI, API, and state machine are read models over that gap.

---

## Start here

| Document | What it is |
|---|---|
| **[`docs/ROADMAP.md`](docs/ROADMAP.md)** | **The build plan.** Six phases, each ending in something you can *run*. This is the authoritative order of work. |
| [`docs/MENTAL-MODEL.md`](docs/MENTAL-MODEL.md) | **Why.** The canonical design and the 12 adjudications that settled the arguments. |
| [`research_notes/…/VERIFIED.md`](research_notes/Shipyard%20build%20primitives/VERIFIED.md) | **Proven facts.** Empirically tested on PostgreSQL 18.6 or confirmed against authoritative docs. Wins over recollection. |
| [`docs/data-architecture.md`](docs/data-architecture.md) | The schema spec (DB layer). |
| [`docs/backend-design.md`](docs/backend-design.md) | API and engine design (Go layer). |
| `research_notes/Shipyard build primitives/` | Five deep-dive research notes (SSH, Postgres, SSE, nginx/systemd, secrets). |

Rule of precedence: **`VERIFIED.md` > `MENTAL-MODEL.md` > `ROADMAP.md` > the raw
analyses in `docs/`.** Where they disagree, the higher one wins.

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

These are orthogonal and are the single most common source of bugs. Do not merge
them:

| Axis | Question | Source of truth |
|---|---|---|
| `state` + `state_seq` | What are we *trying* to do? | Postgres (intent) |
| `slot_busy` (derived) | Is a worker on it *right now*? | Generated column — never drifts |
| `is_active` + `active_verified_at` | Is it *live on the host*? | The target host (reality) |

---

## Status

Pre-implementation. The schema (`db/migrations/`) has **not** been written — the
draft that existed was analysed, rejected, and quarantined under
`db/migrations/_discarded/` with the reasons recorded.
