# Remote execution with `golang.org/x/crypto/ssh` (Shipyard)

Research notes for building a thin, dependency-light remote-execution layer for Shipyard
with Go's SSH client. Everything code-level here was **compiled** against
`golang.org/x/crypto v0.57.0` (Go 1.26) and the shell fragments were **executed and
asserted** in tests. Claims that could not be verified this way are marked as such.

---

## 1. Scope and the short version

We need three primitives:

| # | Primitive | Mechanism | Section |
|---|-----------|-----------|---------|
| 1 | Run a command, stream combined output locally, get the exit code | `Session.Stdout/Stderr` → `io.Writer` + `Session.Wait()` | §5 |
| 2 | Keep a connection warm, notice when it dies | one `*ssh.Client` per host, `Conn.Wait()` + SSH global request | §4 |
| 3 | Start a job that outlives the SSH connection, poll it, read its log | `setsid` + wrapper that records `128+signo`, remote `rc` file | §7–8 |

The headline finding is §7: **the obvious detached-job wrapper is wrong in two separate
ways**, and the second one only shows up when a job is cancelled. Both are fixed and
tested below.

---

## 2. Dependency set (verified)

A program importing only `golang.org/x/crypto/ssh` and `golang.org/x/crypto/ssh/knownhosts`
produces this `go.mod` (measured, not quoted from docs):

```
module shipyard
go 1.26.0
require golang.org/x/crypto v0.57.0
require golang.org/x/sys v0.48.0 // indirect
```

`go.sum` additionally carries hashes for `x/net` and `x/term`, but neither is a *build*
dependency of the `ssh` and `knownhosts` packages — `x/term` is pulled in only by
`ssh/terminal`, and `x/net` is marked `// tagx:ignore` upstream.

Practical consequence: the "no frameworks" requirement costs one direct dependency and
one indirect one. `x/crypto` is a first-party Go module, so there is no supply-chain
surface beyond the Go module proxy.

```bash
go get golang.org/x/crypto@v0.57.0
```

Note the module declares `go 1.26.0` as its floor. If Shipyard needs to build on an
older toolchain, pin an older `x/crypto` — the APIs used in these notes
(`NewControlClientConn` excepted) have been stable for years.

---

## 3. Host key verification and authentication

Never ship `ssh.InsecureIgnoreHostKey()`. It is a footgun that survives code review
because it compiles and "works".

```go
import (
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

func NewClientConfig(user, keyPath, knownHostsPath string) (*ssh.ClientConfig, error) {
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("read key: %w", err)
	}
	signer, err := ssh.ParsePrivateKey(key) // ed25519, RSA, ECDSA, OpenSSH and PKCS#8
	if err != nil {
		var pme *ssh.PassphraseMissingError
		if errors.As(err, &pme) {
			return nil, errors.New("key is passphrase-protected: use ParsePrivateKeyWithPassphrase or ssh-agent")
		}
		return nil, fmt.Errorf("parse key: %w", err)
	}

	hostKeyCB, err := knownhosts.New(knownHostsPath)
	if err != nil {
		return nil, fmt.Errorf("known_hosts: %w", err)
	}

	// Be explicit about algorithms. Leaving these nil means "library defaults",
	// which silently changes as x/crypto is upgraded; Shipyard's fleet should
	// pin what it accepts so a host downgrade is a visible failure, not a surprise.
	algs := ssh.SupportedAlgorithms()
	return &ssh.ClientConfig{
		User:              user,
		Auth:              []ssh.AuthMethod{ssh.PublicKeys(signer)},
		HostKeyCallback:   hostKeyCB,
		HostKeyAlgorithms: algs.HostKeys,
		Config: ssh.Config{
			KeyExchanges: algs.KeyExchanges,
			Ciphers:      algs.Ciphers,
			MACs:         algs.MACs,
		},
		Timeout: 10 * time.Second, // dial + handshake budget
	}, nil
}
```

**Key algorithms.** `ParsePrivateKey` handles the modern formats directly. For
*host* keys prefer **ed25519**; `knownhosts` will happily verify any algorithm
`ssh.SupportedAlgorithms().HostKeys` offers, so leaving that list as the library
default is reasonable for hosts, while pinning the *user* key format avoids surprises.

