# Shipyard: SSE log streaming + REST control-plane semantics

Research notes, current as of 2026. Scope: a **Go** `net/http` control-plane server that
streams build/deploy logs over Server-Sent Events (SSE) and exposes REST endpoints for
build state, plus a **Next.js/React** client that consumes the stream. Every HTTP field
name, status code, and browser behaviour below is sourced; the Go and TypeScript code is
authored guidance built on that behaviour, not copied from the sources.

> Writer's note: the code blocks are written to be directly adaptable into Shipyard. The
> "production gotchas" callouts are the parts that actually cause incidents — do not drop them.

---

## 0. TL;DR decision set

| Concern | Decision | Why |
|---|---|---|
| Stream transport | SSE (`text/event-stream`), not WebSocket | Unidirectional logs, native browser reconnect, works over plain HTTP, trivial LB/proxy story. |
| Wire headers | `Content-Type: text/event-stream`, `Cache-Control: no-cache, no-transform`, `Connection: keep-alive`, `X-Accel-Buffering: no` | Required for parsers; the rest defeat proxy/CDN buffering and connection coalescing. |
| Producer model | In-process `Hub`: monotonic event IDs + fixed replay ring + per-subscriber buffered channel | Fans out without blocking the publisher; supports gap-free resume. |
| Resume cursor | Client `?after=<seq>` on first connect; server prefers `Last-Event-ID` on reconnect | `EventSource` sends `Last-Event-ID` only on its own auto-reconnect, never across a page reload. |
| Flush | `http.NewResponseController(w).Flush()` after every event + on keepalive | Without explicit flush Go/`net/http` buffers and nothing streams. |
| Slow clients | Per-subscriber bounded channel; on full buffer **evict and force reconnect** (or drop for broadcast) | One stalled client must never stall the publisher or other clients. |
| Reverse proxy | HTTP/2 (or explicit `proxy_read_timeout` / no buffering) | HTTP/1.1 caps browsers at ~6 connections per origin; buffering holds events until buffer fills. |
| Client auth | Same-origin Next.js Route Handler proxies to Go and injects `Authorization` | Native `EventSource` cannot set custom request headers. |
| Conditional GET | Strong quoted `ETag` + `If-None-Match` → `304` | Cheap polling / cache revalidation of build state. |
| Optimistic concurrency | `If-Match: "<rev>"` → **`412`** on mismatch | RFC 9110 distinction: precondition failure ≠ business conflict. |
| Idempotent POST | `Idempotency-Key` stored with request fingerprint + original response | Retries of `POST /builds` must not create duplicate builds. |
| Status codes | see §7 table | Keep `304` / `409` / `412` / `425` semantically distinct. |

---

## 1. SSE wire format and required response headers

