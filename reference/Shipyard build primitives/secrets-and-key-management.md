# Secrets and key management in Shipyard

Research notes. Scope: how Shipyard stores and transports secrets — the master
key, per-project environment values in PostgreSQL, SSH credentials, remote
`shared/.env` writes, log redaction, and key rotation. Everything below was
verified against the current toolchain and the current published sources.

The Go in §5, §6, §7, §8, and §10 was extracted verbatim from this document,
assembled into three packages, and run: it builds, vets, and passes 23 security
assertions, including the ones that should fail (wrong owner, wrong name, wrong
table, flipped bits, short input, bad key size, a split secret). §14 lists them
and is explicit about what was *not* executed — the systemd, shell, and SQL
blocks are unverified by design and are marked as such.

Assumptions taken from the existing design, which this document does not reopen:

- One operator. Solo, evenings-and-weekends. No tenants, no HA, no compliance
  regime.
- Shipyard itself stores per-project app env encrypted in PostgreSQL
  (`db/migrations/0001_init.up.sql` §3, `project_env` / `deployment_env`).
- The git deploy key lives only on the target host (`docs/backend-design.md` §3.5).
- Startup secrets live in `shipyard.enc`, `age`-encrypted, with the passphrase
  supplied by systemd `LoadCredential=` (`docs/backend-design.md` §8.3).

---

## 1. Bottom line

**Use a single 32-byte random master key. Derive three subkeys from it with
HKDF-SHA256. Encrypt per-project values with AES-256-GCM in the application
process, not in PostgreSQL. Fingerprint values with HMAC-SHA256 under a
subkey, not bare SHA-256. Do not implement automatic key rotation; document four
one-command manual rotations instead.**

Everything below that is more complicated than this is a cost with no
corresponding threat, and the existing design already says so in
`docs/backend-design.md` §8.5. This
document mostly explains *why* that is correct, and covers the two places where
the existing design is genuinely arguable: bare SHA-256 fingerprints (§6) and
`age`-versus-something-else for the master key (§4).

Three concrete deltas from the current docs, all argued in §6, §7.2, §9, and §12:

1. `db/migrations/0001_init.up.sql:217` comments `value_fingerprint` as
   "sha256 of the plaintext", but `docs/backend-design.md:1434` specifies
   "HMAC-SHA256". They disagree. §6 argues for the HMAC, because a bare SHA-256
   of a low-entropy secret is a confirmation oracle for anyone who can read the
   row.
2. `shared/.env` is specified `0640 root:appsvc` at
   `docs/backend-design.md:1327`. The app never needs to *open* that file — it
   gets its values through its own `/proc/self/environ`, injected by PID 1. So
   `0600 root:root` is sufficient and strictly better. See §9.
3. `project_env.name` is `citext` while the name is also AAD (§7.2), so a
   casing mismatch between the request and the stored row makes a valid
   ciphertext fail authentication. Fix the normalization before there is data
   in the table. See §7.2 and §12 item 3.

---

## 2. Threat model

Ranked by how likely they are to actually happen to this project. This ordering
drives every recommendation below; most secret-management complexity exists to
address rows near the bottom.

| # | Threat | Defended by | Worth engineering for? |
|---|---|---|---|
| 1 | Stolen laptop / stolen backup / a repo I accidentally committed to | Encryption at rest (`shipyard.enc`, `project_env`) | **Yes** — this is the design's stated goal (`docs/backend-design.md:1400`) |
| 2 | A log line, error message, or panic containing a secret | Never putting secrets in argv/env; type-level redaction (§10) | **Yes** — this actually happens |
| 3 | Another process on the target host reading the env | Unix permissions, `shared/` ownership, dedicated `shipyard` user | **Yes** — cheap, and the design already does it |
| 4 | A leaked per-project value (e.g. a public repo) needing revocation | Re-encrypting one row; revoking a host key | **Yes** |
| 5 | An attacker with root on the control-plane host | Nothing, except SSH host key pinning (§8) which buys you *detection* | Partially |
| 6 | Malicious/compromised app code on the target host | Nothing — it can read its own env by design | **No** — accept it |
| 7 | Side channel: timing, cache, speculative execution | Not addressed | **No** — out of scope |
| 8 | Cryptanalysis of AES-GCM | Stdlib | **No** |
| 9 | Attacker with a *copy* of your PostgreSQL database | AES-GCM + random nonce | **Yes** — the main justification for column encryption |
| 10 | Insider with legitimate read access to the control plane | Nothing | **No** — single operator |

The important structural point: **rows 1–4 are all about confidentiality at rest
and in transit, and none of them are about key *management* per se.** Rows 5–10
are where Vault, KMS, and rotation infrastructure would help, and they are also
the rows that do not apply.

---

## 3. Where each secret lives

| Secret | Storage | Format | Notes |
|---|---|---|---|
| Master key (32 bytes) | inside `shipyard.enc` | `age` scrypt-encrypted file | Random, not a passphrase — see §5 |
| `age` passphrase | systemd tmpfs credential | `LoadCredential=` | Never in the unit file, never in `ps` |
| Per-project env value | `project_env.value_sealed` | `bytea`, AES-256-GCM | §7 |
| Per-project env fingerprint | `project_env.value_fingerprint` | `bytea`, HMAC-SHA256 | §6 |
| Deployment env snapshot | `deployment_env.value_sealed` | `bytea`, AES-256-GCM | Immutable; AAD binds `deployment_id` |
| Per-deployment env fingerprint | `deployments.env_fingerprint` | `bytea` | Set of pairs, not per-value |
| App env on target | `<app>/shared/.env` | `0600 root:root` | §9 |
| SSH admin private key | `shipyard.enc` | OpenSSH key, unencrypted at rest-in-memory | Parsed once at startup |
| Git deploy private key | **target host only** | `<deploy>/.ssh/id_deploy` | Shipyard never holds it |
| Git deploy *public* key | `authorized_keys` | restricted | Shipyard holds only this half |
| Host keys | `known_hosts` on the control plane | OpenSSH | Pinned at enrollment |

`deployment_env` deserves a note: it is a deliberate immutable snapshot
(`db/migrations/0001_init.up.sql:227`) so that "reproduce the exact env it ran
with" is answerable months later. It is also the reason §11's rotation advice is
"re-wrap, do not re-encrypt".

---

## 4. Master key management: honest comparison

The question is only "where does the 32-byte master key live while Shipyard is
running, and where does it live while it is not?" Everything else is downstream.

| Option | Key at rest | Key in memory | Extra moving parts | Verdict for Shipyard |
|---|---|---|---|---|
| **Plaintext env var** | Unit file, `systemctl show`, `/proc/<pid>/environ` | Yes | None | **No** — see below |
| **File, `0600`** | On disk, plaintext | Yes | None | No — same threat as no encryption |
| **`age` + `LoadCredential=`** | Encrypted blob in the unit dir | Yes | One static binary at setup time | **Yes** — the current design |
| **`systemd-creds encrypt`** | Encrypted, **bound to the host** | Yes | None at runtime | Yes, slightly better — §4.1 |
| OS keyring (Secret Service) | Keyring daemon | Yes | Needs a session bus and a login | **No** — a systemd service has no session |
| Cloud KMS | Never exists on disk | **No** | Network, IAM, latency, quota, no offline deploys | **No** — §4.2 |
| `gopass` | `~/.password-store` | Yes | Passphrase agent, gpg underneath | **No** — a human CLI, not a daemon API |
| SOPS as a library | Encrypted file | Yes | `decrypt` subpackage only; rest is explicitly unstable API | **No** — see §4.3 |
| Envelope/KMS-wrap per row | Per-row DEK | Data keys | +3 columns, +~150 lines | **No now**, add `key_version` now (§11) |

### 4.1 Why not a plaintext env var

The design's own reasoning at `docs/backend-design.md:775-790` is correct and
applies with more force at the control plane than on the target:

- The value is visible in `/proc/<pid>/environ` to the process owner and root.
- A systemd unit's `Environment=` is readable via `systemctl show` and appears
  in `systemctl cat` and unit dumps. That is *not* limited to root on every
  configuration.
- Any child process the API spawns inherits it, including anything that dumps
  its own environment.
- It lands in crash reports and in any `env`-printing debug endpoint.