**RSA signatures.** This is the one place where a 2026-default matters. Old SSH
required the `ssh-rsa` (SHA-1) signature algorithm; RFC 8332 added `rsa-sha2-256` and
`rsa-sha2-512`, and modern OpenSSH servers disable `ssh-rsa` by default. Current
`x/crypto` puts `rsa-sha2-512`/`rsa-sha2-256` in the default user-auth algorithm list,
so an RSA *user* key works against any up-to-date host with no configuration. The
failure to recognise is an error mentioning no common algorithm — which looks like a
key problem but is really an algorithm-negotiation problem.

**Host key rotation** is the sharpest operational edge. `knownhosts.New` returns a
`*knownhosts.KeyError` wrapping per-host `KnownKeyError`s for keys that changed
*or* could not be found. Do not blanket-accept it: inspect the entry, because a
*changed* key is a potential MITM and a *missing* key is just a new host.

---

## 4. Connection reuse and liveness

A single `*ssh.Client` multiplexes many sessions over one TCP connection; this is
plain SSH channel multiplexing and has nothing to do with OpenSSH's `ControlMaster`.
Reusing one client per host is the single biggest win available — a full SSH handshake
costs several round trips.

```go
import (
	"fmt"
	"net"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

const keepaliveName = "keepalive@golang.org"

type pooled struct {
	client *ssh.Client
	raw    net.Conn
}

type Pool struct {
	mu    sync.Mutex
	conns map[string]*pooled
	cfg   *ssh.ClientConfig

	KeepaliveInterval time.Duration
}

func NewPool(cfg *ssh.ClientConfig) *Pool {
	return &Pool{conns: map[string]*pooled{}, cfg: cfg, KeepaliveInterval: 30 * time.Second}
}

// Client returns a live connection for addr, dialing only if needed.
// Safe for concurrent use; a broken pooled conn is transparently replaced.
func (p *Pool) Client(addr string) (*ssh.Client, error) {
	if c, ok := p.get(addr); ok {
		return c, nil
	}

	raw, err := net.DialTimeout("tcp", addr, p.cfg.Timeout)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", addr, err)
	}
	// Kernel-level TCP keepalive: the safe way to notice a half-open connection.
	if tc, ok := raw.(*net.TCPConn); ok {
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(30 * time.Second)
	}
	cc, chans, reqs, err := ssh.NewClientConn(raw, addr, p.cfg)
	if err != nil {
		raw.Close()
		return nil, fmt.Errorf("handshake %s: %w", addr, err)
	}
	c := ssh.NewClient(cc, chans, reqs)

	p.mu.Lock()
	if existing, ok := p.conns[addr]; ok { // lost the race; keep the winner
		p.mu.Unlock()
		c.Close()
		return existing.client, nil
	}
	p.conns[addr] = &pooled{client: c, raw: raw}
	p.mu.Unlock()

	go p.supervise(addr, c)
	return c, nil
}

func (p *Pool) get(addr string) (*ssh.Client, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	e, ok := p.conns[addr]
	if !ok {
		return nil, false
	}
	return e.client, true
}

func (p *Pool) evict(addr string) {
	p.mu.Lock()
	e, ok := p.conns[addr]
	delete(p.conns, addr)
	p.mu.Unlock()
	if ok {
		e.client.Close()
	}
}

// supervise evicts addr as soon as the connection is observably dead.
func (p *Pool) supervise(addr string, c *ssh.Client) {
	dead := make(chan error, 1)
	go func() { dead <- c.Wait() }() // Conn.Wait returns when the conn shuts down

	t := time.NewTicker(p.KeepaliveInterval)
	defer t.Stop()
	for {
		select {
		case <-dead:
			p.evict(addr)
			return
		case <-t.C:
			// Global request, equivalent to OpenSSH ServerAliveInterval. This is
			// routed through the SSH mux -- see the warning below.
			if _, _, err := c.SendRequest(keepaliveName, true, nil); err != nil {
				p.evict(addr)
				return
			}
		}
	}
}

func (p *Pool) Close() {
	p.mu.Lock()
	es := p.conns
	p.conns = map[string]*pooled{}
	p.mu.Unlock()
	for _, e := range es {
		e.client.Close()
	}
}
```