SSE is a one-way HTTP response whose body is a stream of UTF-8 text events. Each event is a
group of `field: value` lines terminated by a **blank line** (`\n\n`). Fields ([WHATWG HTML
§9.2](https://html.spec.whatwg.org/multipage/server-sent-events.html#server-sent-events)):

- `event:` — event name; absent ⇒ the generic `message` event.
- `data:` — one line of payload. **A payload containing newlines must be split into one
  `data:` line per line**; the client rejoins them with `\n`. Do not try to embed a raw
  newline in a single `data:` line.
- `id:` — sets the EventSource's *last event ID string*. Ignored if it contains NUL.
- `retry:` — reconnection delay hint in **integer milliseconds**.
- A line starting with `:` is a **comment** (used for keepalives), ignored by clients.

Minimal correct response headers:

```http
HTTP/1.1 200 OK
Content-Type: text/event-stream; charset=utf-8
Cache-Control: no-cache, no-transform
Connection: keep-alive
X-Accel-Buffering: no
```

- `text/event-stream` is mandatory; a wrong/missing content type makes the browser error out
  and reconnect forever ([MDN, Using server-sent events](https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events)).
- `Cache-Control: no-cache` stops response caching; `no-transform` additionally tells proxies
  not to compress/rewrite the stream (compression can hold bytes in a buffer).
- `Connection: keep-alive` is HTTP/1.1 noise but is harmless and widely emitted; **do not**
  set it under HTTP/2 (it is a forbidden header there).
- `X-Accel-Buffering: no` is the **nginx** de-facto directive to disable proxy buffering for
  this response ([nginx proxy module](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)).
  On nginx you can also set `proxy_buffering off;` server-wide, but per-response is safer.

> **Gotcha 1 — buffering is the #1 "SSE doesn't work in prod but works locally" cause.**
> nginx buffers proxied responses by default, so events sit in nginx's buffer and arrive in
> bursts (or only when the connection closes). Fix with `X-Accel-Buffering: no` **and**
> confirm no CDN / API gateway in front is buffering. Cloudflare, for example, will buffer
> unless the response is streamed without compression and is not subject to its own buffering
> heuristics.
>
> **Gotcha 2 — compression.** gzip/br middleware (including `compress` in Go or Next) buffers
> output, defeating streaming. Ensure the SSE route opts out of compression, or flush after
> each event at the compression layer too.

---

## 2. Go server: handler + hub with gap-free replay

The idiomatic Go shape is a central `Hub` that owns a registry of subscriber channels and a
replay ring, guarded by a mutex, plus non-blocking fan-out. This mirrors the widely used
community pattern (see §8 sources) and the advice that a slow client must not block the
broadcast loop.

### 2.1 Core types

```go
package sse

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Event is one SSE frame. ID is monotonic and used for resumption.
type Event struct {
	ID   uint64
	Type string // SSE "event:" field; "" => generic message event
	Data []byte // raw payload bytes (e.g. a JSON log line)
}

type subscriber struct {
	ch chan Event
}

type Hub struct {
	mu       sync.Mutex
	subs     map[uint64]*subscriber
	nextSub  uint64
	nextID   uint64
	ring     []Event // fixed-size replay ring
	ringSize int
	done     chan struct{}
	closed   bool
}

func NewHub(ringSize int) *Hub {
	if ringSize < 1 {
		ringSize = 512
	}
	return &Hub{
		subs:     make(map[uint64]*subscriber),
		ringSize: ringSize,
		done:     make(chan struct{}),
	}
}
```

### 2.2 Non-blocking publish

```go
// Publish appends to the replay ring and fans out. It never blocks on a
// subscriber: a full per-subscriber buffer means that client is slow, and the
// broadcast proceeds without it.
func (h *Hub) Publish(typ string, data []byte) (uint64, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return 0, errors.New("hub closed")
	}
	h.nextID++
	ev := Event{ID: h.nextID, Type: typ, Data: data}
	h.ring = append(h.ring, ev)
	if len(h.ring) > h.ringSize {
		h.ring = h.ring[len(h.ring)-h.ringSize:]
	}
	for _, s := range h.subs {
		select {
		case s.ch <- ev:
		default:
			// Slow-consumer policy. For a shared broadcast (log tail seen by
			// many) dropping is right: the next event supersedes it and the
			// client can re-fetch state. For must-deliver per-recipient
			// streams, close s.ch instead so the client reconnects and
			// re-fetches authoritative state (see §2.5).
		}
	}
	return ev.ID, nil
}
```

### 2.3 Subscribe + replay + stream

```go
// backlog returns ring events strictly newer than lastID. Caller holds h.mu.
func (h *Hub) backlog(lastID uint64) []Event {
	if lastID == 0 {
		return nil // fresh client: don't replay ancient history
	}
	for i, ev := range h.ring {
		if ev.ID > lastID {
			out := make([]Event, len(h.ring)-i)
			copy(out, h.ring[i:])
			return out
		}
	}
	return nil
}

// Serve streams one client. lastID is the resume cursor (0 = from now).
func (h *Hub) Serve(ctx context.Context, w http.ResponseWriter, lastID uint64) error {
	rc := http.NewResponseController(w)

	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)

	// Tell the browser how long to back off before reconnecting (ms).
	if _, err := io.WriteString(w, "retry: 3000\n\n"); err != nil {
		return err
	}
	if err := rc.Flush(); err != nil {
		return err
	}

	// Register and snapshot the replay backlog under ONE lock so replayed
	// frames and the live channel are gap-free and overlap-free.
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return errors.New("hub closed")
	}
	backlog := h.backlog(lastID)
	h.nextSub++
	id := h.nextSub
	sub := &subscriber{ch: make(chan Event, 256)}
	h.subs[id] = sub
	h.mu.Unlock()

	defer func() {
		h.mu.Lock()
		delete(h.subs, id)
		h.mu.Unlock()
	}()

	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	for _, ev := range backlog {
		if err := writeEvent(w, ev); err != nil {
			return err
		}
	}
	if err := rc.Flush(); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-h.done:
			return nil
		case ev := <-sub.ch:
			if err := writeEvent(w, ev); err != nil {
				return err
			}
			if err := rc.Flush(); err != nil {
				return err
			}
		case <-keepalive.C:
			// SSE comment: keeps idle connections alive through proxies whose
			// read timeout would otherwise reap them.
			if _, err := io.WriteString(w, ": keepalive\n\n"); err != nil {
				return err
			}
			if err := rc.Flush(); err != nil {
				return err
			}
		}
	}
}

// writeEvent encodes one SSE frame, splitting multi-line payloads correctly.
func writeEvent(w io.Writer, ev Event) error {
	var b strings.Builder
	fmt.Fprintf(&b, "id: %d\n", ev.ID)
	if ev.Type != "" {
		fmt.Fprintf(&b, "event: %s\n", ev.Type)
	}
	for _, line := range strings.Split(string(ev.Data), "\n") {
		b.WriteString("data: ")
		b.WriteString(line)
		b.WriteByte('\n')
	}
	b.WriteByte('\n') // blank line terminates the event
	_, err := io.WriteString(w, b.String())
	return err
}
```

### 2.4 Route handler (cursor negotiation)

```go
func (h *Hub) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		lastID := parseCursor(r)
		if err := h.Serve(r.Context(), w, lastID); err != nil &&
			!errors.Is(err, context.Canceled) {
			// A closed pipe / write deadline is normal when a client leaves.
			slog.Debug("sse stream ended", "err", err)
		}
	})
}

// parseCursor prefers the standard Last-Event-ID header (sent by EventSource on
// its own reconnect) and falls back to ?after= for first connects / page reloads,
// where EventSource has no in-memory lastEventId yet.
func parseCursor(r *http.Request) uint64 {
	pick := func(v string) (uint64, bool) {
		n, err := strconv.ParseUint(v, 10, 64)
		return n, err == nil
	}
	if v := r.Header.Get("Last-Event-ID"); v != "" {
		if n, ok := pick(v); ok {
			return n
		}
	}
	if v := r.URL.Query().Get("after"); v != "" {
		if n, ok := pick(v); ok {
			return n
		}
	}
	return 0
}
```

### 2.5 Backpressure policy — pick one deliberately

A bounded per-subscriber channel forces a decision when it fills. Confirmed policies across
mature Go SSE libraries (see §8): **drop-newest**, **drop-oldest (coalesce)**, or
**disconnect-slow**.

- **Broadcast logs** (many viewers of one build): drop-newest is fine; emit a
  `event: gap` frame telling the client it fell behind, so the UI can show "reconnecting".
- **Must-deliver** (per-recipient notifications): close the subscriber's channel; the client
  reconnects with `Last-Event-ID` and the ring replays from the cursor. Resync over your
  normal REST API is what actually guarantees correctness, not best-effort delivery.
- **Never** block the publisher on a subscriber channel.

Complement with a **per-write deadline** so a socket that stops reading cannot pin a
goroutine forever:

```go
// Inside the write path, before writing (illustrative):
_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Second))
```

### 2.6 Server + graceful shutdown

```go
func main() {
	hub := NewHub(1024)
	mux := http.NewServeMux()
	mux.Handle("/v1/builds/", hub.Handler()) // real routing elided

	srv := &http.Server{
		Addr:              ":8080",
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		// CRITICAL: the zero value of WriteTimeout kills long-lived streams.
		// Keep it 0 for SSE and enforce liveness with per-write deadlines.
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}
	_ = srv.ListenAndServe()
}

// Shutdown stops new subscribers and unblocks every Serve loop.
func (h *Hub) Shutdown(ctx context.Context) {
	h.mu.Lock()
	if !h.closed {
		h.closed = true
		close(h.done)
	}
	h.mu.Unlock()
	_ = ctx // hook srv.Shutdown(ctx) here in real code
}
```

> **Gotcha 3 — `http.Server.WriteTimeout`.** A non-zero `WriteTimeout` is applied to the whole
> response write and will abruptly kill streams. Leave it 0 and use
> `ResponseController.SetWriteDeadline` per write. (`ReadHeaderTimeout` still protects you.)
>
> **Gotcha 4 — goroutine leaks.** Always register/unregister around `r.Context().Done()`; if
> you don't watch for client disconnect the handler goroutine and its channel leak per
> dropped connection, which is the classic slow memory exhaustion under load.
>
> **Gotcha 5 — `Flusher` availability.** `http.NewResponseController(w).Flush()` returns an
> error when the writer can't flush (some middleware wraps `ResponseWriter` and drops the
> `Flusher`). Prefer `ResponseController` (Go 1.20+) over a raw `w.(http.Flusher)` assertion;
> it unwraps and reports errors. If your middleware preserves `Flush` via `Unwrap()`, this
> just works.

---

## 3. Streaming a child process into the hub (the build runner)

```go
// RunBuild streams a child process's stdout/stderr into the hub as it runs.
func RunBuild(ctx context.Context, hub *Hub, cmd *exec.Cmd) error {
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}

	var wg sync.WaitGroup
	pump := func(r io.Reader, stream string) {
		defer wg.Done()
		sc := bufio.NewScanner(r)
		// bufio.Scanner's default MaxScanTokenSize is 64 KiB. A single longer
		// line (stack trace, base64 blob, minified error) makes Scan() return
		// false with bufio.ErrTooLong and the REST OF THE STREAM IS LOST.
		// Raise the cap, or use bufio.Reader.ReadBytes('\n') (no line limit).
		sc.Buffer(make([]byte, 0, 64*1024), 1<<20) // up to 1 MiB per line
		for sc.Scan() {
			payload, _ := json.Marshal(map[string]string{
				"stream": stream,
				"line":   sc.Text(),
			})
			if _, err := hub.Publish("log", payload); err != nil {
				return
			}
		}
		if err := sc.Err(); err != nil {
			payload, _ := json.Marshal(map[string]string{
				"stream": stream,
				"error":  err.Error(),
			})
			_, _ = hub.Publish("error", payload)
		}
	}
	wg.Add(2)
	go pump(stdout, "stdout")
	go pump(stderr, "stderr")
	werr := cmd.Wait()
	wg.Wait()
	code := cmd.ProcessState.ExitCode()
	payload, _ := json.Marshal(map[string]int{"code": code})
	_, _ = hub.Publish("exit", payload)
	return werr
}
```

> **Gotcha 6 — the 64 KiB scanner cliff.** `bufio.Scanner`'s `MaxScanTokenSize` is 64 KiB
> (`bufio.ErrTooLong` on overflow). Either call `sc.Buffer(...)` to raise it, or read with
> `bufio.Reader.ReadBytes('\n')` which has no fixed cap. For structured JSON logs, a
> `json.Decoder` over the pipe is often cleaner still.
>
> **Gotcha 7 — stdout/stderr ordering.** Two pipes are read by two goroutines, so
> interleaving is non-deterministic. If ordering matters, have the child emit a single
> merged, timestamped stream (e.g. via a shell wrapper or a structured logger), or set both
> `cmd.Stdout` and `cmd.Stderr` to the same `io.Writer` (a shared `*os.File` or `io.PipeWriter`)
> and accept that ordering is still best-effort.
>
> **Gotcha 8 — `cmd.Wait()` must run.** With `StdoutPipe`/`StderrPipe`, you must not call
> `Wait` until reads finish; the pattern above (`Wait` then `wg.Wait`) is correct because
> the pipes are fully read by the goroutines and `Wait` closes them. Don't `Wait` before the
> pumps finish, and don't forget it or you leak the child.

---

## 4. Resumption semantics: `Last-Event-ID` vs `?after=`

This is the subtle part and worth getting exactly right.

- Per the [WHATWG spec](https://html.spec.whatwg.org/multipage/server-sent-events.html), the
  EventSource keeps a *last event ID string*, updated from each `id:` field. On its **own
  automatic reconnect** it sends that value in the `Last-Event-ID` request header.
- It is **not** sent on the first connection, and it is **not persisted**: a page reload
  creates a brand-new `EventSource` whose last event ID is empty ([MDN EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource)).
  So a refresh silently restarts at the current tail unless you carry a cursor yourself.
- `EventSource` gives you **no API to set `Last-Event-ID`** manually and **no way to set
  custom request headers** (no `Authorization`). The ID is opaque to you as a string; if you
  use numeric IDs you parse it back.
- `id:` values are also **not reset between reconnects** by the client; if a server sends an
  `id:` with an empty value the stored string is reset to empty.

Practical contract:

1. Server sets `id: <monotonic uint>` on every event and keeps a bounded replay ring.
2. On reconnect the browser sends `Last-Event-ID`; server replays `> lastID` from the ring.
3. On **first** connect / page reload the client appends `?after=<cursor>` that it persisted
   in `sessionStorage`/`localStorage`, and the server treats it as the same cursor.
4. Server prefers `Last-Event-ID` when present (it is fresher than a possibly-stale query
   param because the browser updated it on the live connection).

> **Gotcha 9 — ring size is a product decision.** If a client is away longer than the ring can
> cover, the oldest events are gone. Emit an explicit `event: gap` (or return `?after=` too
> old ⇒ `410 Gone` and force a full state re-fetch) rather than silently skipping. Never
> pretend a gap did not happen.

---

## 5. Infrastructure / proxy checklist

| Layer | Setting | Why |
|---|---|---|
| nginx | `proxy_buffering off;` / `X-Accel-Buffering: no` | Stop buffering the stream. |
| nginx | `proxy_read_timeout 3600s;` (≥ your keepalive interval) | Default 60s reaps idle streams. |
| nginx | `proxy_http_version 1.1;` `proxy_set_header Connection "";` | Keep upstream connection alive; avoid forced close. |
| nginx | `proxy_cache off;` `gzip off;` (or bypass) | Caching/compression hold bytes. |
| Load balancer | idle timeout ≥ keepalive; sticky not required if stateless ring | Read/side timeouts kill streams. |
| HTTP/2 | enable end-to-end | HTTP/1.1 caps **~6 connections per browser per origin**; many tabs exhaust it. HTTP/2 streams default ~100. |
| Go server | `WriteTimeout: 0` | See Gotcha 3. |
| Observability | gauge of active subscribers, counter of drops/evictions, keepalive failures | This is how you catch slow-consumer incidents. |

> **Gotcha 10 — the 6-connection limit.** When **not** over HTTP/2, browsers limit
> simultaneous connections per origin (≈6, per browser, across all tabs) and this is marked
> "won't fix" in Chrome/Firefox ([MDN EventSource warning](https://developer.mozilla.org/en-US/docs/Web/API/EventSource)).
> Six open dashboard tabs against one host can deadlock the seventh SSE connection. Terminate
> HTTP/2 at the edge.
>
> **Gotcha 11 — buffering can be re-introduced by your own stack.** Go gzip middleware, a
> Node/Next proxy, service meshes (Envoy/Istio with response buffering), and Cloudflare all
> sit between the Go server and the browser. Verify with `curl -N` through each hop in
> production.

Quick verification command (must show lines as they arrive, not in one block):

```bash
curl -N -H 'Accept: text/event-stream' \
  'https://shipyard.example.com/v1/builds/42/logs?after=0'
```

---

## 6. Next.js / React client

### 6.1 Why a proxy route

Native `EventSource` cannot send an `Authorization` header and cannot set `Last-Event-ID`.
Also, cross-origin SSE with credentials requires `withCredentials: true` **and** a server
`Access-Control-Allow-Origin` that is **not** `*` (plus `Access-Control-Allow-Credentials:
true`). The simplest, most robust fix for a same-host app is a thin Next.js Route Handler
that injects auth server-side and streams the upstream body straight through.

### 6.2 Next.js Route Handler proxy (App Router)

```ts
// app/api/builds/[id]/logs/route.ts
export const runtime = "nodejs";          // needs Node streams + server-only secrets
export const dynamic = "force-dynamic";   // never cache a stream

export async function GET(
  req: Request,
  ctx: { params: Promise<{ id: string }> },
) {
  const { id } = await ctx.params;
  const token = await getServerToken(); // resolve from session/cookie server-side

  // Preserve the cursor. The browser sends Last-Event-ID on its own reconnect;
  // forward it so the Go server can replay. ?after= covers first connect/reload.
  const after = new URL(req.url).searchParams.get("after");
  const upstreamUrl =
    `${process.env.SHIPYARD_API}/v1/builds/${id}/logs` +
    (after ? `?after=${encodeURIComponent(after)}` : "");

  const headers: Record<string, string> = {
    Accept: "text/event-stream",
    Authorization: `Bearer ${token}`,
  };
  const lastEventId = req.headers.get("last-event-id");
  if (lastEventId) headers["Last-Event-ID"] = lastEventId;

  const upstream = await fetch(upstreamUrl, {
    headers,
    cache: "no-store",
    signal: req.signal, // abort upstream when the client goes away
  });

  if (!upstream.ok || !upstream.body) {
    return new Response("upstream error", { status: 502 });
  }

  return new Response(upstream.body, {
    headers: {
      "Content-Type": "text/event-stream; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      "X-Accel-Buffering": "no",
      Connection: "keep-alive",
    },
  });
}
```

> **Gotcha 12 — do not buffer the proxy.** Returning `upstream.body` (a web `ReadableStream`)
> streams, but any middleware or `compression`/gzip wrapping on this route re-introduces
> buffering. Keep this route out of compression and out of ISR/caching (`force-dynamic`,
> `cache: "no-store"`).

### 6.3 React client component

```tsx
"use client";

import { useEffect, useRef, useState } from "react";

type LogLine = {
  seq: number;
  stream: "stdout" | "stderr";
  line: string;
};

const MAX_LINES = 5_000; // bound memory for long builds

export function BuildLogs({ buildId }: { buildId: string }) {
  const [lines, setLines] = useState<LogLine[]>([]);
  const [status, setStatus] = useState<"connecting" | "open" | "closed">(
    "connecting",
  );
  const cursorRef = useRef(0);

  useEffect(() => {
    // EventSource keeps lastEventId in memory only; a reload would restart at 0.
    // Persist and restore it ourselves, and pass it as ?after= on first connect.
    const key = `shipyard:cursor:${buildId}`;
    const saved = Number(sessionStorage.getItem(key) ?? "0") || 0;
    cursorRef.current = saved;

    const es = new EventSource(
      `/api/builds/${buildId}/logs?after=${saved}`,
      { withCredentials: true },
    );

    es.onopen = () => setStatus("open");
    es.onerror = () => setStatus("connecting"); // browser auto-retries

    es.addEventListener("log", (e) => {
      const evt = e as MessageEvent;
      if (evt.lastEventId) {
        cursorRef.current = Number(evt.lastEventId);
        sessionStorage.setItem(key, evt.lastEventId);
      }
      const parsed = JSON.parse(evt.data) as Omit<LogLine, "seq">;
      setLines((prev) => {
        const next = [
          ...prev,
          { ...parsed, seq: Number(evt.lastEventId) },
        ];
        return next.length > MAX_LINES ? next.slice(-MAX_LINES) : next;
      });
    });

    es.addEventListener("exit", () => {
      setStatus("closed");
      es.close(); // terminal event: stop the automatic reconnect loop
    });

    return () => es.close(); // cleanup on unmount / build change
  }, [buildId]);

  return (
    <div>
      <div aria-live="polite">{status}</div>
      <pre>
        {lines.map((l) => (
          <div
            key={l.seq}
            className={l.stream === "stderr" ? "text-red-400" : undefined}
          >
            {l.line}
          </div>
        ))}
      </pre>
    </div>
  );
}
```

Key client rules:

- Named events (`event: log`) require **`addEventListener("log", ...)`**; `onmessage` only
  receives unnamed (`message`) events ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/EventSource)).
- Use a `ref` for the cursor, not state — writing state on every line would re-run the effect
  and resubscribe.
- **Call `es.close()` on the terminal event**, or the browser will reconnect forever after a
  finished build.
- Cap the retained lines; a long build will otherwise grow memory without bound.
- `EventSource` fires `onerror` on transient drop; the browser retries with backoff
  (honouring your `retry:` hint). Don't implement your own reconnect on top of the native one
  unless you switch to `fetch` (below) — you'd get double connections.

> **Gotcha 13 — Server Components cannot use `EventSource`.** It is a browser API. The
> streaming component must be a Client Component (`"use client"`) and must clean up in the
> effect's return.

### 6.4 When you cannot use the native EventSource (custom headers)

If you must attach headers directly from the browser (no Next proxy), use `fetch` with a
streaming body and parse SSE yourself. You then own reconnect/backoff and must re-send the
cursor. Sketch:

```ts
async function streamLogs(buildId: string, after: number, onEvent: (e: {id: number; type: string; data: string}) => void) {
  const res = await fetch(`/v1/builds/${buildId}/logs?after=${after}`, {
    headers: { Accept: "text/event-stream", Authorization: `Bearer ${token}` },
  });
  if (!res.ok || !res.body) throw new Error(`stream failed: ${res.status}`);
  const reader = res.body.pipeThrough(new TextDecoderStream()).getReader();
  let buf = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buf += value;
    let idx: number;
    while ((idx = buf.indexOf("\n\n")) !== -1) {
      const frame = buf.slice(0, idx);
      buf = buf.slice(idx + 2);
      let id = 0, type = "message", data = "";
      for (const line of frame.split("\n")) {
        if (line.startsWith("id:")) id = Number(line.slice(3).trim());
        else if (line.startsWith("event:")) type = line.slice(6).trim();
        else if (line.startsWith("data:")) data += (data ? "\n" : "") + line.slice(5).replace(/^ /, "");
      }
      if (id) after = id;
      onEvent({ id, type, data });
    }
  }
}
```

> **Gotcha 14 — SSE line parsing is not "split on newline".** A `data:` field may repeat across
> lines to encode embedded newlines; strip exactly one optional leading space after the colon;
> frames end on a blank line. The above handles the common cases but a battle-tested parser
> (or the native `EventSource`) is strongly preferred.

---

## 7. REST control-plane semantics

### 7.1 Conditional GET / ETag (poll and revalidate cheaply)

- Return a **strong** `ETag` — a quoted string that changes whenever the representation
  changes, e.g. `ETag: "build-42-rev7"` (derive from the resource's `updated_seq`/`updated_at`,
  not from a random per-request value).
- On `GET`, if the client sends `If-None-Match: "build-42-rev7"` and it matches, return
  **`304 Not Modified`** with **no body**, re-sending the same `ETag` and `Cache-Control`.
- ETags must be quoted (`"..."`); use `W/"..."` only if the representation is semantically
  equivalent but byte-different (e.g. re-compressed). Don't emit weak ETags unless you mean it
  ([RFC 9110 §8.8.1/§13](https://www.rfc-editor.org/rfc/rfc9110.html)).
- Emit `Vary` when the representation depends on request headers, and `Cache-Control:
  no-store` for per-user/authenticated responses you don't want cached.

### 7.2 Optimistic concurrency: `If-Match` → `412`

- Client reads state, keeps `ETag`. On write (`PUT`/`PATCH`) it sends `If-Match: "<rev>"`.
- If it no longer matches the current representation, return **`412 Precondition Failed`** —
  this is the RFC 9110 code for a failed precondition (including `If-Match`), and it is
  distinct from `409`.
- `If-Match: *` means "only if any current representation exists". `If-None-Match: *` on `PUT`
  means "only if the resource does **not** exist" (create-if-absent) and should yield `412`
  when it does exist.
- `If-Unmodified-Since` is a weaker, second-granularity alternative; prefer ETags.

### 7.3 Semantic conflicts: `409`

Use **`409 Conflict`** when the request conflicts with the current *state of the resource* in
a business sense, not a precondition sense — e.g. "cancel an already-succeeded build", "two
builds attempt the same exclusive environment lock", "duplicate unique key".

| Situation | Code |
|---|---|
| `If-Match` ETag mismatch (client is stale) | `412 Precondition Failed` |
| Create-if-absent but resource exists (`If-None-Match: *`) | `412 Precondition Failed` |
| Operation invalid for current business state | `409 Conflict` |
| Duplicate natural key (no unique-constraint at DB level) | `409 Conflict` |
| Same `Idempotency-Key`, different request body | `409 Conflict` (see §7.4) |
| Same `Idempotency-Key`, original still in flight | `409 Conflict` + `Retry-After` |

### 7.4 Idempotent POST with `Idempotency-Key`

Pattern formalized by the IETF drafts ([draft-idempotency-header-00](https://datatracker.ietf.org/doc/html/draft-idempotency-header-00),
[draft-ietf-httpapi-idempotency-key-header-07](https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header-07)):

1. Client sends `Idempotency-Key: <opaque string, e.g. UUID>` on `POST /v1/builds` (and other
   non-idempotent, side-effecting writes).
2. Server stores, keyed by **(authenticated principal, endpoint, key)**: a **request
   fingerprint** (hash of method + path + body) and the **original response** (status + body),
   with a TTL.
3. **Same key + same fingerprint** ⇒ replay the stored response verbatim; do not re-execute.
   Signal it (e.g. `Idempotent-Replay: true`).
4. **Same key + different fingerprint** ⇒ `409 Conflict` (the drafts allow `409`/`422`; pick one
   and document it).
5. **Same key while the first request is still running** ⇒ `409 Conflict` with `Retry-After`
   (do not run the operation twice).

Go middleware skeleton:

```go
type IdemStore interface {
	// Get returns the stored response fingerprint for key, if any.
	Get(ctx context.Context, principal, endpoint, key string) (fingerprint string, resp []byte, status int, ok bool, err error)
	// Begin claims the key; returns ErrInFlight if another request holds it.
	Begin(ctx context.Context, principal, endpoint, key, fingerprint string, ttl time.Duration) error
	// Finish stores the completed response.
	Finish(ctx context.Context, principal, endpoint, key string, resp []byte, status int) error
}

func Idempotency(store IdemStore, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Idempotency-Key")
		if key == "" || r.Method != http.MethodPost {
			next.ServeHTTP(w, r)
			return
		}
		principal := authn.PrincipalFrom(r.Context())
		endpoint := r.URL.Path

		body, _ := io.ReadAll(r.Body)
		r.Body = io.NopCloser(bytes.NewReader(body))
		fp := sha256hex(r.Method + " " + endpoint + " " + string(body))

		if storedFP, resp, status, ok, _ := store.Get(r.Context(), principal, endpoint, key); ok {
			if storedFP != fp {
				http.Error(w, "idempotency key reused with a different request", http.StatusConflict)
				return
			}
			w.Header().Set("Idempotent-Replay", "true")
			w.WriteHeader(status)
			_, _ = w.Write(resp)
			return
		}
		if err := store.Begin(r.Context(), principal, endpoint, key, fp, 24*time.Hour); err != nil {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "request in progress", http.StatusConflict)
			return
		}

		rec := &responseRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		_ = store.Finish(r.Context(), principal, endpoint, key, rec.body.Bytes(), rec.status)
	})
}
```

> **Gotcha 15 — idempotency must not paper over non-idempotent internals.** Replaying a
> response is safe; the danger is executing the side effect twice while "thinking" it is
> idempotent. Claim the key atomically (unique index / Redis `SET NX`) **before** doing work.
>
> **Gotcha 16 — scope and hash the key.** Scope by principal so user A cannot replay or block
> user B's key. Store a hash, not necessarily the raw key. Expire entries (TTL) so storage
> does not grow forever.

---

## 8. Sources

Fetched directly:
- MDN, *Using server-sent events* — https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events
- MDN, *EventSource* (interface, `withCredentials`, 6-connection/HTTP-1.1 warning, `close()`) — https://developer.mozilla.org/en-US/docs/Web/API/EventSource
- WHATWG HTML, *Server-sent events* (`event`/`data`/`id`/`retry`, `Last-Event-ID`, reconnection) — https://html.spec.whatwg.org/multipage/server-sent-events.html
- nginx, *ngx_http_proxy_module* (buffering, `proxy_read_timeout`, `X-Accel-Buffering`) — https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- IETF, *The Idempotency-Key HTTP Header Field* (draft 00) — https://datatracker.ietf.org/doc/html/draft-idempotency-header-00
- IETF HTTPAPI WG, *Idempotency-Key header* (draft 07) — https://datatracker.ietf.org/doc/html/draft-ietf-httpapi-idempotency-key-header-07
- Go `net/http` `ResponseController` (`Flush`/`FlushError`, `SetWriteDeadline`) — https://pkg.go.dev/net/http#ResponseController
- Next.js App Router, Route Handlers — https://nextjs.org/docs/app/api-reference/file-conventions/route
- RFC 9110, *HTTP Semantics* (ETag, `If-Match`/`If-None-Match`, `304`, `409`, `412`) — https://www.rfc-editor.org/rfc/rfc9110.html
- Go `bufio` (`Scanner`, `ErrTooLong`, `MaxScanTokenSize`, `Buffer`) — https://pkg.go.dev/bufio#Scanner

Search-derived (community/implementation references for hub/backpressure patterns):
- "Implementing Server-Sent Events (SSE) in Go" (hub + `select`/`default` drop, `Flush`,
  `r.Context().Done()`) — https://medium.com/@rishabhkum17/real-time-updates-without-the-complexity-implementing-server-sent-events-sse-in-go-f9d508f91d0e
- Go SSE libraries demonstrating replay rings, keepalive, backpressure policies and
  per-subscriber buffers: `tmaxmax/go-sse` (https://github.com/tmaxmax/go-sse),
  `lampctl/go-sse` (`NumEventsToKeep`, `ChannelBufferSize`),
  `imlargo/sse` (`Block`/`Coalesce`/`Disconnect`), `apt304/sse-go` (drop-oldest + heartbeats),
  `oarkflow/sse` (sticky replay, `BackpressureDisconnectSlow`, graceful drain),
  `cplieger/webhttp/sse` (replay ring + monotonic IDs + `Last-Event-ID`),
  `custom-app/sse` (`CloseSubscription` → reconnect + re-fetch authoritative state).

Caveats on citations: the WHATWG/RFC/MDN/nginx/Go/Next.js items were fetched directly and are
authoritative. The community library descriptions were surfaced through search and are cited
as corroborating implementation patterns, not as specifications.