`LoadCredential=` fixes all of those: systemd writes the plaintext to a
tmpfs-backed file under `/run/credentials/<unit>/` at start, readable only by
the service, and never persists it. Note that `LoadCredential=` is the *plaintext*
variant — the file path you point it at must already be safe. The stronger form
is `LoadCredentialEncrypted=`, which takes a blob produced by
`systemd-creds encrypt` and is additionally bound to the host's key, so the
encrypted credential is useless if copied to another machine.

```ini
# /etc/systemd/system/shipyard.service
[Service]
ExecStartPre=/usr/bin/install -d -m 0700 -o shipyard /run/shipyard
# weaker: plaintext file must be safe before systemd touches it
LoadCredential=passphrase:/run/shipyard/age-passphrase
# stronger: blob is host-bound, decryptable only on this machine
# LoadCredentialEncrypted=passphrase:/etc/credstore.encrypted/age-passphrase
Environment=SHIPYARD_KEY_PASSPHRASE_FILE=%C/age-passphrase
```

`%C` expands to the credential directory. Do **not** read the credential into an
env var inside the process — that reintroduces exactly what you avoided. Read
the file, derive, zero the buffer.

Caveat worth stating: `LoadCredentialEncrypted=` with host binding means
losing the host key (disk wipe, reinstall) makes the credential permanently
unrecoverable. That is a feature for threat #1 and a footgun at 3am. Keep an
unencrypted `shipyard.enc` backup somewhere else.

### 4.2 Why not a cloud KMS

KMS's real benefit is that the key never exists in process memory, and the key
can be revoked centrally. Shipyard cannot use the benefit: every deploy needs
the data key, so either the process holds a long-lived data key (defeating the
purpose) or it calls KMS on every deploy (adding a network dependency and a
latency/failure mode to the critical path, and making offline deploys
impossible).

The honest version: **KMS is the right answer the day Shipyard has more than one
operator, or stores secrets for someone other than its own operator.** It is
strictly worse than a local file for a single operator on a VPS.

### 4.3 Why not SOPS as a library

SOPS is excellent and the wrong shape here. Its own module documentation states
that the root `sops` package "should not be used directly" and that *no* package
except `.../sops/v3/decrypt` has API stability guarantees. The module has also
moved (`go.mozilla.org/sops/v3` → `github.com/getsops/sops/v3`). It encrypts
*files*, not rows, and its value is editor-friendly `ENC[AES256_GCM,...]` output
in git — which is precisely the property Shipyard does not want, since its
secrets live in PostgreSQL and its source of truth is the UI.

If you ever want SOPS-shaped ergonomics — human-readable, diffable, committed
encrypted config — use the `sops` **binary** from a `shipyardctl` subcommand and
keep the runtime path on `age` or raw AES-GCM. That gets you the tooling without
the unstable library API.

Verify the current import path with `go list -m -versions github.com/getsops/sops/v3`
before adding it; the module path changed once already.

---

## 5. Key derivation: when you actually need a KDF

This is where most implementations go wrong, by applying a password KDF to a
value that is not a password.

**A KDF exists to stretch low-entropy input.** Shipyard's master key is 32 bytes
from `crypto/rand` — full entropy, no dictionary. Running Argon2id over it adds
~60ms of latency and zero security. The correct derivation is HKDF, which exists
to *separate* one secret into several independent purposes, not to add entropy.

Three distinct jobs, three distinct tools:

| Input | Tool | Why |
|---|---|---|
| 32 random bytes (master key) | **HKDF-SHA256** | Split into independent subkeys. Not for entropy. |
| `age` passphrase (human-chosen) | **Argon2id** (inside `age`) | Stretch low entropy against offline guessing |
| Raw SSH private key (random) | **None** | Full entropy already |

`age` already applies its own scrypt KDF to the passphrase when encrypting
`shipyard.enc`. So Shipyard's Go code **does not need a KDF at all** for the
master key — the age layer is the KDF layer, and the Go process only ever sees
the 32 random bytes. This is the single most useful simplification in the whole
area, and it is why §1 does not put Argon2 in the runtime path.

### 5.1 HKDF subkey derivation

```go
package secrets

import (
	"crypto/hkdf"
	"crypto/sha256"
	"fmt"
)

// Subkeys is the set of independent keys derived from one master secret.
// Never use Master directly for anything.
type Subkeys struct {
	EnvAEAD     []byte // AES-256-GCM for project_env / deployment_env
	Fingerprint []byte // HMAC-SHA256 for change detection
	HostWrap    []byte // wrapping keys for per-host material (reserved)
}

func DeriveSubkeys(master []byte) (*Subkeys, error) {
	if len(master) != 32 {
		return nil, fmt.Errorf("master key must be 32 bytes, got %d", len(master))
	}
	// Distinct info strings => independent subkeys. A nil salt is fine:
	// the input already has full entropy, and there is no second party
	// to be salt-separated from.
	enc, err := hkdf.Key(sha256.New, master, nil, "shipyard/v1/env-aead", 32)
	if err != nil {
		return nil, err
	}
	fp, err := hkdf.Key(sha256.New, master, nil, "shipyard/v1/fingerprint", 32)
	if err != nil {
		return nil, err
	}
	wrap, err := hkdf.Key(sha256.New, master, nil, "shipyard/v1/host-wrap", 32)
	if err != nil {
		return nil, err
	}
	return &Subkeys{EnvAEAD: enc, Fingerprint: fp, HostWrap: wrap}, nil
}
```

