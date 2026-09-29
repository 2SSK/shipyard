# ⚠️ DISCARDED MIGRATION — DO NOT APPLY

This file is kept only as a record of a design that was analysed and rejected.
It is **not** the Shipyard schema. The real schema has not been written yet.

## Why it was discarded

This migration came from a third, independent design pass. It conflicts with
the adjudications in `docs/MENTAL-MODEL.md` §5:

| This file does | Canonical decision | Problem |
|---|---|---|
| `CREATE TYPE deployment_status AS ENUM` with `PENDING`/`BUILDING`/… | **D12** — use `text` + `CHECK` | `ALTER TYPE … ADD VALUE` cannot run in the same transaction that uses the new value; enums are forward-only and painful to evolve or remove |
| Uppercase state values | lowercase (`pending`, `building`, …) | The canonical lifecycle is lowercase everywhere; two spellings is a permanent source of bugs |
| Single `active` boolean + `CHECK (NOT active OR status IN …)` | **D4** — three orthogonal axes: `state` / `slot_busy` / `is_active` | Conflates "a worker is on it" with "it is live on the host". These are the two things that must never be merged — see `docs/MENTAL-MODEL.md` §3 |
| Partial index on `WHERE status = 'PENDING'` | **D11** — index on `coalesce(lease_expires_at,'-infinity')` over the non-terminal set | An index that only matches `'PENDING'` does not help reclaiming work abandoned later in its life (`cloning`, `building`, …), which is exactly the case a lease exists for |
| No `lease_generation` fencing | **D2** — lease + fencing | Without a monotonic generation, a resurrected zombie worker can still write and corrupt state |

## What replaces it

Write the real migration from `docs/data-architecture.md`, corrected by
`research_notes/Shipyard build primitives/VERIFIED.md`, and obeying
`docs/MENTAL-MODEL.md` §5. It does not exist yet — it is written by hand in
**Phase 2** of `docs/ROADMAP.md`.

Verified constraints to honour when you do write it (all proven on PostgreSQL
18.6 — see `VERIFIED.md` §1):

- `slot_busy` as `boolean GENERATED ALWAYS AS (state IN (…)) STORED` is **legal**
  (an enum-membership test is immutable), and a `UNIQUE (project_id, server_id)
  WHERE slot_busy` index is **enforced by the database**.
- Never build a generated column over `now()` — it is not immutable and is
  rejected by the server.
- Always write `STORED` explicitly: the bare default became `VIRTUAL` in PG 18.
- Put `FOR UPDATE SKIP LOCKED` **inside** a CTE, never outside a CTE reference —
  outside, Postgres silently does not lock, which is a correctness bug.
