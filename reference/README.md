# Reference

Research material behind the design. **Not code** — you write all the code.

## Precedence

```
VERIFIED.md  >  docs/MENTAL-MODEL.md  >  docs/ROADMAP.md  >  the deep dives below
```

If two documents disagree, the higher one wins. `VERIFIED.md` wins over
everything because it is the only one whose claims were actually *executed*.

---

## `Shipyard build primitives/VERIFIED.md` — **read this first**

The distilled, proven facts. Everything in it was either:

- **empirically tested** on a live PostgreSQL 18.6 instance, or
- **confirmed against authoritative docs / upstream issue trackers** (with links).

It also records **corrections to the original design**, including two that
inverted earlier reasoning:

1. A crashed worker does **not** leave rows locked forever — row locks are
   transaction-scoped. The lease is still mandatory, but to recover
   *committed-but-abandoned* work, not to free locks.
2. `.path` units do **not** fire on atomic symlink replacement — still broken on
   systemd 256.8. The deploy must explicitly `systemctl restart`.

If you only keep one reference file, keep this one.

---

## The five deep dives

Long-form research (~5,200 lines). Consult these when you reach the phase that
needs them, not up front — they are working notes, and their line-number
citations into the now-removed raw analyses are historical provenance.

| File | Lines | Read it when |
|---|---|---|
| `go-ssh-execution.md` | 888 | Phase 2 — writing the SSH transport, exit codes, detached remote jobs |
| `postgres-claim-lease.md` | 976 | Phase 2 — the claim query, lease renewal, fencing, `LISTEN/NOTIFY` |
| `nginx-and-systemd.md` | 873 | Phase 1 then 5 — unit files, `daemon-reload` vs `restart`, config apply, journald cursors |
| `sse-and-api-semantics.md` | 873 | Phase 3 — SSE framing, resume cursors, ETag, idempotency keys |
| `secrets-and-key-management.md` | 1549 | Phase 5 — AES-GCM layout, the AAD case-sensitivity trap, SSH deploy keys |

---

## Removed during cleanup

The following were deleted because they were *inputs* that had already been
distilled into `MENTAL-MODEL.md` — keeping them is precisely what produced three
mutually incompatible designs. They remain in git history at `b3fa356`:

- `docs/backend-design.md` and `docs/data-architecture.md` — two independent
  designs that disagreed on the lease model, the status representation, and
  whether a queue table existed.
- `docs/swap_link.sh`, `docs/swaprace.c` — agent-written code. You write all code.
- `db/migrations/`, `db/seed/` — an agent-written migration that violated D2, D4,
  D11, and D12, and seed data for a schema that does not exist.

**If you need the removed raw analyses back:** `git show b3fa356:docs/backend-design.md`