`crypto/hkdf` is stdlib as of Go 1.24 — **no dependency needed.** It is
[marked experimental](https://pkg.go.dev/crypto/hkdf) but has been stable since;
`golang.org/x/crypto/hkdf` is a frozen compatibility shim whose API differs
(`Expand` vs `Expand` with byte slice), so prefer stdlib. Confirmed present on
Go 1.27.1.

The `info` strings are part of the contract. Changing one is a breaking change
to every stored ciphertext, so version them (`shipyard/v1/...`) as shown.

### 5.2 Argon2id, if you ever need it

Only relevant if a *human passphrase* ever has to protect a key Shipyard reads
without an interactive unlock. `age` covers that today. If you add a path:

```go
import "golang.org/x/crypto/argon2"

// OWASP's recommended floor for Argon2id, and RFC 9106's second recommended
// option (64 MiB, t=3, p=4). Benchmark on your target hardware: the goal is
// 100-250ms.
key := argon2.IDKey(
    []byte(passphrase),
    salt,      // >= 16 bytes from crypto/rand, stored beside the ciphertext
    3,         // time (passes)
    64*1024,   // memory in KiB
    4,         // threads
    32,        // output length = AES-256
)
```

Measured on the development machine (12 cores, Go 1.27.1): **57ms** at
`t=1, m=64MiB, p=4`; `t=3` would be ~170ms. Fine for an interactive
`shipyardctl init`, far too slow for a per-deploy path.

Never use a hardcoded salt — a per-value random salt, stored in the same record
as the ciphertext, is the whole point.

### 5.3 scrypt

`age` uses scrypt internally; you will not call it directly. Documented
recommended parameters for interactive use are `N=32768, r=8, p=1` (from the
`scrypt.Key` doc comment), and `N` must be a power of two greater than 1.

```go
import "golang.org/x/crypto/scrypt"

key, err := scrypt.Key([]byte(passphrase), salt, 1<<15, 8, 1, 32)
```

Measured: **125ms** at `N=2^15, r=8, p=1`. The package validates its inputs and
returns `scrypt: N must be > 1 and a power of 2` for bad `N` — verified.

### 5.4 PBKDF2

**Prefer not to.** It is not memory-hard, so it is materially cheaper for an
attacker per unit of guessing than Argon2id or scrypt. OWASP's guidance on it is
expressed purely in iteration counts (600,000 for PBKDF2-HMAC-SHA256) precisely
because it lacks the memory cost that makes the others expensive.

Since Go 1.24 it is stdlib (`crypto/pbkdf2`), and `golang.org/x/crypto/pbkdf2` is
now a frozen wrapper that forwards to it. If you must:

```go
import "crypto/pbkdf2"

key, err := pbkdf2.Key(sha256.New, passphrase, salt, 600_000, 32)
```

Note the argument order differs from x/crypto: the hash constructor is **first**,
the password is a **string**, and `Key` returns an **error**.

---

## 6. Fingerprinting: bare SHA-256 leaks, HMAC does not

This is the one place where the current schema comment is arguably wrong.

### 6.1 The problem with bare SHA-256

`db/migrations/0001_init.up.sql:216-217`:

```sql
-- sha256 of the plaintext; lets the UI show "changed" without decrypting
value_fingerprint bytea NOT NULL,
```

The stated purpose is good and worth keeping: show "changed?" in the UI without
decrypting, and let the agent decide whether a redeploy is needed. The
construction has a flaw that only matters for *low-entropy* values, and
environment variables are full of them.

An attacker who reads the database (a stolen backup — threat #1, the one the
whole design is built around) gets `value_fingerprint` for free. They can then
confirm a guess offline:

```go
candidate := sha256.Sum256([]byte("production"))
// compare to the stored value_fingerprint for that row
```

For `STRIPE_SECRET_KEY` this is hopeless to crack and fine. For any of these it
is instant:

| Value | Guessable? |
|---|---|
| `NODE_ENV=production` | Trivial |
| `APP_ENV=staging` | Trivial |
| `LOG_LEVEL=info` | Trivial |
| `SENTRY_DSN=https://public@o1.ingest.sentry.io/2` | In every public repo |
| `DATABASE_URL=postgres://app:<pw>@localhost:5432/app` | Hostname is public; `pg_hba.conf` and error messages often leak the rest |
| `REDIS_URL=redis://cache:6379` | Trivial |

So the fingerprint column, intended to be harmless metadata, becomes a
side channel that confirms a guessed secret — and it does so for exactly the
boring, non-credential config values that the schema happily accepts
(`name ~ '^[A-Za-z_][A-Za-z0-9_]*$'`, so anything goes in).

Worse, fingerprints are **stable across rows**, so they also act as a
correlation oracle: identical fingerprints across different projects tell an
attacker those two projects share a value, without decrypting anything.

### 6.2 HMAC fixes both

An HMAC under a secret key is not computable by an attacker who does not have
the key. That restores the column to "harmless metadata", and the change
detection property is unchanged.

```go
package secrets

import (
	"crypto/hmac"
	"crypto/sha256"
)

// ValueFingerprint returns a deterministic, keyed digest of a secret value.
// The returned bytes are safe to store and to display: without the
// Fingerprint subkey, an attacker holding the row cannot confirm a guessed
// value, cannot correlate values across rows, and cannot precompute a
// dictionary.
func ValueFingerprint(fpKey []byte, value []byte) []byte {
	m := hmac.New(sha256.New, fpKey)
	// Domain-separate from any other HMAC made with this key.
	m.Write([]byte("shipyard/v1/value-fingerprint\x00"))
	m.Write(value)
	return m.Sum(nil)
}
```

32 bytes. Store it truncated if you want, but there is no reason to — it is not
a secret once it is keyed.

`docs/backend-design.md:1434` already specifies `value_sha bytea NOT NULL, --
HMAC-SHA256`. **Follow the design doc, and fix the migration comment**, or
change the design doc. Do not ship with both saying different things. Given the
analysis above the HMAC is correct.

Note the naming: the column is `value_fingerprint`, not `value_sha`, and
`deployments.env_fingerprint` is a *different* computation (§6.3). Keep them
distinguishable.

### 6.3 The deployment-level fingerprint is a set, not a value

`deployments.env_fingerprint` (`db/migrations/0001_init.up.sql:154-155`) hashes
"the sorted (name, value) pairs this run actually used". That is a different
thing and needs a canonical encoding, or it will not be reproducible.

```go
// CanonicalEnv produces a deterministic byte encoding of an environment set:
// names sorted by byte order, each name and value length-prefixed. The
// length prefixes are what stop {"AB":"C"} colliding with {"A":"BC"}.
func CanonicalEnv(env map[string]string) []byte {
	names := make([]string, 0, len(env))
	for k := range env {
		names = append(names, k)
	}
	slices.Sort(names)

	var buf []byte
	var lenBuf [4]byte
	for _, n := range names {
		v := env[n]
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(n)))
		buf = append(buf, lenBuf[:]...)
		buf = append(buf, n...)
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(v)))
		buf = append(buf, lenBuf[:]...)
		buf = append(buf, v...)
	}
	return buf
}

// EnvFingerprint is the deployment-level digest: one value for the whole set.
func EnvFingerprint(fpKey []byte, env map[string]string) []byte {
	m := hmac.New(sha256.New, fpKey)
	m.Write([]byte("shipyard/v1/env-set\x00"))
	m.Write(CanonicalEnv(env))
	return m.Sum(nil)
}
```

This is also HMAC, not SHA-256, for the same reason: a bare digest of the whole
set is a much smaller oracle (an attacker must guess every key and value
correctly at once), but a *set* fingerprint still confirms a full correct guess,
and one successful confirmation is all that is needed. HMAC costs nothing here.

Verified behaviours (§14): map iteration order does not affect the result; any
value change changes the result; `{"AB":"C"}` and `{"A":"BC"}` do not collide.

---

## 7. AES-256-GCM

The wire format is fixed by the schema comment at
`db/migrations/0001_init.up.sql:214`: `[12-byte nonce || ciphertext || 16-byte
tag]`. That is the right format. Three things to get right, all of which the
implementation below does.

### 7.1 Why these three things matter

**1. Nonce uniqueness is a hard requirement, not a style preference.** Reusing a
(nonce, key) pair with GCM is catastrophic and unauthenticated: it leaks the XOR
of the two plaintexts and, for the keystream-reuse case, allows recovery of the
GCM authentication subkey, which lets an attacker *forge* arbitrary ciphertexts.
`crypto/cipher`'s own documentation states the requirement plainly. `crypto/rand`
for 12 bytes is the right source; do not use a counter or a timestamp unless you
can prove single-threaded uniqueness.

**2. Associated data must bind the ciphertext to its location.** Without AAD, a
`value_sealed` row copied from project 7 to project 9 decrypts perfectly, and
`deployment_env` rows become freely swappable between deployments. AAD costs
nothing and is exactly the right tool: it is authenticated but not transmitted.

**3. Never hand `Open` a reused buffer.** On authentication failure `Open` may
have written unauthenticated plaintext into the destination. If that buffer
previously held a real secret, a single forged row can corrupt it. Always pass
`nil` for a fresh allocation.

Also: return a **sentinel error**, not the raw `cipher` error, and never include
ciphertext or plaintext in error text.

### 7.2 Implementation

```go
package secrets

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	sealedVersion byte = 1

	// Layout: version(1) || nonce(12) || ciphertext || tag(16)
	// The schema comment at db/migrations/0001_init.up.sql:214 describes
	// the nonce+ciphertext+tag portion; the version byte is ours and gives
	// us a migration path.
	nonceSize  = 12
	keySize    = 32
	tagSize    = 16 // cipher.NewGCM's Overhead(); assert it, do not assume
	headerSize = 1 + nonceSize
)

// ErrSealed is returned for any authentication failure, wrong AAD, or
// truncation. It deliberately carries no detail: distinguishing "wrong key"
// from "tampered ciphertext" tells an attacker something, and Shipyard has
// no operational need for the distinction.
var ErrSealed = errors.New("sealed value failed authentication")

// aadFor binds a ciphertext to where it belongs. A row moved to another
// project, renamed, or attached to another deployment fails to open instead
// of silently decrypting.
//
// name MUST be the canonical stored name. See the citext note below: pass the
// value read back from the row, never the one from the request, or the
// ciphertext will not authenticate.
func aadFor(rowKind byte, ownerID int64, name string) []byte {
	aad := make([]byte, 0, 3+8+len(name))
	aad = append(aad, sealedVersion, rowKind)
	aad = binary.BigEndian.AppendUint64(aad, uint64(ownerID))
	return append(aad, name...)
}

// rowProjectEnv and rowDeploymentEnv keep the two tables from sharing an AAD
// namespace, so a project_env ciphertext cannot be replayed as a
// deployment_env ciphertext even with a matching owner id.
const (
	rowProjectEnv    byte = 0x01
	rowDeploymentEnv byte = 0x02
)

func gcmFor(key []byte) (cipher.AEAD, error) {
	if len(key) != keySize {
		return nil, fmt.Errorf("aead key must be %d bytes, got %d", keySize, len(key))
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	if gcm.NonceSize() != nonceSize {
		return nil, fmt.Errorf("unexpected nonce size %d", gcm.NonceSize())
	}
	if gcm.Overhead() != tagSize {
		return nil, fmt.Errorf("unexpected tag size %d", gcm.Overhead())
	}
	return gcm, nil
}

// Seal encrypts plaintext for (rowKind, ownerID, name). The output is
// len(plaintext) + 29 bytes, and a fresh nonce is generated per call, so
// sealing the same plaintext twice yields different ciphertext. That is
// required for GCM safety and is harmless for the fingerprint-based change
// detection, which reads value_fingerprint rather than the ciphertext.
func Seal(key []byte, rowKind byte, ownerID int64, name string, plaintext []byte) ([]byte, error) {
	gcm, err := gcmFor(key)
	if err != nil {
		return nil, err
	}
	out := make([]byte, headerSize, headerSize+len(plaintext)+gcm.Overhead())
	out[0] = sealedVersion
	if _, err := rand.Read(out[1:headerSize]); err != nil {
		return nil, fmt.Errorf("generate nonce: %w", err)
	}
	// Seal appends to out; the nonce slice keeps pointing at out[1:13].
	return gcm.Seal(out, out[1:headerSize], plaintext, aadFor(rowKind, ownerID, name)), nil
}

// Open decrypts. Any failure returns ErrSealed.
func Open(key []byte, rowKind byte, ownerID int64, name string, sealed []byte) ([]byte, error) {
	if len(sealed) < headerSize+tagSize {
		return nil, ErrSealed
	}
	if sealed[0] != sealedVersion {
		// Not an error worth distinguishing: a future version is still
		// "cannot open".
		return nil, ErrSealed
	}
	gcm, err := gcmFor(key)
	if err != nil {
		return nil, err
	}
	// nil destination => fresh allocation. On failure Open may have
	// written unauthenticated bytes into dst, so dst must never alias
	// anything we still need.
	pt, err := gcm.Open(nil,
		sealed[1:headerSize],
		sealed[headerSize:],
		aadFor(rowKind, ownerID, name),
	)
	if err != nil {
		return nil, ErrSealed
	}
	return pt, nil
}
```

Zero the plaintext buffer when done if the caller is security-sensitive:

```go
defer clear(plaintext) // Go 1.21+
```

This is best-effort — the compiler may have copied it — but it is free, and it
removes the long-lived copy that a GC would otherwise keep.

### 7.3 Write-only in PostgreSQL, enforced by types

`docs/backend-design.md:1440-1445` proposes write-only-at-the-API and justifies
it with repository-interface discipline. Go's type system can do better, and the
right shape is worth being explicit about:

```go
// Sealed is the ONLY representation of a secret in the data layer. It has
// no method that returns plaintext, so a handler cannot leak a value by
// forgetting to strip a field: there is nothing to strip.
type Sealed struct {
	rowKind byte
	ownerID int64
	name    string
	cipher  []byte
}

// Open requires the key explicitly and is the single chokepoint through
// which plaintext exists. Every call site is greppable.
func (s Sealed) Open(key []byte) ([]byte, error) {
	return Open(key, s.rowKind, s.ownerID, s.name, s.cipher)
}
```

**The `citext` trap — the one thing most likely to break this in production.**
`project_env.name` and `deployment_env.name` are `citext`
(`db/migrations/0001_init.up.sql:213`, `:231`). `citext` compares
case-*insensitively* but stores the text as first written, and the CHECK
constraint `name ~ '^[A-Za-z_][A-Za-z0-9_]*$'` (`:222`) is an ordinary
case-sensitive Postgres regex, so uppercase names like `DATABASE_URL` pass it
and are the convention for environment variables.

So `DATABASE_URL` and `database_url` are the same primary key, the row holds
whichever casing was inserted first, and an `UPDATE` can change the stored
casing without changing the key's identity. Now apply that to AAD:

- Seal with the name from the request (`DATABASE_URL`), and a later read that
  takes the name from the row gets `database_url` → the AAD differs → `Open`
  fails with `ErrSealed`.
- That failure is indistinguishable from real corruption or a wrong key, which
  is the worst possible outcome: correct data, unrecoverable-looking, and the
  natural debugging instinct ("did the key change?") sends you in exactly the
  wrong direction.
- Worse, it is intermittent. It reproduces only when casing differs, so it
  shows up on one environment variable, on one machine, after a data import.

Three ways out, in order of preference:

1. **Normalize before it reaches the database.** Make the name canonical
   (`strings.ToUpper`) in the API write handler, before sealing *and* before
   insert, so the stored value and the AAD are the same string by construction.
   Cheap, and it makes the CHECK constraint's `A-Z` allowance pointless.
2. **Build the AAD from the row, never from the request.** In the read path,
   pass the `name` column value. Correct on its own, but it does not stop the
   write path from sealing under a name the row does not have.
3. **Use `text` plus a `CHECK (name = upper(name))`.** Cleanest, and it makes
   the invalid state unrepresentable rather than merely avoided. It is a
   migration on a table that does not exist yet, so it is free right now and
   expensive after the first deploy.

Whichever you pick, the rule to write in the package doc is the one in the
`aadFor` comment: **the AAD name is the stored name.** A rename must re-seal, and
with option 1 or 3 a case-only change is not a rename at all.

Two rules that must hold in review:

- The `project_env` **read** queries must select columns explicitly. Never
  `SELECT *`. There is no `Value` column, so there is nothing to leak — but
  `SELECT *` into a struct that *does* have a `Value` field is the exact
  regression to look for.
- The API's read handler returns `[{name, has_value, updated_at}]`. Do not
  return `value_fingerprint` either. It is keyed, so it is not directly
  dangerous, but there is no reason for a client to have it, and it makes
  the UI able to test guesses.

### 7.4 Do not encrypt in PostgreSQL

`pgcrypto`'s `pgp_sym_encrypt` with a passphrase from a setting, or `pgcrypto`
with the key in a shared file on the DB host, are both worse than application-
side encryption and are worth rejecting explicitly in review:

- The key ends up in the database's memory, in `pg_settings`, and in a file on
  the DB host — the same trust boundary as the data. A `pg_dump` plus that file
  is total compromise, and the "encrypted" column gives false comfort.
- Nonce management is not yours to get right, and `pgcrypto` does not bind
  ciphertext to a row.
- It makes the DB the only component that can decrypt, which fights the
  `deployment_env` snapshot replay path.

### 7.5 What AES-GCM does not protect

- **The plaintext in process memory.** A core dump, a heap dump, or a
  `/proc/<pid>/mem` read by root gets it. `madvise(MADV_DONTDUMP)` and Go's
  `GODEBUG=madvdontneed=1` help marginally; they are not a control.
- **Length.** GCM is length-preserving, so an observer can tell that a value is
  40 bytes and not 400. If that matters (it usually does not for env vars), pad.
- **A key held forever in memory.** The master key lives for the process
  lifetime by design. On a host where you do not trust root, that is the
  exposure.
- **Rollback attacks.** An attacker with write access to the database can
  restore an old `value_sealed` and `value_fingerprint` pair. GCM cannot detect
  it — it authenticates, it does not version. `deployment_env` is append-only by
  primary key but nothing prevents a row delete. If you care, you need a
  monotonic counter or a `pgcrypto`-style external MAC; Shipyard does not.

---

## 8. SSH credentials

The design's decision at `docs/backend-design.md:761-770` — the git deploy key
never moves per-deploy, Shipyard never possesses a secret that can deploy
anywhere — is the single best security decision in the design. Keep it. What
follows is the operational detail around it.

### 8.1 Per-host keys, not one key

One keypair per target host. The blast radius of a stolen admin key is then one
host instead of the fleet, and revoking is `shipyardctl host enroll` on one
host rather than a fleet-wide rotation.

```bash
# Run on the CONTROL PLANE, per host, once. ed25519: small, fast, no
# SHA-1 or RSA key-size negotiation to get wrong.
ssh-keygen -t ed25519 -a 100 -N '' -C "shipyard-admin@host-01" -f ./host-01_ed25519
# The private key goes into shipyard.enc. Never onto a build host.
```

`-a 100` sets the private-key encryption KDF rounds. Shipyard holds this key
unencrypted in memory anyway (§8.3), so the passphrase on this particular key
buys nothing against a memory read — but it does buy something against a
careless `cp`. If the private key is passphrase-protected, prefer `-a 100` over
the default and treat the passphrase as a real secret.

The public half is installed on the target during enrollment. The
`known_hosts` entry is captured at the same moment, by a human looking at the
fingerprint. That is the whole trust bootstrap, and it is the step most worth
doing slowly.

### 8.2 Pin the host key, strictly

```go
package sshdial

import (
	"errors"
	"fmt"
	"net"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// NewClient dials a host with a pinned host key.
//
// knownhosts.New in strict mode (no RevokedHosts, no WildcardHost) means:
// an unknown host is an error, not a trust-on-first-use prompt. Shipyard is a
// daemon, so TOFU is not available anyway — there is no human to ask.
func NewClient(addr string, user string, signer ssh.Signer) (*ssh.Client, error) {
	cb, err := knownhosts.New("/var/lib/shipyard/known_hosts")
	if err != nil {
		return nil, fmt.Errorf("load known_hosts: %w", err)
	}
	cfg := &ssh.ClientConfig{
		User: user,
		Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)},
		// The chokepoint. Everything else in this file can be wrong and
		// this line still stops a MITM.
		HostKeyCallback: cb,
		// Pin the algorithm so a downgrade to ssh-rsa/SHA-1 is refused even
		// if the host somehow offers it.
		HostKeyAlgorithms: []string{ssh.KeyAlgoED25519},
		Timeout:           10 * time.Second,
	}
	conn, err := net.DialTimeout("tcp", addr, 10*time.Second)
	if err != nil {
		return nil, err
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		conn.Close()
		return nil, classifyHostKeyError(err)
	}
	return ssh.NewClient(c, chans, reqs), nil
}

// classifyHostKeyError turns a key mismatch into an actionable message
// without leaking the stored key material. knownhosts.KeyError carries
// Want: an EMPTY Want means "host not in the file", a NON-EMPTY Want means
// "the key we have is not the key it presented" — i.e. a possible MITM or a
// rebuilt host. Those deserve very different responses.
func classifyHostKeyError(err error) error {
	var ke *knownhosts.KeyError
	if errors.As(err, &ke) {
		if len(ke.Want) == 0 {
			return fmt.Errorf("host not in known_hosts: enroll it first: %w", err)
		}
		return fmt.Errorf("HOST KEY MISMATCH: the host presented a different key "+
			"than the one recorded at enrollment. If this host was rebuilt, "+
			"re-enroll deliberately; otherwise treat this as a compromise: %w", err)
	}
	var re *knownhosts.RevokedError
	if errors.As(err, &re) {
		return fmt.Errorf("host key is revoked: %w", err)
	}
	return err
}
```

Never ship `ssh.InsecureIgnoreHostKey()`. Grep for it in CI — it is the single
most common way a Go SSH client silently loses MITM protection.

### 8.3 The admin key in memory

Shipyard needs an unencrypted private key to sign non-interactively, and it
cannot ask a human per deploy. So: decrypt at startup, hold in memory, accept
that memory exposure as threat #5 (not defended, per §2).

`SSH_AUTH_SOCK`/`ssh-agent` is worth mentioning and not using: an agent is a
separate process holding the same key, adds a socket to secure, and offers
nothing here because Shipyard is the only client.

### 8.4 Restrict the git deploy key on the target

The design installs the public half into `authorized_keys`
(`docs/backend-design.md:761`). Make the *options* do work. The key is
server-side, so this is a place where you can cheaply make a stolen key nearly
worthless:

```
restrict,command="/usr/local/lib/shipyard/git-shell",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,no-user-rc from="203.0.113.0/24" ssh-ed25519 AAAA... shipyard-deploy@host-01
```

| Option | Effect |
|---|---|
| `restrict` | Disables pty, port/X11/agent forwarding and `~/.ssh/rc` in one word (OpenSSH 7.2+) |
| `command="..."` | Forces every session through your wrapper regardless of what the client asked for |
| `no-pty` | No shell. Belt to `restrict`'s braces |
| `no-agent-forwarding` | Stops the client from using this connection to reach an agent on the target |
| `no-user-rc` | Ignores `~/.ssh/rc` |
| `from="..."` | Source-address restriction. **Only add this if you actually have a stable egress IP.** A home connection with a CGNAT address changes constantly, and a wrong `from=` silently breaks every deploy |

The `command=` wrapper must validate the requested command itself, because
`restrict` does not stop the client from *requesting* `git-upload-pack` on an
arbitrary path:

```bash
#!/usr/bin/env bash
# /usr/local/lib/shipyard/git-shell, mode 0755, root:deploy
set -euo pipefail

# SSH_ORIGINAL_COMMAND is what the client actually asked for.
case "${SSH_ORIGINAL_COMMAND:-}" in
  "git-upload-pack '"*"'")   ;;
  "git-receive-pack '"*"'")  ;;
  *) logger -t shipyard-git "rejected command: ${SSH_ORIGINAL_COMMAND:-<empty>}"
     exit 1 ;;
esac

# Only the one repository this key exists for. The quoting is the important
# part: a naive "*/repo.git" glob also matches "/evil/../other.git".
repo="/srv/git/myapp.git"
for arg in "$@"; do
  [ "$arg" = "$repo" ] || { logger -t shipyard-git "rejected path: $arg"; exit 1; }
done

exec /usr/lib/git-core/git-shell -c "$SSH_ORIGINAL_COMMAND"
```

OpenSSH documents `restrict` and the individual options at
`sshd(8)`/`sshd_config(5)` and `authorized_keys(5)`. `from=` accepts comma-
separated patterns and `!` negation.

---

## 9. Writing `shared/.env` on the target

The design gets the mechanics right (`docs/backend-design.md:493-520`): render
the complete desired set to a temp file in the same directory, `umask 077`,
`chown`/`chmod`, then `mv -f` (which is `rename(2)`, atomic within a filesystem).
Two corrections and three additions.

### 9.1 The temp file must be on the same filesystem

`mv -f` is atomic **only within one filesystem**. A temp file in `/tmp` makes
`mv` a copy-then-unlink: not atomic, and the plaintext passes through a
world-readable directory. `docs/backend-design.md:503` correctly uses
`"$app_root/shared/.env.tmp.$$"`, which is right. Worth an explicit rule,
because the natural instinct is `/tmp`.

Also prefer `mktemp` over `$$` for the suffix: `$$` is guessable and the
predictable name invites a pre-created symlink at that path.

```bash
set -euo pipefail
umask 077

target="$app_root/shared/.env"
# Same directory => same filesystem => rename(2) is atomic. -t makes
# mktemp fail rather than fall back to $TMPDIR.
tmp="$(mktemp "$app_root/shared/.env.tmp.XXXXXXXX")"
trap 'rm -f "$tmp"' EXIT          # only reached on failure; after mv it is gone
```

### 9.2 Mode: `0600 root:root`, not `0640 root:appsvc`

`docs/backend-design.md:1327` specifies `0640 root:appsvc`, reasoning that
"systemd reads it; the app's user can read it". The second clause is where the
weakness is. **The app never opens this file.** systemd's `EnvironmentFile=`
is read by PID 1 (root) at start, and the values are injected into the app's
own environment. The app reads `/proc/self/environ`, not the path.

So the group grant is unnecessary:

```bash
chown root:root "$tmp"
chmod 0600 "$tmp"
mv -f "$tmp" "$target"
```

This is strictly better: it removes the app's service user from the set of
principals that can read every other app's `shared/.env` on the host. If an app
genuinely needs to re-read the file at runtime — some do, for hot-reload — then
it does need group read, and that should be a documented per-app exception with
`0640 root:appsvc`, not the default.

Keep `shared/` itself `0750 root:appsvc`
(`docs/backend-design.md:1326`) so the `shipyard` agent user can traverse and
write, but note the tension: if the directory is group-readable by `appsvc`
and a *different* app's `shared/` is also `0750 root:appsvc`, then any process
running as `appsvc` can read **every** app's `shared/.env`. If the fleet shares
one service user, per-app isolation of `shared/` is not achievable with
permissions alone — it needs one service user per app. That is a real design
consequence, and it is worth deciding explicitly rather than inheriting.

### 9.3 `sync` before the service reads it

`docs/backend-design.md:513` has `sync -f "$target" 2>/dev/null || true`. Keep
it, and understand what it does: `rename(2)` is atomic with respect to
*concurrent readers*, but says nothing about durability. Without a flush, a
crash can leave a directory entry pointing at a file whose data blocks are
unwritten, and the next boot hands the service a truncated or empty `.env`.
`sync -f` syncs the filesystem containing the file, which is the right scope.

`sync -f` requires coreutils 8.24+; the `|| true` is the right guard.

### 9.4 Value validation at the writer

`systemd`'s `EnvironmentFile=` is not a shell and not a simple `KEY=VALUE` dump.
It supports quoting, and backslash line continuation, and it *trims* unquoted
values. A value containing a newline cannot be represented at all.

Reject at the Go layer, before it reaches a file, rather than discovering the
mangling on the target:

```go
// validEnvValue rejects anything systemd's EnvironmentFile= cannot
// represent faithfully. A newline silently splits one variable into two
// broken ones; a leading or trailing space gets trimmed; a NUL cannot be
// in an environment at all.
func validEnvValue(v string) error {
	if strings.ContainsAny(v, "\x00\n\r") {
		return errors.New("env value contains NUL or newline")
	}
	if v != strings.TrimSpace(v) {
		return errors.New("env value has leading or trailing whitespace; " +
			"systemd trims unquoted values")
	}
	return nil
}
```

The name check already exists at the database level
(`db/migrations/0001_init.up.sql:222`), which is the right place for it. The
value check has no natural home there, so it belongs in the write path — and it
must run on the API write handler, not only at deploy time, so the user gets the
error at the point of entry.

### 9.5 Why not put it in the release directory

It is tempting to write `.env` into `releases/<n>/` since that is where the
versioned content lives. Do not:

- The release directory is the thing that gets copied around, archived, and
  diffed during rollback analysis. Secrets in it get copied.
- Rollback replaces the symlink; it does not restore env. Mixing them invites
  the belief that rollback restores configuration.
- The release is the app's code directory. If the app serves static files from
  its own directory, a `.env` is one path-traversal bug away from being served
  over HTTP.

`shared/` is the correct location, and the design already has it. Keep it.

---

## 10. Log redaction

**The primary defence is not writing the secret. Redaction is a backstop, and it
is a leaky one.** Both statements matter, and conflating them is how projects end
up with a redaction filter that gives false confidence.

### 10.1 Why redaction is not a guarantee

A filter that searches output for known secret values fails on:

| Failure | Example |
|---|---|
| Encoding | The build tool prints the URL percent-encoded, base64'd, or JSON-escaped. The filter sees `postgres%3A%2F%2F` and does not match |
| Transformation | `docker build --build-arg` echoed as a SHA, or a secret in a compiled binary's strings section |
| Fragmentation | The value is split across two log lines, or interleaved with other output, and per-line matching misses it |
| Derived values | The app logs a JWT it minted with the secret, or a connection string it re-serialized |
| The secret is the message | `error: password "hunter2" rejected` — nothing to redact *around*, the value is the payload |
| Over-redaction | A short or common value (`"1"`, `"true"`, a 4-char token) matches everywhere and destroys the log, hiding the real failure |

GitHub's own documentation makes the general point for Actions: masking
(`::add-mask::`) is a *convenience* applied on top of not printing secrets, not
a security boundary, and it is explicitly lossy — it is exact-substring matching
that cannot catch a value the tool has transformed.

### 10.2 What to do instead, in order

1. **Never print it.** The design already refuses to put secrets in argv
   (`docs/backend-design.md:775-790`), which is the single highest-leverage
   decision in this whole area. Extend the same discipline to stdout/stderr.
2. **Make accidental printing impossible at the type level.** A `Stringer`
   that redacts turns "someone forgot" from a leak into a shrug:

```go
package secrets

import "log/slog"

// Secret is a value that must never be rendered. Implementing fmt.Stringer
// and fmt.GoStringer means any accidental %v, %s, %q, %#v, or json.Marshal of
// a Secret -- or of a struct containing one -- prints [REDACTED] instead of the
// value. Verified: all of those verbs, plus json.MarshalIndent, redact.
//
// This does NOT protect a type alias, a bare string field, or a []byte copy. It
// is a backstop, not the control.
type Secret struct{ b []byte }

func NewSecret(b []byte) Secret { return Secret{b: b} }
func (s Secret) Bytes() []byte  { return s.b }

func (s Secret) String() string   { return "[REDACTED]" }
func (s Secret) GoString() string { return "[REDACTED]" }

// MarshalJSON is belt-and-braces: GoString covers %#v, not encoding/json.
func (s Secret) MarshalJSON() ([]byte, error) { return []byte(`"[REDACTED]"`), nil }

// LogValue covers slog, which checks for slog.LogValuer before Stringer.
func (s Secret) LogValue() slog.Value { return slog.StringValue("[REDACTED]") }
```

Non-`Secret` fields in the same struct are unaffected, which is what makes this
usable rather than just annoying:

```json
{"dsn":"[REDACTED]","host":"db","retries":3}
```

3. **Redact at the log-capture boundary**, not at each call site. One place,
   streaming, with the value list derived from what the deployment actually
   used — not from a hand-maintained list that drifts:

```go
package redactor

import (
	"bytes"
	"io"
	"regexp"
)

var secretNameRe = regexp.MustCompile(`(?i)\b([A-Za-z0-9_]*(?:secret|passwo?rd|passwd|token|api[_-]?key|private[_-]?key|credential|dsn|database_url|auth)[A-Za-z0-9_]*)(\s*[=:]\s*)("[^"\n]*"|'[^'\n]*'|[^\s"'` + "`" + `]+)`)

const (
	// keepBack is how many trailing bytes are held so a secret split
	// across two Write calls is still caught. The regex pass can match
	// across a boundary too, so this is a floor, not the exact need.
	keepBack = 512
	// minLiteral is the shortest value worth redacting. Below this a value
	// matches everywhere and destroys the log, hiding the real failure.
	minLiteral = 6
)

// Redactor streams output from a build, removing known secret values. It is a
// backstop against a tool that prints a secret we handed it, NOT a control: it
// is exact-substring matching and cannot catch a value the tool has encoded,
// split, or derived. See §10.1 for why that distinction matters.
//
// A Redactor is not safe for concurrent use: it carries state across Write
// calls, so writes must be serialised. Give each build its own instance.
type Redactor struct {
	out         io.Writer
	literals    [][]byte
	placeholder []byte
	varPats     []*regexp.Regexp
	buf         []byte
}

func New(out io.Writer, values []string) *Redactor {
	lits := make([][]byte, 0, len(values))
	for _, v := range values {
		if len(v) < minLiteral {
			continue
		}
		lits = append(lits, []byte(v))
	}
	// Longest first: a secret that is a PREFIX of another must not
	// partially mask the longer one.
	for i := 0; i < len(lits); i++ {
		for j := i + 1; j < len(lits); j++ {
			if len(lits[j]) > len(lits[i]) {
				lits[i], lits[j] = lits[j], lits[i]
			}
		}
	}
	return &Redactor{
		out:         out,
		literals:    lits,
		placeholder: []byte("[REDACTED]"),
		varPats:     []*regexp.Regexp{secretNameRe},
	}
}

// Write implements io.Writer. It retains a tail so that a match straddling a
// chunk boundary is still caught -- a secret split across two reads is the
// classic way a naive per-chunk filter misses it.
func (r *Redactor) Write(p []byte) (int, error) {
	r.buf = append(r.buf, p...)
	keep := keepBack
	for _, l := range r.literals {
		if n := len(l) - 1; n > keep {
			keep = n
		}
	}
	if len(r.buf) <= keep {
		return len(p), nil
	}
	emit, tail := r.buf[:len(r.buf)-keep], r.buf[len(r.buf)-keep:]
	r.buf = append(r.buf[:0], tail...)
	return len(p), r.scrub(emit)
}

// Flush emits the retained tail. Call before closing the stream.
func (r *Redactor) Flush() error { return r.scrub(r.buf) }

func (r *Redactor) scrub(b []byte) error {
	if len(b) == 0 {
		return nil
	}
	out := make([]byte, 0, len(b))
	out = append(out, b...)
	for _, l := range r.literals {
		out = bytes.ReplaceAll(out, l, r.placeholder)
	}
	s := string(out)
	for _, re := range r.varPats {
		s = re.ReplaceAllString(s, "${1}${2}[REDACTED]")
	}
	_, err := r.out.Write([]byte(s))
	return err
}
```

Wire it as the sink for the SSH session's stdout, and as the thing that feeds
`deployment_logs` inserts — one place, not per call site:

```go
red := redactor.New(logWriter, secretValuesForThisDeployment)

var wg sync.WaitGroup
wg.Add(1)
go func() {
	defer wg.Done()
	io.Copy(red, session.Stdout) // Redactor is not safe for concurrent use,
	// so this is the only writer.
}()

// Flush only after the session is done AND the copy goroutine has finished,
// otherwise the tail of the build output is lost.
session.Wait()
wg.Wait()
red.Flush()
```

The ordering is not optional. `session.Wait()` closes `Stdout`; the `io.Copy`
then returns; only then is the redactor's carry buffer guaranteed to be
complete. Flushing on `Wait()` alone races the reader and truncates the last
few hundred bytes — which is usually where the interesting part is.

The `varPats` regex is a genuine second line of defence, because the *name* is
often secret-adjacent even when the value was never seen by the control plane
(a tool that read the file on the target and echoed a URL it built). Tune it
against real build output — it is a starting point, and an over-eager one will
redact `DATABASE_HOST=...` and confuse everyone. Note it deliberately does
**not** match `HOST`, `PORT`, or `URL` on their own, only the compound names
above.

4. **Redact the error taxonomy, not the message.** The design already has a
   closed set of error codes with a `Code` field
   (`docs/backend-design.md:1471-1497`) and explicitly says `message` is human
   and `detail` is structured. Enforce that `detail` never carries a secret, by
   making the type that carries one not have a `Detail` field:

```go
// CodeError carries a closed-set code, a human message, and structured
// detail. detail must be a map of non-secret fields; a code that needs to
// report a secret gets a new Code whose message is a fixed string.
type CodeError struct {
	Code    domain.Code
	Message string
	Detail  map[string]string
}
```

A lint rule that fails the build on `Errorf` with more than two verbs inside
`internal/domain` catches most of it. This is cheap and worth doing.

### 10.3 Build logs are stored in PostgreSQL

`deployment_logs` is a partitioned table with a hard line-length bound
(`db/migrations/0001_init.up.sql:250`). Two consequences:

- Redaction must happen **before** the insert, not in a read handler. A read
  handler that redacts still leaves the plaintext in the table, in WAL, and in
  any `pg_dump`.
- Bounded lines are a DoS control, not a security control, but they do cap the
  blast radius of a runaway log line. Keep the bound.

---

## 11. Key rotation

`docs/backend-design.md:1450-1456` says no automatic rotation, and it is right.
The reasoning is worth preserving explicitly, because "we don't rotate" reads as
an omission unless you know the alternative:

> Rotation infrastructure for a project with one operator is a feature that will
> never be exercised and will therefore be broken.

That is the correct argument. A rotation path that is never run is an untested
code path, and untested security code is worse than none — it creates the
belief that rotation is handled.

### 11.1 The four rotations that matter, each one command

| What | How | Cost |
|---|---|---|
| A leaked app env value | `PUT /projects/{id}/env/{name}` with the new value | Seconds. New nonce, new ciphertext, new fingerprint |
| A leaked deploy key on a host | `shipyardctl host enroll` again on that host, then `authorized_keys` update | Minutes. One host |
| A leaked `age` passphrase | `age -p` to re-encrypt `shipyard.enc` with a new passphrase; shipyard.enc contents unchanged | Minutes |
| A leaked master key | **Not supported — see below** | — |

The first two cover the realistic cases. Document them in the runbook, with the
exact command, and link them from the incident taxonomy.

### 11.2 The master key gap, and the cheap fix

The master key cannot currently be rotated without either re-encrypting every
`project_env` and `deployment_env` row or losing access to them. That is a real
gap. Two options:

**A. Re-encrypt everything in place.** A `shipyardctl seal --rekey` that walks
both tables, decrypts with the old subkey, re-encrypts with the new one. ~100
lines, but: it requires the old key to still be available, it must run
transactionally, and it is a code path that will never be tested. Against a
table you can `pg_dump` first and restore, this is fine.

**B. Add a key version now, and do not implement rotation yet.** One column:

```sql
ALTER TABLE project_env     ADD COLUMN key_version smallint NOT NULL DEFAULT 1;
ALTER TABLE deployment_env ADD COLUMN key_version smallint NOT NULL DEFAULT 1;
```

Then the AAD gains a version byte, and a keyring is `map[smallint][]byte`. When
rotation is eventually needed, old rows are re-wrapped in a background job and
old key versions are dropped once nothing references them. Until then, `key_version`
costs one smallint and buys a migration-free path to rotation later.

**Recommendation: do B now, and do not do A.** The column is nearly free and the
migration is far easier to add before there is production data than after. A
migration on a table holding every app's secrets is exactly the operation you do
not want to perform in a hurry, and `deployment_env` is explicitly meant to be
retained "months later" — which means a table rewrite is a months-long tail
every time you rotate.

### 11.3 Envelope encryption, and why not yet

Standard envelope design: generate a random data key (DEK) per value, encrypt
the value with the DEK, and wrap the DEK with the master key (or a KMS CMK).
Rotation then re-wraps DEKs without touching plaintext, and per-value
revocation is a DEK delete.

Shipyard does not need it. The DEK would live in the same row as the
ciphertext, so an attacker with the database has both and envelope buys
nothing against threat #9. It only helps if the wrapping key is in a
*different* trust boundary — which is threat #5/#6 territory, i.e. the
multi-operator future. Revisit when there is a second operator, and not before.

---

## 12. Three corrections to the current design

Restating §1, with the reasoning, so they are easy to action:

1. **`value_fingerprint` should be HMAC-SHA256, not bare SHA-256.**
   `db/migrations/0001_init.up.sql:216` and `docs/backend-design.md:1434`
   currently disagree. §6 argues for the HMAC: a bare digest of a
   low-entropy env value confirms guesses for anyone holding a database dump,
   which is the exact scenario the column encryption exists to defend. Fix the
   comment, or fix the design doc — but not both differently.

2. **`shared/.env` should be `0600 root:root`, not `0640 root:appsvc`.**
   `docs/backend-design.md:1327`. The app reads its values from
   `/proc/self/environ`, not from the file, so the group grant is not needed.
   §9.2. Related and worth deciding: if every app on the host shares the
   `appsvc` service user, then per-app isolation of `shared/` is not achievable
   with filesystem permissions, and one service user per app is the fix.

3. **`project_env.name` / `deployment_env.name` should be `text` with
   `CHECK (name = upper(name))`, not `citext`.** Both are `citext` today
   (`db/migrations/0001_init.up.sql:213`, `:231`) while the CHECK constraint at
   `:222` is case-sensitive, so uppercase names are allowed and stored with
   whatever casing arrived first. Because the name is AAD (§7.2), a casing
   mismatch between the request and the stored row makes a valid ciphertext
   fail authentication and look like corruption. Fix it now, before the table
   has data; a rename-and-retype migration on a table holding every app's
   secrets is not something to do in a hurry.

   If `citext` is kept for the human-facing reason given at
   `db/migrations/0001_init.up.sql:8` — that `GET /env` shows `DATABASE_URL`
   rather than `database_url` — then the fix belongs in the write handler
   (`strings.ToUpper` before sealing and before insert) and the read path must
   take the name from the row, not the request. Pick one and note it in the
   package doc; do not leave it to the next reader.

---

## 13. Package and version notes

Versions as of 2026-09-29, verified against pkg.go.dev. Check before pinning;
`go list -m -versions <module>` is authoritative.

| Package | Version | Go | Use | Note |
|---|---|---|---|---|
| `crypto/aes`, `crypto/cipher`, `crypto/rand`, `crypto/hmac`, `crypto/sha256` | stdlib | — | §7, §6 | No dependency. Use these |
| `crypto/hkdf` | stdlib (Go 1.24+) | 1.24 | §5.1 | Marked experimental; API stable in practice. `x/crypto/hkdf` is a frozen shim with a different API |
| `crypto/pbkdf2` | stdlib (Go 1.24+) | 1.24 | §5.4 | Prefer not to. `x/crypto/pbkdf2` forwards to it and is frozen |
| `golang.org/x/crypto` | v0.57.0 | 1.26 | `ssh`, `knownhosts`, `argon2`, `scrypt` | Needed for `x/crypto/ssh`; the KDFs come along with it |
| `filippo.io/age` | v1.3.2 | 1.25 | `shipyard.enc` | Static binary, no daemon, no keyserver. §4 |
| `github.com/getsops/sops/v3` | v3.11.0 | — | *not used* | Only `.../decrypt` has API stability. §4.3 |

The project has no `go.mod` yet, so none of these are pinned. When it lands,
pin `golang.org/x/crypto` exactly and update on a schedule, not on a CVE.

**Deliberately not used:** `x/crypto/openpgp` (frozen in stdlib's removal list;
use `github.com/ProtonMail/go-crypto` if PGP is ever needed), `x/crypto/ssh/agent`
(§8.3), any OS keyring binding library (needs a session a daemon does not have).

---

## 14. What was verified

The Go blocks in §5, §6, §7, §8, and §10 were extracted **verbatim** from this
document, assembled into three packages (`secrets`, `redactor`, `sshdial`), and
run against Go 1.27.1 with `golang.org/x/crypto v0.57.0` under `go build`,
`go vet`, and `gofmt`. All three build clean, vet clean, and are gofmt-clean;
24 tests pass. The asserted behaviours are these, all passing:

**AES-GCM (§7.2)**
- Round trip of a 19-byte plaintext yields exactly `19 + 29 = 48` bytes
- Sealing the same plaintext twice gives different ciphertext (nonce is fresh)
- A single flipped bit in the version byte, the first nonce byte, the first
  ciphertext byte, or the final tag byte all fail with `ErrSealed`
- Input shorter than the 29-byte envelope is rejected with `ErrSealed`
- A key that is not 32 bytes is rejected by both `Seal` and `Open`
- AAD is not stored in the output (ciphertext length is `plaintext + 29`)

**AAD binding (§7.2)**
- The same ciphertext fails to open under a different `ownerID`, a different
  `name`, **and** a different row kind (a `project_env` ciphertext cannot be
  replayed as a `deployment_env` ciphertext) — all with `ErrSealed`
- **The name comparison is case-sensitive**: sealing under `DATABASE_URL` and
  opening under `database_url` fails with `ErrSealed`, while the exact casing
  succeeds. This is the `citext` problem in §7.2 reproduced as a test — it is
  why the AAD name must be the stored name, normalized once, deliberately.

**Fingerprinting (§6.2, §6.3)**
- `fingerprint(map) == fingerprint(same map, different iteration order)`
- Changing any value changes the fingerprint; so does adding a variable
- `{"AB":"C"}` and `{"A":"BC"}` produce different fingerprints — the length
  prefixes are load-bearing
- The same value fingerprints differently under different subkeys, which is the
  property that makes HMAC worth the extra step over a bare digest

**HKDF (§5.1)**
- Three subkeys of 32 bytes each, all pairwise distinct
- Derivation is deterministic for a given master
- A master that is not 32 bytes is rejected

**KDFs (§5.2, §5.3)**
- `argon2.IDKey` at `t=1, m=64MiB, p=4` completes in 57ms; deterministic for
  the same salt, different for a different salt
- `scrypt.Key` at `N=2^15, r=8, p=1` completes in 125ms
- `scrypt.Key` rejects a non-power-of-two `N` with
  `scrypt: N must be > 1 and a power of 2`

**SSH host key pinning (§8.2)**
- A matching host key is accepted
- A swapped host key is rejected, and the error is a `*knownhosts.KeyError` with
  a non-empty `Want` — which is how §8.2 distinguishes MITM from
  "not enrolled yet"
- An unknown host is rejected (strict; no trust-on-first-use)
- `knownhosts.New` returns `ssh.HostKeyCallback`, i.e.
  `func(hostname string, remote net.Addr, key PublicKey) error` — the `net.Addr`
  argument is easy to miss when adapting an example

**Streaming redaction (§10.2)**
- A secret is fully redacted at every chunk size tested: 1, 2, 3, 7, 16, 64,
  4096 bytes
- A secret split across two `Write` calls is redacted at **every** split
  position from 1 to `len(secret)-1` — this is the case a naive per-chunk
  filter misses
- A secret that is a prefix of a longer secret does not partially mask the
  longer one
- Values shorter than 6 bytes produce **no** redaction (deliberate: they would
  match everywhere)
- The shape regex catches `STRIPE_SECRET_KEY=sk_live_...` when the value was
  never supplied, while leaving `DATABASE_HOST=db` alone
- 2000 bytes of ordinary build output passes through byte-for-byte unchanged
  (no false positives), and `Write` returns the full input length, honouring
  the `io.Writer` contract

**Type-level redaction (§10.2)**
- `String`, `GoString`, and `MarshalJSON` all render `[REDACTED]`
- `Bytes()` still returns the real value, so this is a logging control and not
  an access control — it does not stop a caller that deliberately asks

Not verified by execution: the systemd unit fragments (§4.1), the shell scripts
(§8.4, §9.1–9.3), the SQL in §11.2, and the timing figures on other hardware.
The shell in §9 is the design's own script with the corrections from §9.1 and
§9.2 applied; it should be tested against a real target before being trusted.

---

## 15. Review checklist

Cheap greps and questions for a reviewer, in rough order of value:

1. `grep -rn "InsecureIgnoreHostKey" .` — must return nothing outside tests.
2. `grep -rn "SELECT \*.*project_env\|SELECT \*.*deployment_env"` — must return
   nothing. Write-only depends on explicit column lists.
3. `grep -rn "%v\|%s" internal/domain/` — look for any that could receive a
   secret.
4. Any `Errorf` that takes a value as a verb. Should be none in `internal/domain`.
5. Does the API read path return `value_fingerprint`? It should not.
6. `LoadCredentialEncrypted=` vs `LoadCredential=` — is the weaker one
   deliberate, and is the file it points at safe?
7. `shared/.env` mode: `0600` or `0640`? Consistent with §9.2?
8. Is there one service user for all apps? Then per-app `shared/` isolation is
   not actually in place, and the docs should say so.
9. Are `mkdocs`/docs and the migration comments saying the same thing about
   fingerprints? §12 item 1.
10. `mktemp` or `$$` for the env temp file? `mktemp`.
11. `grep -rn "aadFor\|\.name" internal/secrets/` — is the AAD name ever built
    from a request value rather than the stored row? With `citext` that is a
    data-loss bug, not a style question. §7.2, §12 item 3.
12. `grep -n "citext" db/migrations/` — is `project_env.name` still `citext`
    while it is also AAD? Prefer `text` + `CHECK (name = upper(name))`.

---

## 16. Sources

- `crypto/cipher` AEAD contract — nonce uniqueness, `Overhead()`, `Open` may
  overwrite `dst` on failure:
  https://go.dev/src/crypto/cipher/cipher.go
- `crypto/hkdf` (stdlib): https://pkg.go.dev/crypto/hkdf
- `crypto/pbkdf2` (stdlib, Go 1.24+): https://pkg.go.dev/crypto/pbkdf2 ·
  proposal: https://github.com/golang/go/issues/69488
- `x/crypto` migration/deprecation list, including the packages **not** moving to
  stdlib: https://github.com/golang/go/issues/65269
- `golang.org/x/crypto/scrypt` — `Key`, and the documented
  `N=32768, r=8, p=1` recommendation:
  https://pkg.go.dev/golang.org/x/crypto/scrypt ·
  source: https://go.googlesource.com/crypto/+/master/scrypt/scrypt.go
- `golang.org/x/crypto/argon2` — `IDKey`:
  https://pkg.go.dev/golang.org/x/crypto/argon2
- `filippo.io/age` v1.3.2: https://pkg.go.dev/filippo.io/age
- SOPS module — "should not be used directly", only `decrypt` is stable, and
  the module path change:
  https://pkg.go.dev/github.com/getsops/sops/v3 · https://github.com/getsops/sops
- OpenSSH `authorized_keys(5)` / `sshd_config(5)` — `restrict`, `command=`,
  `from=`, `no-pty`, `no-user-rc`:
  https://man.openbsd.org/sshd_config · https://man.openbsd.org/ssh-keygen
- systemd credentials — `LoadCredential=`, `LoadCredentialEncrypted=`,
  `%C`: https://systemd.io/CREDENTIALS/
- OWASP Password Storage Cheat Sheet — Argon2id parameters, PBKDF2 iteration
  counts: https://cheatsheetseries.owasp.org/cheatsheets/Password_Storage_Cheat_Sheet.html
- OWASP Secrets Management Cheat Sheet — the "keep it simple" principle and
  the case against bespoke secret management:
  https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html
- GitHub Actions — secret masking is lossy exact-substring matching, a
  convenience rather than a control:
  https://docs.github.com/en/actions/security-guides/using-secrets-in-github-actions
- Shipyard's own design, referenced throughout:
  `docs/backend-design.md` (esp. §3.5, §8.1–8.5), `db/migrations/0001_init.up.sql` (§3)