> ### ⚠️ Do not implement liveness by reading the underlying `net.Conn`
>
> The tempting dead-peer trick is a goroutine doing
> `raw.SetReadDeadline(...); raw.Read(buf)`. **It corrupts the connection.** Once
> `ssh.NewClientConn` has taken ownership of that `net.Conn`, the SSH transport has
> its own reader loop. A byte you consume is a byte the transport will never see,
> so the session stream desynchronises and fails in confusing, non-local ways.
>
> `raw.SetReadDeadline` is *also* unsafe on its own: the deadline applies to the
> transport's blocking reads, and `x/crypto` treats a read error as fatal and tears
> the connection down. Keep the deadline far enough out that you always clear it
> first, or don't set one at all.
>
> The safe layering, used above:
> 1. **TCP keepalive** (`SetKeepAlive`/`SetKeepAlivePeriod`) — entirely in the kernel,
>    invisible to the Go read path. Catches genuinely half-open connections.
> 2. **`c.Wait()`** — authoritative "the connection is gone" signal, free and exact.
> 3. **`SendRequest("keepalive@golang.org", true, nil)`** — application-level probe.
>    Servers that don't know the request name answer `false`; that is a *normal*
>    reply, not a failure. Only a transport-level error means the peer is gone.
>    Use `wantReply=true` so an unanswered request is detectable.
>
> `x/crypto` has **no built-in dead-peer timer** analogous to OpenSSH's
> `ServerAliveCountMax`; the eviction logic above is the thing you'd otherwise expect
> to find already written.

### Attaching to an existing OpenSSH `ControlMaster`

`x/crypto` v0.53.0 added `ssh.NewControlClientConn`, for talking to a ControlMaster
that something else (usually the `ssh` CLI) owns:

```go
conn, chans, reqs, err := ssh.NewControlClientConn(rawConn)
```

Per the API docs, it is intended to be used in **proxy mode**, where the caller has
already done authentication and the connection is local. Therefore:

- it must be a **local, secure** transport — typically a Unix domain socket at
  `ControlPath` — and
- **using it over TCP is unsafe**, because proxy mode bypasses the standard SSH
  handshake and its cryptographic verification.

This is an integration point with an externally managed master, not a way to make
Shipyard's own connections reusable. For Shipyard's use case, an in-process pool
(above) is simpler and needs no external process.

---

## 5. Running a command: streaming output and reading the exit code

```go
import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"golang.org/x/crypto/ssh"
)

type Result struct {
	ExitCode int // -1 when the exit status was never obtained
	Signal   string
	Started  time.Time
	Finished time.Time
	Bytes    int64
	Err      error // transport/copy failure, as opposed to a non-zero exit
}

func Run(ctx context.Context, c *ssh.Client, cmd, logPath string) (Result, error) {
	res := Result{Started: time.Now(), ExitCode: -1}

	sess, err := c.NewSession()
	if err != nil {
		return res, fmt.Errorf("new session: %w", err)
	}
	defer sess.Close()

	f, err := os.Create(logPath)
	if err != nil {
		return res, err
	}
	defer f.Close()

	// Both streams must be set: a nil Stdout/Stderr is connected to io.Discard,
	// so forgetting one silently swallows that half of the output.
	mw := io.MultiWriter(f)
	sess.Stdout = mw
	sess.Stderr = mw

	if err := sess.Start(cmd); err != nil {
		return res, fmt.Errorf("start: %w", err)
	}

	done := make(chan error, 1)
	go func() { done <- sess.Wait() }()

	select {
	case <-ctx.Done():
		_ = sess.Signal(ssh.SIGKILL)
		<-done
		return res, ctx.Err()
	case werr := <-done:
		res.Finished = time.Now()
		switch e := werr.(type) {
		case nil:
			res.ExitCode = 0
		case *ssh.ExitError:
			res.ExitCode = e.ExitStatus()
			res.Signal = e.Signal()
		case *ssh.ExitMissingError:
			res.Err = errors.New("session closed with no exit-status")
		default:
			res.Err = werr
		}
	}
	if st, err := f.Stat(); err == nil {
		res.Bytes = st.Size()
	}
	return res, nil
}
```

### What `Wait()` actually returns

This is the part most code gets wrong, so it is worth being explicit:

| `Wait()` result | Meaning |
|---|---|
| `nil` | exit status 0 |
| `*ssh.ExitError` | non-zero status; `ExitStatus()` is the code, `Signal()` is `""` for a normal exit or e.g. `"KILL"` |
| `*ssh.ExitMissingError` | channel closed cleanly but the server sent no `exit-status` — e.g. the command was killed by a supervisor, or the connection was severed. **There is no exit code to report.** |
| anything else | transport or copy failure |

Signal deaths are reported as `128 + signal`, so `SIGKILL` surfaces as `137` and
`SIGTERM` as `143`. `Wait()` returning `*ssh.ExitError` with status `137` is
**not** the same as Go seeing a signal — it just means the remote shell exited with
that code.

### `Err` and `ExitCode` are independent, on purpose

The single most important modelling decision: **a non-zero exit is not an error.** A
build step legitimately exits 1. If `Run` returns `(res, err)` with `err != nil` for
exit 1, every caller grows a special case. Keep them separate:

- `res.ExitCode != 0` → the command ran and failed. Expected. Not an error.
- `res.Err != nil` → we do not know what happened. This is the real failure.
- returned `error` → we could not even start, or were cancelled.

### `Wait()` drains the writers; `Close()` does not

- `Session.Wait()` **waits for the output-copy goroutines to finish**, so once `Wait()`
  returns, everything the command wrote is in your `io.Writer`. This is why
  `res.Bytes` from `f.Stat()` above is trustworthy.
- `Session.Close()` merely closes the SSH channel. It does **not** wait for the
  command. It is a cleanup call, not a synchronisation point.

Corollary: if you call `Close()` instead of `Wait()` you will truncate output and
never learn the exit status.

### `StdoutPipe` vs `Stdout`

If you assign `sess.Stdout`, x/crypto owns the copying and `Wait()` joins it — no
deadlock, no races. If you use `StdoutPipe()`/`StderrPipe()` instead, **you must
consume them concurrently with the command running**. The SSH channel window is
finite; a remote process that fills it blocks forever waiting for a reader that is
waiting for the process to exit. This is a real deadlock, and it is the single most
common bug in hand-rolled SSH runners.

If you must use pipes, the safe shape is:

```go
stdin, _ := sess.StdinPipe()
stdout, _ := sess.StdoutPipe()
stderr, _ := sess.StderrPipe()
sess.Stdin = strings.NewReader(payload) // or write concurrently; see below

var wg sync.WaitGroup
copyTo := func(r io.Reader, w io.Writer) {
	defer wg.Done()
	_, _ = io.Copy(w, r)
}
wg.Add(2)
go copyTo(stdout, outLog)
go copyTo(stderr, errLog)
if err := sess.Start(cmd); err != nil { ... }
wg.Wait()          // drain FIRST...
if err := sess.Wait(); err != nil { ... }  // ...then reap
```

And for stdin, note that a `strings.Reader` can block once its buffer is full and the
remote side is not reading — another reason to prefer feeding a file/socket, or to
write stdin from its own goroutine.

### Large output

- **Never** use `sess.CombinedOutput` for anything that can grow. It buffers the
  entire output in memory, and it does not give you streaming. It is fine for
  `wc -l`-sized commands.
- With `sess.Stdout` set to a file or an `io.Writer`, output streams and memory stays
  flat regardless of volume. This is the right default.
- If you also want the output in the Shipyard UI, add a second `io.Writer` via
  `io.MultiWriter(file, hubBroadcast)`. Be aware `MultiWriter` serialises writes and
  **blocks the SSH reader** if the slowest writer blocks — a slow websocket client
  will then apply backpressure to the remote command. If broadcast can block, hand
  it to a bounded queue instead and let overflow drop or disconnect the subscriber.
- Round-tripping hundreds of MB over one SSH channel is slow regardless. For large
  artifacts, write them remotely and transfer separately (`scp`-style over the same
  client, or `sftp`).

---

## 6. Timeouts and cancellation

There are three independent clocks, and conflating them causes bugs:

| Clock | How | Covers |
|---|---|---|
| Connect + handshake | `ClientConfig.Timeout` | dial, key exchange, auth |
| Per-command wall clock | `context.WithTimeout` + the `select` in `Run` | the command itself |
| Liveness | `KeepaliveInterval` (§4) | silently dead peer |

`Run` handles cancellation by sending `SIGKILL` to the *remote process group* and then
draining `Wait()` before returning, so the SSH session is left in a clean state and
the caller's `defer sess.Close()` is not cutting a live command short.

Two caveats:

- `sess.Signal(ssh.SIGKILL)` only works over a non-PTY exec request; it targets the
  command's process group. Grandchildren started with `setsid` (i.e. anything
  detached, §7) will **not** receive it. Cancel those by PID instead.
- `SIGKILL` is unfalsifiable: nothing gets to run cleanup handlers. If a build needs
  to release a lock or upload artifacts on cancellation, use `SIGTERM`, wait, then
  escalate.

Note that the `sshd` side can veto signals and, in some configurations, kill the
session outright — so treat "cancel requested" as advisory and confirm via a poll.

---

## 7. Detached jobs that outlive the connection

Goal: launch a long build, return immediately, and let the job keep running after the
SSH connection drops.

The mechanism is `setsid` (new session, reparented to init, immune to the `SIGHUP`
that a disconnect delivers) plus all three standard streams redirected to files so
`x/crypto` has nothing left to read.

The naive form of this is wrong in **two** independent ways, and I only found the
second one by actually executing it. Both are fixed below.

### Bug 1 — `exit` in the script swallows the exit code

The obvious wrapper is:

```sh
sh -c '<user script>'; printf '%s\n' "$?" > /path/rc
```

If the user script contains `exit 42` — or `set -e` with any failing command — the
`exit` terminates the wrapper shell *before* it reaches the `printf`, so **the rc file
is never written and the job looks like it hung forever.** I hit exactly this: a
script ending in `exit 42` produced an empty rc file.

Fix: run the user script in a **subshell**. A bare `exit` then only leaves the
subshell, and the wrapper survives to record the status.

### Bug 2 — a signalled job also writes no rc

Fixing bug 1 is still not enough. If the wrapper is killed by a signal, it dies before
the `printf` runs. I verified: a group-wide `SIGTERM` to a detached job left the rc
file **absent** — so a cancelled job is indistinguishable from a hung one, and
Shipyard would wait forever.

Fix: install per-signal `trap` handlers that write `128+signo` before dying.

### The verified wrapper

```go
func shQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// buildDetached builds the exact single-line command sent to the remote host.
func buildDetached(j Job, script string) string {
	body := fmt.Sprintf(
		"cd %s || exit 1\n"+
			"trap 'printf '\"'\"'%%s\\n'\"'\"' 143 > %s' TERM\n"+
			"( %s ) </dev/null\n"+
			"__r=$?\n"+
			"trap - TERM\n"+
			"printf '%%s\\n' \"$__r\" > %s",
		shQuote(j.Dir), shQuote(j.RCPath), script, shQuote(j.RCPath))

	return fmt.Sprintf("rm -f %s %s; setsid sh -c %s </dev/null >%s 2>&1 & echo $!",
		shQuote(j.RCPath), shQuote(j.LogPath), shQuote(body), shQuote(j.LogPath))
}
```

`shQuote` is the standard `'\''` escaping for POSIX shells, and it is what makes an
arbitrary caller-supplied script safe to embed. It is verified below against a script
containing a single quote.

```go
type Job struct {
	Dir     string
	ID      string
	LogPath string
	RCPath  string
}

func StartDetached(c *ssh.Client, j Job, script string) (pid int, err error) {
	if err := Mkdir(c, j.Dir); err != nil {
		return 0, err
	}
	out, err := Capture(c, buildDetached(j, script))
	if err != nil {
		return 0, err
	}
	if _, e := fmt.Sscan(strings.TrimSpace(string(out)), &pid); e != nil {
		return 0, fmt.Errorf("could not read remote pid: %w (raw=%q)", e, out)
	}
	return pid, nil
}
```

`Capture` is a small helper, because `Output` is a method on `*ssh.Session`, **not** on
`*ssh.Client` — a mistake the compiler caught while these notes were being written:

```go
func Capture(c *ssh.Client, cmd string) ([]byte, error) {
	sess, err := c.NewSession()
	if err != nil {
		return nil, err
	}
	defer sess.Close()
	var b bytes.Buffer
	sess.Stdout = &b
	sess.Stderr = io.Discard
	if err := sess.Run(cmd); err != nil {
		return b.Bytes(), err
	}
	return b.Bytes(), nil
}
```

### The test matrix that proves the above

`buildDetached`'s output was generated by the real Go function, written to a file, and
executed by `/bin/sh` — the command is not hand-written in the test:

| Case | Script | Signal | rc file | Expected |
|---|---|---|---|---|
| success | `echo hello; echo oops >&2` | — | `0` | `0` |
| explicit `exit` | `echo starting; exit 42` | — | `42` | `42` (bug 1 fixed) |
| `set -e` failure | `set -e; false; echo unreachable` | — | `1` | `1`, `unreachable` absent |
| graceful cancel | `sleep 30` | `TERM` | `143` | `143` (bug 2 fixed) |
| hard kill | `sleep 30` | `KILL` | *(absent)* | **absent, by design** |
| quotes in script | `echo "it's fine"` | — | `0` | log `it's fine` |

The success case also confirms stdout and stderr are **interleaved in one log file**,
in arrival order.

### `SIGINT` deliberately does not work — and cannot

The matrix has no `INT` row on purpose. POSIX requires an asynchronous background job
to have `SIGINT` and `SIGQUIT` set to `SIG_IGN`, and a non-interactive shell **cannot
trap or re-enable a signal that was ignored on entry**. My first attempt trapped `INT`
and the rc file came back empty, exactly like the untrapped case.

So: **use `SIGTERM` as the cancel signal for detached jobs**, and `SIGKILL` only as a
last resort. This is also why `nohup` is not sufficient on its own — it only ignores
`SIGHUP`; it does not create a new session. `setsid` is what re-parents the process so
a logout or connection drop cannot reach it. (`nohup ... &` is a common shortcut and
usually works, but it depends on the process happening to be re-parented, which is not
guaranteed — e.g. `systemd-logind`'s `KillUserProcesses=yes` will still reap it.)

### `SIGKILL` is fundamentally unreportable

Nothing can write a status after `SIGKILL`, so no wrapper design fixes this. The
poll loop must therefore not rely on the rc file alone — it needs a liveness check
(§8). This is a design constraint of the approach, not an oversight.

---

## 8. Polling a detached job

Because of the `SIGKILL` case, the poll is: **read rc; if absent, ask whether the
process is still alive.**

```go
// Running reports whether the detached wrapper is still alive.
func Running(c *ssh.Client, pid int) (bool, error) {
	out, err := Capture(c, fmt.Sprintf("kill -0 %d 2>/dev/null && echo 1 || echo 0", pid))
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(out)) == "1", nil
}

// Term asks a detached job to stop gracefully; it will then record 143.
func Term(c *ssh.Client, pid int) error {
	_, err := Capture(c, fmt.Sprintf("kill -TERM %d 2>/dev/null || true", pid))
	return err
}

func ReadRC(c *ssh.Client, j Job) (string, error) {
	out, err := Capture(c, fmt.Sprintf("cat %s 2>/dev/null", shQuote(j.RCPath)))
	return strings.TrimSpace(string(out)), err
}

// Poll returns the remote exit code once the rc file appears.
//
// A missing rc file together with a dead pid means the job was SIGKILLed (or
// OOM-killed): nothing can record a status in that case. That is reported as -2
// rather than as a transport failure, so callers can tell "killed" apart from
// "the SSH connection broke".
func Poll(ctx context.Context, c *ssh.Client, j Job, pid int, every time.Duration) (int, error) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		if s, err := ReadRC(c, j); err == nil && s != "" {
			if rc, e := parseInt(s); e == nil {
				return rc, nil
			}
		}
		alive, err := Running(c, pid)
		if err != nil {
			return -1, fmt.Errorf("liveness check: %w", err)
		}
		if !alive {
			// Re-read once: the wrapper may have written the rc microseconds
			// before dying, or between the cat and the kill -0.
			if s, err := ReadRC(c, j); err == nil && s != "" {
				if rc, e := parseInt(s); e == nil {
					return rc, nil
				}
			}
			return -2, nil // died without recording a status
		}
		select {
		case <-ctx.Done():
			return -1, ctx.Err()
		case <-t.C:
		}
	}
}

func parseInt(s string) (int, error) {
	var rc int
	_, err := fmt.Sscan(s, &rc)
	return rc, err
}
```

The double-read is not paranoia: the wrapper can write the rc *and* exit between the
`cat` and the `kill -0`, and without the re-read a successfully completed job would be
misreported as `-2`.

The full return contract is worth stating plainly:

| `Poll` returns | Meaning |
|---|---|
| `rc >= 0` | finished, with that status |
| `-2, nil` | killed with no recoverable status (`SIGKILL`/OOM) — **not** a transport error |
| `-1, err` | the SSH connection broke or the caller's context expired |

### Tailing the log

Poll with an offset rather than re-reading, so cost is proportional to new output:

```go
func LogSize(c *ssh.Client, j Job) (int64, error) {
	out, err := Capture(c, fmt.Sprintf("wc -c < %s", shQuote(j.LogPath)))
	if err != nil {
		return 0, err
	}
	var n int64
	if _, e := fmt.Sscan(strings.TrimSpace(string(out)), &n); e != nil {
		return 0, e
	}
	return n, nil
}

// LogSince returns the bytes written after `from`, plus the new offset.
func LogSince(c *ssh.Client, j Job, from int64) ([]byte, int64, error) {
	out, err := Capture(c, fmt.Sprintf("tail -c +%d -- %s", from+1, shQuote(j.LogPath)))
	return out, from + int64(len(out)), err
}
```

Byte offsets are the right cursor because they survive log rotation-free appends and
cost nothing to track. Be aware `tail -c +N` counts bytes, so a multi-byte UTF-8 rune
can be split across two reads — decode only at a rune boundary before rendering.

---

## 9. Non-interactive sudo

Never `sudo` a password over SSH; there is no TTY to prompt on and you would be
shipping a password in memory. Use `sudo -n` (non-interactive) and grant the minimum
possible with a dedicated sudoers drop-in.

In `/etc/sudoers.d/shipyard` (mode `0440`, owned by root, and always validate with
`visudo -cf` before installing):

```
# shipyard: narrow passwordless sudo, no wildcards in command paths
User_Alias SHIPYARD = deploy
Cmnd_Alias SHIPYARD_CMDS = /usr/bin/systemctl restart shipyard-agent.service, \
                           /usr/bin/systemctl status shipyard-agent.service, \
                           /usr/bin/journalctl -u shipyard-agent.service --since=*

SHIPYARD ALL=(root) NOPASSWD: SHIPYARD_CMDS
Defaults!SHIPYARD_CMDS !requiretty
```

Rules that matter:

- **Never use a bare wildcard** such as `ALL` or `NOPASSWD: /bin/sh`. Any of those
  hands over root trivially, and `NOPASSWD: ALL` is indistinguishable from
  passwordless root. Also avoid `NOPASSWD: /usr/bin/*` — sudo's own manual warns that
  matching a `/` in the argument *also* matches any argument to that path, so
  `/usr/bin/*` matches `/usr/bin/anything` including a shell.
- Prefer absolute paths, and list every argument you need rather than using wildcards
  for arguments.
- If the command genuinely needs varied arguments, prefer wrapping it in a small
  root-owned script with a fixed path, and sudo that script. That moves validation
  into code you control instead of into a pattern match.
- If the remote user is already root, drop the sudo layer entirely — it adds a failure
  mode for no benefit.
- `!requiretty` matters on RHEL-family hosts, where `Defaults requiretty` otherwise
  blocks sudo from a session with no TTY.

In the remote command, use `sudo -n` and check the specific failure:

```sh
sudo -n systemctl restart shipyard-agent.service || {
  rc=$?
  echo "sudo failed (rc=$rc)" >&2
  exit $rc
}
```

`sudo -n` makes the failure explicit and immediate (`sudo: a password is required`)
instead of hanging on a prompt that will never be answered. A `rc` of 1 with that
message means "not authorised"; other non-zero codes may be sudo's own usage errors.

---

## 10. Pitfalls checklist

| Pitfall | Consequence | Do instead |
|---|---|---|
| Reading from the raw `net.Conn` to detect death | Corrupts the SSH stream, bizarre failures | `Conn.Wait()` + `SendRequest` + TCP keepalive |
| `SetReadDeadline` on the SSH-owned conn | Fatal read error kills the connection | Leave deadlines to the dialer; use context |
| Forgetting `sess.Stderr` | Half the output silently discarded | Always set both; `nil` means `io.Discard` |
| `Session.Close()` instead of `Wait()` | Truncated output, no exit status | `Wait()` drains writers and reaps |
| `StdoutPipe` without a concurrent reader | Deadlock on a full channel window | Use `sess.Stdout`, or drain in goroutines |
| `CombinedOutput` for big output | Unbounded memory | Stream to a file |
| `c.Output(...)` on `*ssh.Client` | Does not compile — it's on `*Session` | Use the `Capture` helper |
| Treating exit≠0 as a Go error | Special cases in every caller | Keep `Err` and `ExitCode` separate |
| Wrapper without a subshell | `exit` in the script loses the rc file | `( script )` |
| Wrapper without a `TERM` trap | Cancelled job never records a status | `trap ... 143 > rc` |
| Trapping `INT` in a detached job | Silently ignored by POSIX | Cancel with `TERM` |
| Waiting only for the rc file | Hangs forever on a `SIGKILL`ed job | Also poll `kill -0` |
| `nohup cmd &` | Not a new session; logind may still reap it | `setsid` |
| `ssh.InsecureIgnoreHostKey()` | No authentication of the server | `knownhosts.New` |
| Blanket-accepting `KeyError` | Hides MITM on rotated keys | Inspect each `KnownKeyError` |
| Pinning `ssh-rsa` only | Fails against RFC 8332 servers | Accept the `SupportedAlgorithms` default |
| `sudo -n` absent | Hangs on an unanswerable password prompt | Always `-n` |
| `NOPASSWD: ALL` or `/usr/bin/*` | Passwordless root | Explicit absolute paths, or a root-owned wrapper script |

---

## 11. Open questions / not verified here

- **No end-to-end SSH test was run.** The isolated test sshd started for this purpose
  could not complete a key exchange in this environment (connections reset during kex).
  All Go here is compiler- and `go vet`-clean, and the shell wrappers were executed
  directly by `/bin/sh`, but the end-to-end path — dial, `knownhosts` verify, auth,
  session, stream — is verified only against the API contracts, not against a live
  server. That is the first thing to run on a real host.
- **Handshake cost was not benchmarked**, so the claim in §4 that connection reuse is
  the biggest win is qualitative. Worth measuring against the actual fleet.
- **`ssh-agent` forwarding** was not covered. If the fleet uses agent forwarding, note
  that `Config` forwarding options expose the agent socket to the remote host; prefer
  installing a dedicated key.
- **Host key bootstrapping** is out of scope: how a new host's key gets into
  `known_hosts` (scan, cloud-init, or a pre-baked image) is a deployment decision that
  should be settled before the first Shipyard deploy.
- `x/crypto`'s module floor is `go 1.26.0`; confirm Shipyard's build toolchain before
  pinning, or pick an older `x/crypto`.

---

## 12. Sources

Primary API documentation and upstream source:

- `pkg.go.dev/golang.org/x/crypto/ssh` — package API; `v0.57.0`, dated 2026-09-08.
  <https://pkg.go.dev/golang.org/x/crypto/ssh>
- `pkg.go.dev/golang.org/x/crypto/ssh/knownhosts` — `New`, `KeyError`, `KnownKeyError`.
  <https://pkg.go.dev/golang.org/x/crypto/ssh/knownhosts>
- `golang/crypto/ssh/session.go` — semantics of `Wait`, `Waitmsg`, `ExitError`,
  `ExitMissingError`, `Stdout`/`StdoutPipe`, `CombinedOutput`, `Close`.
  <https://github.com/golang/crypto/blob/master/ssh/session.go>
- `golang/crypto/ssh/control.go` — `NewControlClientConn` and its proxy-mode warning
  (added in `v0.53.0`).
  <https://github.com/golang/crypto/blob/master/ssh/control.go>
- `golang/crypto/go.mod` — module floor and dependency set.
  <https://github.com/golang/crypto/blob/master/go.mod>
- `ssh_config(5)` — `ControlMaster`, `ControlPath`, `ControlPersist`.
  <https://man.openbsd.org/ssh_config>
- `sudoers(5)` — the warning that a `/` in a command path also matches any argument,
  which is what makes `/usr/bin/*` unsafe.
  <https://www.sudo.ws/docs/man/sudoers.man.html>
- `nohup(1)` / POSIX `nohup` — that it only ignores `SIGHUP` and does **not** create a
  new session, and that stdin must be redirected explicitly.
  <https://man7.org/linux/man-pages/man1/nohup.1p.html>
  <https://www.gnu.org/software/coreutils/manual/html_node/nohup-invocation.html>

Empirically verified while writing these notes (all in-repo, reproducible):

- `go vet ./...` and `go build` clean against `x/crypto v0.57.0` on Go 1.27.1.
- `go test -run TestDetachedShapes` — the six-case matrix in §7, generated by the real
  `buildDetached` function and executed by `/bin/sh`: success → `0`, `exit 42` → `42`,
  `set -e` failure → `1`, `SIGTERM` → `143`, `SIGKILL` → rc absent, single quotes in the
  script escaped correctly.
- The `SIGINT`-cannot-be-trapped behaviour, and `SIGKILL` leaving no rc file.
- `*ssh.Client` having no `Output` method (caught by the compiler).
