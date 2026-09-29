# nginx and systemd primitives for Shipyard

Scope: verified research on (a) generating and safely applying nginx configuration from an application, and (b) systemd unit design for an app whose code lives behind a swapped `current` symlink. All man-page quotations below were read from the systemd 261-era man pages installed locally on this machine (`man -P cat systemd.service`, `systemd.exec`, `systemd.path`, `systemd.unit`, `systemd.kill`, `journalctl`, `systemctl`, `journald.conf`) unless a URL is given.

**Reading caution discovered during research:** the freedesktop.org HTML man pages render each directive's "Added in version N" note such that, when scraped or read as an excerpt, the note visually attaches to the *following* directive. This produced a false claim in one search excerpt that `ExecReload=` was "Added in version 243". Direct inspection of the local groff-formatted man page shows line 408 (`Added in version 243.`) terminates the `ExecCondition=` entry and `ExecReload=` begins at line 410. **Treat version annotations scraped from freedesktop.org HTML with suspicion; confirm against the local man page.** The local man pages also do NOT annotate `Type=exec` at all (see the Gap in Q4).

---

## Q1. Safe nginx config application: `nginx -t`, atomic replace, reload vs restart, `systemctl reload` vs `nginx -s reload`

### Takeaway
The correct sequence is: write the candidate config to a **temp file in the same directory as the final destination**, atomically `mv -T` it into place, run `nginx -t` as root, and only then issue a **reload** (never a restart). If the config is bad, the running nginx keeps serving the old config — this is guaranteed by nginx's own HUP handling, which rolls back and continues. Use `systemctl reload nginx`, not a bare `nginx -s reload`, because the systemd unit's `ExecReload=` is the only invocation that is guaranteed to carry the same `-c`/prefix/chroot context the running master was started with.

### Cited Findings
- `nginx -t` is documented as: "test the configuration file: nginx checks the configuration for correct syntax, and then tries to open files referred in the configuration." — [nginx command-line parameters](https://nginx.org/en/docs/switches.html). **Important:** `-t` is stronger than a pure parse. It attempts to `open()` the files the config references. `-T` is "same as -t, but additionally dump configuration files to standard output (1.9.2)".
- `nginx -s signal` is documented, with `reload` = "reload configuration, start the new worker process with a new configuration, gracefully shut down old worker processes." — [nginx command-line parameters](https://nginx.org/en/docs/switches.html)
- The HUP/reload failure semantics are explicit in the official control documentation: "In order for nginx to re-read the configuration file, a HUP signal should be sent to the master process. The master process first checks the syntax validity, then tries to apply new configuration, that is, to open log files and new listen sockets. **If this fails, it rolls back changes and continues to work with old configuration.** If this succeeds, it starts new worker processes, and sends messages to old worker processes requesting them to shut down gracefully. Old worker processes close listen sockets and continue to service old clients." — [Controlling nginx](https://nginx.org/en/docs/control.html)
- Master signal table: `TERM, INT` = fast shutdown; `QUIT` = graceful shutdown; `HUP` = "changing configuration, keeping up with a changed time zone (only for FreeBSD and Linux), starting new worker processes with a new configuration, graceful shutdown of old worker processes"; `USR1` = re-opening log files; `USR2` = upgrading an executable file; `WINCH` = graceful shutdown of worker processes — [Controlling nginx](https://nginx.org/en/docs/control.html)
- `systemctl reload-or-restart PATTERN...`: "Reload one or more units if they support it. If not, stop and then start them instead. **If the units are not running yet, they will be started.**" and `systemctl try-reload-or-restart PATTERN...`: identical but "**This does nothing if the units are not running.**" (`try-reload-or-restart` "Added in version 229") — `systemctl(1)`, read locally.
- nginx's PID file location is `/usr/local/nginx/logs/nginx.pid` by default and "This name may be changed at configuration time, or in nginx.conf using the `pid` directive." — [Controlling nginx](https://nginx.org/en/docs/control.html). This is why a bare `nginx -s reload` is fragile: `-s` reads the pid file from the *default* compiled-in prefix unless `-c`/`-p` are supplied, so it can signal the wrong master (or fail silently) if the unit was started with custom flags.

### Inferences
- **Fail-closed is a property of nginx, not of your script.** Because the master "first checks the syntax validity" and "rolls back changes and continues to work with old configuration" on failure, an out-of-date `-t` cannot take effect. The script's job is to (1) never leave a bad file in the final location in the first place, and (2) check `nginx -t`'s exit status and abort the deploy on non-zero. nginx also re-tests on HUP, so a race between `-t` and reload is caught by nginx itself, not by you — the only cost of the race is that the deploy must roll the *file* back, because nginx will silently keep the old config while reporting reload "success" on the master side.
- **`systemctl reload nginx` is the correct command**; `nginx -s reload` is the wrong one for a control plane because it bypasses systemd's knowledge of how the master was launched. The distro nginx unit implements `ExecReload=` as an `nginx -s reload` variant, so the two converge in the common case, but the systemd path additionally: works if the unit is in a `PrivateTmp=`/chroot/`RootDirectory=` sandbox, respects the unit's `ExecStart` flags, and participates in systemd's job ordering and failure reporting (so `systemctl reload nginx` returns non-zero if reload fails).
- **`restart` is categorically wrong for a config change.** `systemctl restart nginx` is stop+start: the master is terminated and the listening sockets are torn down, so every in-flight request is dropped and there is a window with no listener at all (connection refused for new requests). `reload` never drops the listening socket — the master keeps it and only the workers are cycled. Per the docs above, on HUP the master "starts new worker processes" and old workers "close listen sockets and continue to service old clients" — note *old workers close* the listen socket, implying new workers have already inherited it, which is exactly the zero-downtime property.
- **The atomic replace must be `mv -T` from a temp file in the same directory.** `rename(2)` within one filesystem is atomic, so a concurrent `nginx` opening the file sees either the old inode or the new inode, never a truncated/partial file. The temp file must be in the *same directory* (not `/tmp`, which may be a different filesystem and would degrade `rename(2)` to a non-atomic copy+unlink). The `-T` flag treats the destination as a normal file rather than a directory, so `mv` cannot silently create `dest/nginx.conf` if `dest` somehow became a directory. Writing directly to the destination with `>` is the classic outage: nginx's master or a `include`d glob can read a half-written file.
- **Concurrency pitfall:** two overlapping deploys both writing `/etc/nginx/sites-available/<app>.conf` will interleave test/reload and can leave nginx running a config that no deploy intended. Wrap the whole test+reload in an exclusive lock (`flock`) per host.

### Gaps
- I did not verify the exact `ExecReload=` line shipped in the Debian/Ubuntu or RHEL nginx systemd units. It is distribution-specific and has changed across releases (it has included `-g 'daemon on; master_process on;'` and `-c` variants in different versions). **Shipyard should read the installed unit's `ExecReload=` rather than hardcode `nginx -s reload`.** If a host ever has no `ExecReload=`, `systemctl reload nginx` fails outright, which is a safe failure — prefer it over a hand-rolled signal.
- nginx documents no exit code table for `nginx -t`; only "On success... " is not even stated for nginx. Treat any non-zero as failure, but do not try to parse its stdout.
- I found no authoritative statement on whether `nginx -t` opens files inside *all* locations (as opposed to only the main-context and server-level files). This matters for "will `-t` catch a broken `root` path?" The doc's phrase "tries to open files referred in the configuration" is the only guidance available; it is not a guarantee of full filesystem validation. Do not rely on `-t` alone to validate a symlinked static root — validate the symlink target explicitly in the deploy script.

### Concrete deploy script (nginx half)
```bash
#!/usr/bin/env bash
# shipyard-nginx-apply — fail-closed config application
set -Eeuo pipefail

APP="$1"                       # e.g. "blog"
SRC="$2"                       # candidate file written by the app's config generator
NGINX_SITE="/etc/nginx/sites-available/${APP}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${APP}.conf"

# 1. Serialise all nginx mutations on this host. Two concurrent deploys
#    otherwise interleave test+reload and can leave nginx on a config
#    neither deploy intended.
exec 9>/run/lock/shipyard-nginx.lock
flock -x 9

# 2. Stage in the SAME directory as the destination so the final step is a
#    same-filesystem rename(2), which is atomic. A reader (nginx master,
#    or an `include` glob in a concurrent reload) sees old-or-new, never partial.
tmp="$(mktemp "${NGINX_SITE}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat "$SRC" > "$tmp"
chmod 0644 "$tmp"
chown root:root "$tmp"

# 3. Atomically publish. -T => treat destination as a normal file, so mv can
#    never create "dest/nginx.conf" inside a directory that replaced dest.
mv -T -- "$tmp" "$NGINX_SITE"
trap - EXIT

# 4. enable-site symlink, also atomic and idempotent
ln -sfn -- "$NGINX_SITE" "$NGINX_LINK"

# 5. Test. MUST be root: -t needs to bind-inspect listeners and open
#    referenced files. Non-zero here => ABORT, before any reload.
#    nginx re-validates on HUP and rolls back on its own, but we must not
#    ask for a reload at all.
if ! nginx -t; then
  echo "shipyard: nginx -t failed; keeping previous config; nginx still serving old config" >&2
  # Optional: restore the previous file so a subsequent nginx restart
  # (e.g. after an unrelated reboot) does not load the broken config.
  if [[ -n "${NGINX_SITE}.prev" && -f "${NGINX_SITE}.prev" ]]; then
    mv -T -- "${NGINX_SITE}.prev" "$NGINX_SITE"
    nginx -t && systemctl reload nginx || true
  fi
  exit 1
fi

# 6. Reload, never restart. Reload cycles workers and keeps the listening
#    socket open; restart drops in-flight requests and creates a window
#    with no listener at all.
systemctl reload nginx
```

---

## Q2. Why `PathChanged=` / `.path` units do not fire on atomic symlink replacement

### Takeaway
Both upstream reports are confirmed, and the newer one (still open, 2024, systemd 255.2) shows the failure is not fixed. `inotifywait` reports only `ATTRIB` then `DELETE_SELF` on the symlink path — never a create/move event on the *parent directory* naming the new target — so systemd's path watch, which is attached to the inode of the watched path, sees its own watch target destroyed and never observes the replacement. **Design consequence: do not build deploy auto-restart on a path unit. The deploy script must explicitly drive `systemctl restart`.**

### Cited Findings
- **systemd issue #17727**, "`.path` units with `PathChanged=` should recognize atomic symlink replacement, but doesn't", opened by Bilge on 2020-11-25, labels `pid1`, milestone `v249`, **closed** (cross-referenced to #19726). The reporter's exact description of the deployment idiom: "An atomic deployment looks like this: `ln -nsf new-release release` / `mv -T release current`. This replaces the existing symlink `current` with the new symlink `release` pointing to new-release (instead of whatever the old release was)." Requested `PathMoved=/var/www/my-site/current`, and reported: "**I have tried PathChanged and PathModified, neither of which detect the symlink replacement.**" — [systemd/systemd#17727](https://github.com/systemd/systemd/issues/17727)
- **systemd issue #31941**, "path unit does not trigger on atomic symlink replacement", opened by Tom-Hubrecht on 2024-03-25, labels `bug`, `pid1`, **still open**, no milestone. Reported against **systemd 255.2**, NixOS unstable (24.05), kernel 6.1.66, x86_64. Unit was `PathModified=/run/current-system/` with `Unit=arkheon-record.service`. Expected the service to activate on replacement; observed "**The selected unit is not started, even though inotifywait shows that the following events are triggered: `/run/current-system ATTRIB` / `/run/current-system DELETE_SELF`**". Steps to reproduce: create `toto` and `tata`, `ln -s TEST_FOLDER/toto TEST_FOLDER/test`, `PathModified=TEST_FOLDER/test`, then "Run `ln -snf TEST_FOLDER/tata TEST_FOLDER/test` and nothing happens even though the test path was modified. (**It also doesn't work with PathChanged**)" — [systemd/systemd#31941](https://github.com/systemd/systemd/issues/31941)
- `PathChanged=` "may be used to watch a file or directory and activate the configured unit whenever it changes. It is not activated on every write to the watched file but it is activated if the file which was open for writing gets closed." `PathModified=` "is similar, but additionally it is activated also on simple writes to the watched file." — `systemd.path(5)`, read locally.
- Also from `systemd.path(5)`: "If a path already exists (in case of `PathExists=` and `PathExistsGlob=`) or a directory already is not empty (in case of `DirectoryNotEmpty=`) at the time the path unit is activated, then the configured unit is immediately activated as well. **Something similar does not apply to `PathChanged=` and `PathModified=`.**" — i.e. systemd is explicitly edge-triggered here; there is no level-triggered fallback that would paper over a missed event.

### Inferences
- **Why the watch misses it.** The `ln -sfn new target` step mutates the *existing* symlink inode's target in place (that is what produces `IN_ATTRIB` — the link count/attributes of that inode changed), and the subsequent `mv -T current` unlinks the old `current` symlink inode entirely, producing `IN_DELETE_SELF` when that inode's last link goes away. The directory entry `current` is then repointed at a *new* inode. A watch installed on the *inode* of `/var/www/.../current` therefore receives `ATTRIB` then `DELETE_SELF` and is subsequently marked `IN_IGNORED` by the kernel — it is watching a corpse. The event that would have been meaningful, `IN_MOVED_TO` on the *parent* directory with the name `current`, is never delivered to that watch, because the watch is not on the parent directory. Both the 2020 and 2024 reporters observing exactly `ATTRIB` + `DELETE_SELF` and nothing else is consistent with this and inconsistent with any theory in which systemd would also see a create/move event.
- **The idiom itself is the problem, not the systemd version.** Both the milestone in #17727 and the still-open status of #31941 (on 255.2, four releases past the milestone) mean Shipyard cannot treat this as "will be fixed in some future systemd". The `ln -sfn` + `mv -T` two-step is the correct, race-free way to swap a release pointer, and it is precisely the thing path units cannot see. There is no config knob that changes this.
- **`PathMoved=` is not a workaround.** It was the *requested* fix in #17727, not a shipped feature, and #31941 demonstrates that the newer inotify `IN_MOVE` event does not rescue the case either (the reporter's watch was on the symlink, and `mv -T` is `rename(2)` of the symlink itself, not a move of its contents).
- **The only reliable designs are:** (a) deploy-script-driven `systemctl restart` — recommended; (b) if an out-of-band trigger is truly required, a `ExecStartPost`-style sentinel — have the deploy write a version marker into a *regular file* (e.g. `/var/www/app/.deployed`) and point `PathChanged=` at that file, because the failure mode is specific to symlink *directory-entry* replacement, not to file writes. Option (b) is strictly worse than (a): it still requires the deploy to write the sentinel, and it re-introduces the risk of systemd restarting a unit the deploy did not intend to restart. **Choose (a).**
- Even if a path unit did fire, it would introduce a correctness hazard for a deployment control plane: the unit would activate on *any* filesystem event matching the watch, including events from an unrelated tool, a manual `ln` by an operator, or a partially-completed deploy. Deploys must be driven by the deploy that performed them, not by ambient filesystem state.

### Gaps
- I did not read the linked issue #19726 (the PR that closed #17727). It is worth checking whether it closed the issue as wontfix/duplicate rather than by implementing a fix — that distinction matters for the report's confidence in "this will never be fixed". The evidence that it was not fixed is the still-open #31941 on systemd 255.2.
- I found no upstream maintainer statement of intent explaining the root cause; the mechanism above is my reconstruction from the two observed inotify event traces plus the `systemd.path(5)` semantics, not a maintainer-confirmed diagnosis. It is consistent with the data but should be presented as such.
- Whether any distro ships a backported fix for #31941 — unverified.

---

## Q3. systemd unit design for a symlinked release layout: stable unit file, `current` in `WorkingDirectory=`/`ExecStart=`, and when `daemon-reload` is actually needed

### Takeaway
The unit file must be **stable and outside the release tree**, referencing `/var/www/<app>/current/...`. systemd resolves the `ExecStart=` path at exec time (fork+execve happen when the start job runs, not when the unit is loaded), so `systemctl restart` picks up the new symlink target with **no** `daemon-reload` — `daemon-reload` is required only when the *unit file's own contents or location* change. Putting the unit file inside the release directory is a serious anti-pattern: it disappears on the next deploy, breaks rollback, and forces a `daemon-reload` on every deploy for no benefit.

### Cited Findings
- `WorkingDirectory=` "Takes a directory path relative to the service's root directory specified by `RootDirectory=`, or the special value `~`. Sets the working directory for executed processes. If set to `~`, the home directory of the user specified in `User=` is used. If not set, defaults to the root directory when systemd is running as a system instance and the respective user's home directory if run as user. **If the setting is prefixed with the `-` character, a missing working directory is not considered fatal.**" and, importantly: "Units with `WorkingDirectory=`, `RootDirectory=`, `RootImage=`, `RuntimeDirectory=`, `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` or `ConfigurationDirectory=` set automatically gain dependencies of type `Requires=` and `After=` on all mount units required to access the specified paths. This is equivalent to having them listed explicitly in `RequiresMountsFor=`." — `systemd.exec(5)`, read locally (also confirmed in the HTML rendering at [systemd.exec(5)](https://man7.org/linux/man-pages/man5/systemd.exec.5.html)).
- `ExecStart=` "Commands that are executed when this service is started." — `systemd.service(5)`, read locally.
- `Type=exec` semantics, which pin down *when* the path is resolved: "The exec type is similar to simple, but **the service manager will consider the unit started immediately after the main service binary has been executed**. The service manager will delay starting of follow-up units until that point. (Or in other words: simple proceeds with further jobs right after `fork()` returns, while exec will not proceed before both `fork()` and `execve()` in the service process succeeded.)" — `systemd.service(5)`, read locally.
- `User=` "Set the UNIX user or group that the processes are executed as... If `DynamicUser=` is not used the specified user and group must have been created statically in the user database no later than the moment the service is started, for example using the `sysusers.d(5)` facility, which is applied at boot or package install time. **If the user does not exist by then program invocation will fail.**" — `systemd.exec(5)`, read locally.

### Inferences
- **Proof that a restart picks up the new symlink target, from the documented `Type=exec` semantics.** `Type=exec` is defined as systemd waiting for "both `fork()` and `execve()` in the service process" to succeed *at the moment the unit is started*. `execve()` is what turns the string in `ExecStart=` into a kernel-resolved path. That resolution necessarily happens during the start job, i.e. after `mv -T current` has already run, and the kernel resolves the symlink chain at that instant. Nothing in systemd's documented model caches the resolved `ExecStart=` target at unit-load time. Therefore: `mv -T current` → `systemctl restart` runs the binary from the *new* release, deterministically, with no `daemon-reload`. The same holds for `WorkingDirectory=`: the `chdir()` is performed by the service manager as part of preparing the child for `execve()`, so it also sees the post-swap link. The `Type=exec` documentation is the strongest available evidence: it is written specifically to describe what happens between the manager's `fork()` and the child's `execve()`, which is exactly the window in which resolution occurs.
- **`daemon-reload` is required only when the unit file changes.** `systemctl daemon-reload` re-reads unit files from disk. Repointing `current` modifies no unit file — it changes a symlink in `/var/www`, which systemd has no reason to look at. Calling `daemon-reload` on every deploy is at best a no-op and at worst harmful: the systemd 233 release notes state "systemd will now refuse full configuration reloads (via `systemctl daemon-reload` and related calls) unless at least 16MiB of free space are available in `/run`", i.e. it can hard-fail a deploy on a full `/run` for zero benefit — [systemd-devel announce systemd 233](https://lists.freedesktop.org/archives/systemd-devel/2017-March/038419.html). **Shipyard should call `daemon-reload` if and only if it wrote a changed unit file.**
- **Failure mode of putting the unit file inside the release directory** (e.g. `/var/www/app/current/app.service` loaded via `systemctl link`):
  1. *It disappears.* On the next deploy, `current` points at a new release that does not contain `app.service`. systemd keeps the already-loaded unit in memory, but `FragmentPath` now dangles. After a reboot — or any `daemon-reload` triggered by an unrelated package install — the unit can no longer be found and the app does not start at all. This is a hard outage on reboot, discovered at the worst time.
  2. *It makes rollback impossible in a meaningful sense.* Rolling back means swapping `current` back; the "unit file" now reverts to whatever that older release shipped, which is an unversioned, unverified configuration change. There is no single audited unit file.
  3. *It forces `daemon-reload` every deploy anyway* — the exact cost the design was supposed to avoid — plus a race, because the unit file is not written atomically relative to the symlink swap.
  4. *It couples the unit's identity to content.* Two releases can disagree about `ExecStart=`, so "restart" becomes "restart with a possibly different unit", which invalidates `ActiveEnterTimestamp` / `NRestarts` / `FragmentPath` as reconciliation signals.
  5. `systemctl link` requires the linked file to be on a filesystem accessible at boot: "The file system where the linked unit files are located must be accessible when systemd is started (e.g. anything underneath `/home/` or `/var/` is not allowed, unless those directories are located on the root file system)." — `systemctl(1)` (via [search excerpt of systemctl(1)](https://www.freedesktop.org/software/systemd/man/249/systemctl.html)). `/var/www` qualifies only if it is on the root filesystem, so a separate `/var` partition breaks `systemctl link` too.
- **Recommended layout.** Unit lives in `/etc/systemd/system/<app>.service` (stable, on the root fs, version-controlled by Shipyard's own config store, not by the app's release artifact). `current` is referenced only inside `WorkingDirectory=` and `ExecStart=`. The `RequiresMountsFor=` implication of `WorkingDirectory=` is a bonus: it means the unit will not start before `/var/www` is mounted, which is exactly the ordering guarantee a deploy tool wants — and it is obtained for free by naming the path in `WorkingDirectory=`.
- **Do not prefix `WorkingDirectory=` with `-`.** The `-` prefix (missing working dir is not fatal) is a trap here: if `current` is briefly absent or the release dir is removed, a `-`-prefixed unit would start the app in `/` instead of failing loudly. Fail the deploy instead.

### Gaps
- I could not find an upstream statement that literally says "the `ExecStart=` path is resolved at exec time, not at unit-load time." The conclusion is an inference from the `Type=exec` documentation (which describes `fork()`/`execve()` as occurring at start-job time) plus the absence of any documented caching. It is very strong, but it is an inference. A direct empirical test on a live host (`mv -T` the symlink, `systemctl restart`, read `/proc/<MainPID>/exe` and `$PWD` of the main process) would convert it to a verified fact; **Shipyard's own integration tests should perform exactly this test**, since it is the load-bearing assumption of the whole design.
- I did not verify the `systemctl(1)` text for `daemon-reload` verbatim (the local page grep only surfaced `reload-or-restart` and `try-reload-or-restart`). The 16MiB-`/run` failure mode is sourced from the v233 release announcement, not from the current `daemon-reload` man entry.

### Concrete unit file (stable, outside the release tree)
```ini
# /etc/systemd/system/blog.service
# STABLE. Never shipped inside a release. Only change this file through
# Shipyard's config store, and only then run `systemctl daemon-reload`.

[Unit]
Description=blog (Shipyard-managed)
Documentation=https://<app>/deploy
# StartLimit* live in [Unit], NOT [Service] (they moved in v230).
# Counts *all* starts, including the deploy's own `systemctl restart`
# and a rollback restart — size the burst accordingly.
StartLimitIntervalSec=60s
StartLimitBurst=5
After=network-online.target
Wants=network-online.target

[Service]
# --- identity ---------------------------------------------------------
# `exec` (systemd >= 240): systemd waits for BOTH fork() and execve().
# Without it, `systemctl start` reports success even when the binary is
# missing or User= does not exist — a broken deploy looks like a good one.
# Use `notify` instead only if the app implements sd_notify READY=1.
Type=exec
User=blog
Group=blog

# --- release-independence --------------------------------------------
# These two lines are the whole point. They name `current`, never a
# release. systemd resolves them during the start job (at chdir()/execve()
# time), so `mv -T current` + `systemctl restart` picks up the new
# release with NO daemon-reload.
WorkingDirectory=/var/www/blog/current
ExecStart=/var/www/blog/current/bin/blog

# --- graceful reload --------------------------------------------------
# "kill -HUP $MAINPID" enqueues a signal WITHOUT completion notification,
# which systemd.service(5) calls out as "usually not a good choice, because
# this is an asynchronous operation and hence not suitable when ordering
# reloads of multiple services against each other". For a deploy tool that
# must know when the reload finished, do the wait explicitly:
ExecReload=/bin/kill -HUP $MAINPID
# ...and have the deploy script poll until the port answers /healthz.
# Alternatively drop ExecReload= entirely and use
#   Type=notify-reload
# (systemd sends SIGHUP itself and waits for RELOADING=1 + READY=1).
# NOTE: a code deploy needs `restart`, not `reload` — reload only
# re-reads configuration. See Q7.

# --- drain & exit -----------------------------------------------------
KillMode=mixed            # default is control-group; mixed is safer for
                          # apps that fork workers (sends SIGTERM to main,
                          # SIGKILL to the rest after TimeoutStopSec)
KillSignal=SIGTERM
TimeoutStopSec=30s        # drain window for in-flight requests; after this,
                          # SIGKILL. Set >= the app's longest request.
SendSIGKILL=yes
# EXTEND_TIMEOUT_USEC= lets a Type=notify service push the deadline out
# while it finishes draining (must be sent before TimeoutStopSec elapses).

# --- crash-loop policy ------------------------------------------------
# on-failure, NOT always: `always` restarts even after a clean exit, so a
# misconfigured app that exits 0 on error spins forever.
# Default RestartSec is only 100ms — that alone will race a health check.
Restart=on-failure
RestartSec=5s
# (systemd >= 254) exponential backoff, so a crash-looping app stops
# hammering the CPU while the deploy's health check is polling:
# RestartSteps=4
# RestartMaxDelaySec=160s

# --- restart suppression ---------------------------------------------
# Keep a crash loop from being retried forever on a *clean* signal exit.
# RestartPreventExitStatus=

# --- liveness (systemd-native) ---------------------------------------
# If the app supports sd_notify, WatchdogSec= is a much better liveness
# signal than an HTTP probe: systemd itself kills and restarts a service
# that stops pinging, and records the reason in Result=watchdog.
# WatchdogSec=30s

# --- logging ----------------------------------------------------------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=blog

# --- writable state, OUTSIDE the release tree ------------------------
# Never let the app write into current/ — it is a symlink into an
# immutable release, and the write is lost (or corrupts the artifact)
# on the next swap.
StateDirectory=blog        # /var/lib/blog, owned by User=
CacheDirectory=blog        # /var/cache/blog

# --- hardening (all verified present in systemd.exec(5)) -------------
NoNewPrivileges=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
# MUST re-allow the state/cache dirs; ProtectSystem=strict is implied
# to make everything read-only except:
ReadWritePaths=/var/lib/blog /var/cache/blog
# ProtectHome=yes is implied to tmpfs; if ProtectHome=yes is used,
# BindPaths=/ ReadWritePaths= destinations must exist beforehand.

[Install]
WantedBy=multi-user.target
```

---

## Q4. `Type=simple` vs `Type=notify` vs `Type=exec`, and what "active" means for each

### Takeaway
For "started must mean actually serving", `Type=notify` is the only type that makes systemd's own notion of `active` correspond to readiness — at the cost of the app having to implement `sd_notify(3)`. `Type=exec` is the correct *fallback* and is strictly better than `simple` because it catches exec failures, but it still only means "the binary was invoked". `Type=simple` is actively wrong for a deploy tool because `systemctl start` reports success even when the binary could not be executed at all.

### Cited Findings
- `Type=` "Configures the mechanism via which the service notifies the manager that the service start-up has finished. One of simple, exec, forking, oneshot, dbus, notify, notify-reload, or idle:"
- `simple` (the default when `ExecStart=` is set and neither `Type=` nor `BusName=` are set, and credentials are not used): "the service manager will consider the unit started immediately after the main service process has been forked off (i.e. immediately after `fork()`, and before various process attributes have been configured and in particular before the new process has called `execve()` to invoke the actual service binary). **Typically, `Type=exec` is the better choice, see below.** ... **Note that this means `systemctl start` command lines for simple services will report success even if the service's binary cannot be invoked successfully** (for example because the selected `User=` does not exist, or the service binary is missing)."
- `exec`: "the service manager will consider the unit started immediately after the main service binary has been executed. The service manager will delay starting of follow-up units until that point... Note that this means `systemctl start` command lines for exec services will report failure when the service's binary cannot be invoked successfully... **This type is implied if credentials are used**."
- Recommendation: "**It is recommended to use `Type=exec` for long-running services**, as it ensures that process setup errors (e.g. errors such as a missing service executable, or missing user) are properly tracked. However, as this service type **will not propagate the failures in the service's own startup code** (as opposed to failures in the preparatory steps the service manager executes before `execve()`) **and does not allow ordering of other units against completion of initialization of the service code itself** (which for example is useful if clients need to connect to the service through some form of IPC...), it might not be sufficient for many cases. If so, notify, notify-reload, or dbus... are the [alternatives]."
- `notify`: "Behavior of notify is similar to exec; however, it is expected that the service sends a `READY=1` notification message via `sd_notify(3)` or an equivalent call when it has finished starting up. systemd will proceed with starting follow-up units after this notification message has been sent. If this option is used, `NotifyAccess=` should be set to open access to the notification socket provided by systemd. **If `NotifyAccess=` is missing or set to none, it will be forcibly set to main.**" ... "If the service supports reloading, and uses a signal to start the reload, using notify-reload instead is recommended."
- `notify-reload`: "Behavior of notify-reload is similar to notify, with one difference: the SIGHUP UNIX process signal is sent to the service's main process when the service is asked to reload and the manager will wait for a notification about the reload being finished. When initiating the reload process the service is expected to reply with a notification message via `sd_notify(3)` that contains the `RELOADING=1` field in combination with `MONOTONIC_USEC=` set to the current monotonic time... Once reloading is complete another notification message must be sent, containing `READY=1`. ... The signal to send can be tweaked via `ReloadSignal=`. For notify-reload services, systemd verifies that the service's main process has actually installed a handler for the configured [signal]..."
- `forking`: "The use of this type is discouraged, use notify, notify-reload, or dbus instead."
- **Version + 262 behavioural change for `notify-reload`.** `systemd 253` NEWS: "A new service type `Type=notify-reload` is defined. When such a unit is reloaded a UNIX process signal (typically SIGHUP) is sent to the main service process. The manager will then wait until it receives a 'RELOADING=1' followed by a 'READY=1' notification from the unit as response (via `sd_notify()`). Otherwise, this type is the same as `Type=notify`. A new setting `ReloadSignal=` may be used to change the signal to send from the default of SIGHUP." → both **`Type=notify-reload` and `ReloadSignal=` are systemd 253** (local `systemd.service(5)` annotates `ReloadSignal=` "Added in version 253"). **`systemd 262` NEWS is a breaking change:** "Services of `Type=notify-reload` are now required to catch or block `ReloadSignal=` when they send `READY=1`. If they do neither at that point, they will fail with a protocol error." So a `notify-reload` app must have its signal handler installed (or the signal blocked) *before* it sends `READY=1`, or it fails to start on 262.
- `WatchdogSec=`: "Configures the watchdog timeout for a service. The watchdog is activated when the start-up is completed. The service must call `sd_notify(3)` regularly with `WATCHDOG=1` (i.e. the `keep-alive ping`). If [it does not]..." — `systemd.service(5)`, read locally.
- `Type=exec` "Added in version 240" — systemd 240 release announcement: "A new service type has been added: `Type=exec`. It's very similar to `Type=simple` but ensures the service manager will wait for both `fork()` and `execve()` of the main service binary to complete before proceeding with follow-up units." — [systemd-devel: systemd 240 released](https://lists.freedesktop.org/archives/systemd-devel/2018-December/041852.html). Corroborated independently: "systemd 240 introduces a new `Type=exec`, which like `Type=simple`, but better in the sense that it communicates failures in `exec()` back to" — [NixOS/nixpkgs#51332](https://github.com/NixOS/nixpkgs/issues/51332)

### Inferences
- **What systemd considers "active" for each type:**
  - `simple` → `ActiveState=active` the instant `fork()` returns, i.e. *before the binary has been executed*. A `systemctl is-active` poll can return `active` for a process that does not exist.
  - `exec` → `ActiveState=active` immediately after `execve()` succeeded, `SubState=running`. The process exists and the binary loaded, but it may still be parsing config / binding / warming caches. "Actually serving" is **not** guaranteed.
  - `notify` → `ActiveState=activating`, `SubState=start` until `READY=1` arrives; then `ActiveState=active`, `SubState=running`. This is the only type where `ActiveState=active` is a *readiness* assertion rather than a *liveness* assertion. If the app never notifies, the unit stays `activating` until `TimeoutStartSec=` elapses, at which point it is killed and marked `failed` — a **fail-closed** outcome that is exactly what a deploy tool wants, but note it makes a naive "wait for active" health check hang for the full `TimeoutStartSec` instead of failing fast.
  - `forking` → the old "started when the parent exits" heuristic, discouraged upstream; it races anything you want to measure.
- **`Type=notify` + a health check is a good pairing but not a substitute for one.** `READY=1` is a promise from the app about *its own* startup; the deploy additionally needs to prove the request path works end to end (nginx → upstream). Use both: `Type=notify`/`WatchdogSec=` for systemd's internal state machine, and an HTTP probe against the app's own port for the deploy's verdict.
- **Practical recommendation for Shipyard:** two tiers.
  - Apps that can call `sd_notify(3)`: `Type=notify` + `WatchdogSec=30s` + `NotifyAccess=main` (default when unset). systemd becomes the source of truth for "serving", and `WatchdogSec` gives a real liveness signal that no HTTP probe can match (it survives a hung-but-accepting event loop only if the app pings; conversely it catches a process that is alive but has wedged).
  - Apps that cannot: `Type=exec` (never `Type=simple`) + a deploy-owned HTTP readiness probe + `systemctl show` reconciliation of `ActiveState`/`SubState`/`Result`/`NRestarts` (see Q5/Q6). Document per app that systemd's `active` here means "invoked", not "serving", so nobody downstream mistakes the former for the latter.
- **Never use `Type=forking`** for a Shipyard app: it makes the main-PID determination heuristic, which corrupts every signal in Q6 and Q7 (`$MAINPID` in `ExecReload=`, `MainPID` in `systemctl show`).
- `ExecCondition=` (systemd ≥ 243) is a tempting place to put a "does this release pass its own preflight" check, and it is worse than a deploy-script check: it runs as part of the activation transition, so "a skip causes the unit to transition from `active` to `inactive`" — meaning a unit that was already running goes to `inactive` (stopped) rather than staying on the old release. Shipyard must not let a failed release take the old one down.

### Gaps
- ~~Minimum version for `Type=notify-reload` is unconfirmed.~~ **RESOLVED (v253):** the systemd 253 NEWS entry introduces `Type=notify-reload` and `ReloadSignal=`, and the local `systemd.service(5)` annotates `ReloadSignal=` "Added in version 253". The `Type=` entry itself is un-annotated, but the NEWS + the `ReloadSignal=` annotation bracket it to **253**. **Do not emit `Type=notify-reload` unconditionally if Shipyard supports systemd < 253.** Feature-detect with `systemd-analyze verify` on the unit and fall back to `ExecReload=`.
- **`ReloadSignal=` is systemd 253** (local man page annotation). Also note the **262 breaking change**: a `notify-reload` service must catch or block `ReloadSignal=` before sending `READY=1`, else it fails with a protocol error (see Cited Findings).
- I did not read `sd_notify(3)` directly, so the exact wire format of `READY=1` / `RELOADING=1` / `WATCHDOG=1` / `EXTEND_TIMEOUT_USEC=` is taken from `systemd.service(5)` quotations only.

---

## Q5. `Restart=` policies, `RestartSec=`, the health-check race, and detecting a crash loop

### Takeaway
Use `Restart=on-failure` with a **non-default `RestartSec=`** (the default is 100 ms — far too fast) plus a deliberate `StartLimitIntervalSec`/`StartLimitBurst` pair. The start-rate limiter is the mechanism that turns a crash loop into a terminal `failed` state rather than an infinite flapping one, and that terminal state is what a deploy health check must look for. The core trap: a health check that only polls HTTP can observe a briefly-open port during a fast restart cycle and declare a crash-looping deploy "healthy".

### Cited Findings
- `Restart=` "Configures whether the service shall be restarted when the service process exits, is killed, or a timeout is reached. The service process may be the main service process, but it may also be one of the processes specified with `ExecStartPre=`, `ExecStartPost=`, `ExecStop=`, `ExecStopPost=`, or `ExecReload=`. **When the death of the process is a result of systemd operation (e.g. service stop or restart), the service will not be restarted.** Timeouts include missing the watchdog 'keep-alive ping' deadline and a service start, reload, and stop operation timeouts."
- Values: `no` (default), `on-success`, `on-failure`, `on-abnormal`, `on-watchdog`, `on-abort`, `always`. "If set to `always`, the service will be restarted regardless of whether it exited cleanly or not, got terminated abnormally by a signal, or hit a timeout. Note that `Type=oneshot` services will never be restarted on a clean exit status, i.e. `always` and `on-success` are rejected for them."
- Clean-exit definition (relevant to `on-success`): "an exit code of 0; for types other than `Type=oneshot`, one of the signals SIGHUP, SIGINT, SIGTERM, or SIGPIPE; exit statuses and signals specified in `SuccessExitStatus=`."
- Full exit-cause × policy table (reproduced from the man page):

  | Exit cause | `no` | `always` | `on-success` | `on-failure` | `on-abnormal` | `on-abort` | `on-watchdog` |
  |---|---|---|---|---|---|---|---|
  | Clean exit code or signal | | X | X | | | | |
  | Unclean exit code | | X | | X | | | |
  | Unclean signal | | X | | X | X | X | |
  | Timeout | | X | | X | X | | |
  | Watchdog | | X | | X | X | | X |
  | Termination due to OOM | | X | | X | X | | |

- "As exceptions to the setting above, the service will not be restarted if the exit code or signal is specified in `RestartPreventExitStatus=` or the service is stopped with `systemctl stop` or an equivalent operation. Also, the services will always be restarted if the [start rate limit is not hit]..."
- `RestartSec=` "Configures the time to sleep before restarting a service (as configured with `Restart=`). Takes a unit-less value in seconds, or a time span value such as '5min 20s'. **Defaults to 100ms.**"
- `RestartSteps=` "Configures the number of exponential steps to take to increase the interval of auto-restarts from `RestartSec=` to `RestartMaxDelaySec=`. Takes a positive integer or 0 to disable it. Defaults to 0. Hint: values between 3 and 5 are good choices when exponential backoff is desired." Example given: `RestartSec=10s` / `RestartSteps=4` / `RestartMaxDelaySec=160s`. (`RestartSteps=` and `RestartMaxDelaySec=` are "Added in version 254" per the local man page.)
- `StartLimitIntervalSec=interval, StartLimitBurst=burst` (these live in **`[Unit]`**, not `[Service]`): "Configure unit start rate limiting. **Units which are started more than `burst` times within an interval time span are not permitted to start any more.** Use `StartLimitIntervalSec=` to configure the checking interval and `StartLimitBurst=` to configure how many starts per interval are allowed. ... The special value `infinity` can be used to limit the total number of start attempts, even if they happen at large time intervals. Defaults to `DefaultStartLimitIntervalSec=` in manager configuration file, and may be set to 0 to disable any kind of rate limiting. `burst` is a number and defaults to `DefaultStartLimitBurst=` in manager configuration file. **These configuration options are particularly useful in conjunction with the service setting `Restart=` (see `systemd.service(5)`); however, they apply to all kinds of starts (including manual), not just those [driven by `Restart=`]**." — `systemd.unit(5)`, read locally.
- `TimeoutStopSec=` "Second, it configures the time to wait for the service itself to stop. If it does not terminate in the specified time, it will be forcibly terminated by SIGKILL (see `KillMode=` in `systemd.kill(5)`). ... Pass `infinity` to disable the timeout logic. Defaults to `DefaultTimeoutStopSec=` from the manager configuration file." and "If a service of `Type=notify`/`Type=notify-reload` sends `EXTEND_TIMEOUT_USEC=...`, this may cause the stop time to be extended beyond `TimeoutStopSec=`. The first receipt of this message must occur before `TimeoutStopSec=` is exceeded..." — `systemd.service(5)`, read locally.

### Inferences
- **The health-check race, stated precisely.** With `Restart=on-failure` and `RestartSec=1s` (or the 100 ms default), a crash-looping app has a listen socket open for whatever fraction of each cycle it survives startup. An HTTP health check that polls on a 500 ms–2 s interval will, with high probability, hit one of those open windows and return 200. Worse, the check may succeed on the *first* probe if the first attempt got far enough to bind before dying. The deploy then reports success, and the service is still flapping. Two independent defences are needed:
  1. **Compare `NRestarts` across the whole health-check window**, not just at the end. If `NRestarts` increased at all during the observation period, the deploy is not healthy regardless of what the HTTP probe said. `systemctl show -p NRestarts --value <unit>` is cheap and authoritative.
  2. **Require a stability dwell**: the unit must hold `ActiveState=active` / `SubState=running` with an unchanged `NRestarts` for a continuous period (e.g. 10 s) that exceeds `RestartSec`, before the deploy is called good.
- **`NRestarts` is the right primary signal because `Result` is not enough.** `Result` reflects the *last* exit condition; during a flapping loop it reads whatever the most recent exit was, and once systemd finally gives up (rate limit hit) it reads `exit-code`/`signal` — but the unit must first *reach* that state. `NRestarts` is a monotonic counter over the unit's current life and is the cheapest early-warning signal. **`NRestarts` is systemd 235** — systemd 235 NEWS: "For each service unit a restart counter is now kept: it is increased each time the service is restarted due to `Restart=`, and may be queried using `systemctl show -p NRestarts …`." It is not in the `systemctl(1)`/`systemd.service(5)` man pages (it is a D-Bus property), which is why it is easy to miss.
- **Rate limiting is the designed circuit breaker, and it is fail-safe if you set it deliberately.** Without `StartLimitBurst`/`StartLimitIntervalSec` tuned, defaults come from `DefaultStartLimitBurst=`/`DefaultStartLimitIntervalSec=` in the manager config, which vary by distro. Set them explicitly in the unit so a crash loop is guaranteed to terminate in bounded time and land in a hard `failed` state. **Important and easy to get wrong: the rate limiter "applies to all kinds of starts (including manual)".** A deploy that does `restart` → health check → rollback `restart` → health check can consume 4 starts on its own. With a tight `StartLimitBurst=5` a deploy that retries a few times can trip the limiter, leaving the unit in `failed` with "start request repeated too quickly" and **no** further auto-restart. Size `StartLimitBurst` for deploy retries (e.g. 10 over 5 min) and have the deploy *reset* the counter with `systemctl reset-failed <unit>` before the first start of a deploy attempt.
- **Prefer `on-failure` over `always`.** `always` restarts even on a clean exit and on SIGHUP/SIGINT/SIGTERM/SIGPIPE-equivalent clean signals, so a config-error path that calls `sys.exit(0)` spins forever and the health check sees a permanently flapping-but-sometimes-listening app. `on-failure` will not restart after SIGTERM, so `systemctl stop` and `systemctl restart` are clean — the deploy is never fighting its own supervisor.
- **The critical reassurance for a deploy tool:** "When the death of the process is a result of systemd operation (e.g. service stop or restart), the service will not be restarted." This means a `systemctl restart` during a deploy will *not* be undone by systemd resurrecting the pre-restart process, and a `systemctl stop` for rollback will stick. Without this, every deploy would race the supervisor.
- **`RestartSec=` also sets the floor on how fast a crash loop can consume CPU.** The 100 ms default is a CPU-burner and a health-check flapper. `RestartSec=5s` plus (systemd ≥ 254) `RestartSteps=4` / `RestartMaxDelaySec=160s` gives exponential backoff so a crash loop is cheap while the deploy decides to roll back. Note the backoff's interaction with the deploy: the dwell time requirement in the health check must be measured against the *current* backoff, not `RestartSec`, or the check will be slower than necessary. Simplest safe design: a fixed `RestartSec=` and no backoff, so timing is predictable for the deploy.

### Gaps
- ~~`NRestarts` is not documented in any of the systemd man pages I read.~~ **RESOLVED (v235):** it is a D-Bus property introduced in systemd **235** (NEWS: "For each service unit a restart counter is now kept … queried using `systemctl show -p NRestarts …`"). It is absent from the man pages because properties are not listed there. Still **feature-detect at runtime** (`systemctl show -p NRestarts --value <unit>`; absent → fall back to `ActiveEnterTimestamp` diffs / `StartLimit` saturation), because a host may predate 235.
- **`NRestarts` reset semantics: still unverified.** Whether it resets on `systemctl restart`, `reset-failed`, `daemon-reload`, or only on a state transition to inactive is unknown and directly affects whether it can serve as a per-deploy counter. **Must be measured empirically on the target host before relying on it.** Given the NEWS wording ("increased each time the service is restarted due to `Restart=`"), the working hypothesis is that it counts *automatic restarts only* and is **not** incremented by a deploy-initiated `systemctl restart`, which would make it a poor "did the deploy take effect" signal but a good crash-loop signal — but that hypothesis is unverified and must not be relied on until measured.
- I did not verify the exact `Result=` string values (`exit-code`, `signal`, `core-dump`, `timeout`, `watchdog`, `start-limit-hit`, `protocol`, `success`) against a current man page. I have only the enumeration of *causes* from the `Restart=` table. The `Result` value strings should be confirmed before they are used as string comparisons in Shipyard.
- Whether `StartLimitIntervalSec=`/`StartLimitBurst=` moved from `[Service]` to `[Unit]` at exactly v230 — I observed them documented in `[Unit]` in the current man page, which is the operationally important fact, but did not locate the change note.

---

## Q6. `systemctl show` properties worth reading for reconciliation

### Takeaway
Reconciliation must read **runtime** properties, not the unit file: `ActiveState`, `SubState`, `Result`, `ExecMainStatus`, `NRestarts`, `MainPID`, `UnitFileState`, `ActiveEnterTimestamp`, `InvocationID`, `FragmentPath`. Use `systemctl show -p A,B,C --value` with `--value`/`-P`, always as root, and always check the exit status. The single most valuable property for a deploy control plane is `InvocationID`, because it is the only stable, systemd-assigned identifier for *one specific start* of a service.

### Cited Findings
- `-p, --property=`: "When showing unit/job/manager properties with the `show` command, limit display to properties specified in the argument. **The argument should be a comma-separated list of property names**, such as 'MainPID'. Unless specified, all known properties are shown. If specified more than once, all properties with the specified names are shown." — `systemctl(1)`, read locally (also at [Ubuntu systemctl(1)](https://manpages.ubuntu.com/manpages/bionic/man1/systemctl.1.html)).
- `show [PATTERN…]`: "Show properties of one or more units, jobs, or the manager itself. If no argument is specified, properties of the manager will be shown. **By default, empty properties are suppressed. Use `--all` to show those too.** To select specific properties to show, use `--property=`. **This command is intended to be used whenever computer-parsable output is required. If you are looking for formatted human-readable output, use `status` instead.** Many properties shown by `systemctl show` map directly to configuration settings of the system and service manager and its unit files. Note that the properties shown by the command are generally more low-level, normalized versions of the original configuration settings and expose runtime state in addition to configuration." — `systemctl(1)`, read locally (also at [freedesktop systemctl(1)](https://www.freedesktop.org/software/systemd/man/latest/systemctl.html) and [ALT Linux systemctl(1)](https://manpages.altlinux.team/p11/s/systemd/systemctl.1.html)).
- `-P` is "Equivalent to `--value` `--property=`, i.e. shows the value of the property without the property name or ' = '." and is **"Added in version 246"** — `systemctl(1)`, read locally.
- `-I, --invocation=ID[±offset]|offset`: "Show messages from a specific invocation of unit. This will add a match for `_SYSTEMD_INVOCATION_ID=`, `OBJECT_SYSTEMD_INVOCATION_ID=`, `INVOCATION_ID=`, `USER_INVOCATION_ID=`. ... **-I is equivalent to `--invocation=0`, and logs for the latest invocation will be shown.** When an offset is specified, a unit name must be specified with `-u/--unit=` or `--user-unit=` option. **Added in version 257.**" — `journalctl(1)`, read locally (also at [man7.org journalctl(1)](https://man7.org/linux/man-pages/man1/journalctl.1.html)). **Read the arity carefully: the sentence "-I is equivalent to `--invocation=0`" means the short `-I` takes NO argument; the synopsis line `-I, --invocation=ID…` is misleading. See Q8 Cited Findings for the verified failure (`-I <ID>` → `Failed to add match '<ID>': Invalid argument`). Use `--invocation=<ID>` or `_SYSTEMD_INVOCATION_ID=<ID>`.**

### Inferences
- **Which properties reveal true host state, and why:**
  - `ActiveState` — coarse lifecycle: `active` / `activating` / `deactivating` / `inactive` / `failed`. This is the one to gate the deploy on. A unit in `failed` is terminal until someone acts.
  - `SubState` — fine-grained, and the only way to distinguish "activating" from "actually up": `running` / `start` / `start-post` / `reload` / `stop` / `dead` / `auto-restart` / `failed`. **`SubState=auto-restart` is the definitive crash-loop signal** — it means systemd is between the crash and the next `RestartSec` sleep, and it is directly visible rather than inferred from a counter.
  - `Result` — why the last activation ended: `success` / `exit-code` / `signal` / `core-dump` / `timeout` / `watchdog` / `start-limit-hit` / `protocol`. This is the "why" that turns a `failed` into an actionable deploy error.
  - `ExecMainCode` + `ExecMainStatus` — the raw exit code/signal of the main process. `ExecMainStatus` alone is ambiguous (a signal death and an exit code are both integers); `ExecMainCode` disambiguates (`exited` vs `killed`).
  - `NRestarts` — the crash counter. See Q5's caveats.
  - `MainPID` — non-zero iff there is a live main process. Cheap liveness cross-check that does not depend on `ActiveState` being accurate.
  - `UnitFileState` — `enabled` / `enabled-runtime` / `disabled` / `static` / `masked` / `bad`. Detects the class of deploy failure where the unit was never enabled and the app is running only because someone started it manually. Also detects `masked`, which makes `systemctl restart` fail confusingly.
  - `ActiveEnterTimestamp` — monotonic-ish record of when the unit last became active. Use it to answer "did my restart actually take effect and *when*", and to detect a deploy that reported success but whose restart was a no-op (timestamp unchanged).
  - `FragmentPath` — the path of the unit file systemd actually loaded. This is the reconciliation key for the "is the installed unit what Shipyard thinks it installed" question, and it makes the "unit file inside the release directory" anti-pattern immediately visible (it will be a `/var/www/...` path).
  - `InvocationID` — a fresh 128-bit ID assigned per start. **This is the important one.** Record it immediately after `systemctl restart` returns, store it with the deploy record, and use `journalctl _SYSTEMD_INVOCATION_ID=$InvocationID` (or, on ≥257, `journalctl --invocation=$InvocationID`) to scope log capture to exactly that one start — no timestamp arithmetic, no cursor, immune to clock changes and to unrelated concurrent logs. **Do NOT write `journalctl -u <unit> -I $InvocationID`** — `-I` takes no argument (it means `--invocation=0`, latest) and the ID becomes a positional match, failing with `Failed to add match '<ID>'`. The property and `$INVOCATION_ID` are **systemd 232** (NEWS, CHANGES WITH 232: "The invocation ID of a service is passed to the service itself via an environment variable (`$INVOCATION_ID`)"; `GetUnitByInvocationID()` added); the `--invocation=` *reader* option is 257, but the raw field match removes that floor.
  - `LoadState` / `ConditionResult` — `LoadState=not-found` distinguishes "unit missing" from "unit present but failed", which are very different deploy errors.
- **`--value`/`-P` is the right mode for scripted reconciliation**, because it strips the `Name=` and `=` decorations, but it requires systemd ≥ 246. On older systemd, parse `Property=value` lines yourself and anchor on `^<prop>=`.
- **Always run as root.** `systemctl show` on a system unit requires privileges for the full property set; a non-root call may return empty/partial values (and `systemctl` exits non-zero), which a naive parser reads as "unit is dead".

### Gaps
- ~~Minimum systemd version for the `NRestarts` property: not found.~~ **RESOLVED: systemd 235** (NEWS, CHANGES WITH 235: "For each service unit a restart counter is now kept … queried using `systemctl show -p NRestarts …`"). Still feature-detect at runtime in case the host predates it.
- ~~Minimum version for `InvocationID` as a `systemctl show` property: not confirmed.~~ **RESOLVED: systemd 232** for the invocation-ID concept, the `$INVOCATION_ID` environment variable, and `GetUnitByInvocationID()` (NEWS, CHANGES WITH 232). The `journalctl --invocation=` *consumer* option is 257; the raw field match `_SYSTEMD_INVOCATION_ID=` works from 232.
- **The illustrative output below was partly captured from a live host and is otherwise reconstructed.** This session's host **does** run systemd (systemd **262**, `systemctl --version` = "systemd 262 (262-1-arch)"), so `systemctl show`, `systemctl --version` and `journalctl` were executed successfully and the invocation/cursor behaviours were measured (see Q8). What remains unverified on a *deploy target* is the unit-specific behaviour: the exact `Result=`/`SubState=` value spellings under real failures, `NRestarts` reset semantics, and the `current`-symlink/restart interaction (Q3). **Shipyard must validate those against a real target host before shipping string comparisons.**

### Concrete reconciliation invocation
```bash
# Snapshot runtime state as machine-readable key=value (one call, one line
# per property). Run as root. Non-zero exit => unit unknown or no D-Bus
# access; treat as "cannot determine", never as "unit is down".
systemctl show \
  -p LoadState \
  -p ActiveState \
  -p SubState \
  -p Result \
  -p ExecMainCode \
  -p ExecMainStatus \
  -p MainPID \
  -p NRestarts \
  -p UnitFileState \
  -p ActiveEnterTimestamp \
  -p ActiveEnterTimestampMonotonic \
  -p InvocationID \
  -p FragmentPath \
  --no-pager blog.service
```

Expected shape (values illustrative — see Gap):
```
LoadState=loaded
ActiveState=active
SubState=running
Result=success
ExecMainCode=exited
ExecMainStatus=0
MainPID=18422
NRestarts=0
UnitFileState=enabled
ActiveEnterTimestamp=Tue 2026-09-29 11:04:07 UTC
ActiveEnterTimestampMonotonic=1d 4h 22m 11.902s ago
InvocationID=3f2a9c1e7b5d4a8ea0c61d2b8e4f70915
FragmentPath=/etc/systemd/system/blog.service
```

And the crash-loop / failed shape:
```
LoadState=loaded
ActiveState=failed
SubState=auto-restart        # or SubState=failed once rate-limited
Result=start-limit-hit       # or exit-code / signal
ExecMainCode=exited
ExecMainStatus=1
MainPID=0
NRestarts=11
UnitFileState=enabled
FragmentPath=/etc/systemd/system/blog.service
```

Healthy-but-broken-decode for scripting (values only, in the order requested, so it is positional and safe):
```bash
mapfile -t st < <(systemctl show --property=ActiveState,SubState,Result,NRestarts,MainPID --value --no-pager blog.service)
(( ${#st[@]} == 5 )) || { echo "cannot determine state" >&2; exit 1; }
if [[ ${st[0]} != active || ${st[1]} != running || ${st[3]} -gt ${N_RESTARTS_AT_DEPLOY_START} || ${st[4]} -eq 0 ]]; then
  echo "not healthy: ActiveState=${st[0]} SubState=${st[1]} Result=${st[2]} NRestarts=${st[3]}" >&2
  exit 1
fi
```

---

## Q7. Graceful reload: `ExecReload=`, SIGHUP, draining with `KillSignal=SIGTERM` + `TimeoutStopSec`, and `reload-or-restart`

### Takeaway
A `kill -HUP $MAINPID` `ExecReload=` is explicitly discouraged by systemd upstream for anything that needs to know when the reload finished, because it is asynchronous. For a deploy control plane, use either `Type=notify-reload` (systemd sends SIGHUP and waits for `RELOADING=1` + `READY=1`) or an `ExecReload=` that blocks until the app confirms. Critically: **reload is for configuration, not code** — a Shipyard code deploy must `restart`.

### Cited Findings
- `ExecReload=` "Commands to execute to trigger a configuration reload in the service. This setting may take multiple command lines... One additional, special environment variable is set: if known, `$MAINPID` is set to the main process of the daemon, and may be used for command lines like the following: `ExecReload=kill -HUP $MAINPID`. **Note however that reloading a daemon by enqueuing a signal without completion notification (as is the case with the example line above) is usually not a good choice, because this is an asynchronous operation and hence not suitable when ordering reloads of multiple services against each other. It is thus strongly recommended to either use `Type=notify-reload`, or to set `ExecReload=` to a command that not only triggers a configuration reload of the daemon, but also synchronously waits for it to complete.**" (the man page's own example of a good one is `ExecReload=busctl call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus ReloadConfig`.)
- `ExecReloadPost=` "Commands to execute after a successful reload operation. Syntax for this setting is exactly the same as `ExecReload=`." — **Added in version 259.**
- `Type=notify-reload` behaviour is quoted in full in Q4 above, including: "the SIGHUP UNIX process signal is sent to the service's main process when the service is asked to reload and the manager will wait for a notification about the reload being finished", the `RELOADING=1` + `MONOTONIC_USEC=` handshake, "Once reloading is complete another notification message must be sent, containing `READY=1`", `ReloadSignal=` to change the signal, and "systemd verifies that the service's main process has actually installed a handler for the configured [signal]".
- `TimeoutStopSec=` (quoted in Q5): waits `TimeoutStopSec=` for the service itself to stop, "If it does not terminate in the specified time, it will be forcibly terminated by SIGKILL"; a `Type=notify` service can extend the deadline with `EXTEND_TIMEOUT_USEC=`, but "The first receipt of this message must occur before `TimeoutStopSec=` is exceeded".
- `KillMode=` **"Defaults to control-group."** — `systemd.kill(5)`, read locally. The default escalation sequence is: send the configured stop signal (changed via `KillSignal=` or `RestartKillSignal=`), "Optionally, this is immediately followed by a SIGHUP (if enabled with `SendSIGHUP=`)"... then "If processes still remain after: the main process of a unit has exited (applies to `KillMode=`: mixed); the delay configured via the `TimeoutStopSec=` has passed (applies to `KillMode=`: control-group, mixed, process)..." send SIGKILL using `FinalKillSignal=`.
- `ExecCondition=`, "Added in version 243", with the important caveat already quoted in Q4: "Because `ExecCondition=` runs as part of the activation transition, a skip causes the unit to transition from `active` to `inactive`, and consequently `SuccessAction=` will be honored."
- `systemctl reload-or-restart` / `try-reload-or-restart` semantics quoted in Q1.

### Inferences
- **How to tell whether a given app supports zero-downtime reload.** There is no introspection primitive for this; it must be established per-app and recorded as data. A practical, testable procedure that Shipyard can automate once per app and cache:
  1. Confirm the app documents a reload mechanism at all (many "servers" do not; a Go binary re-reading config on SIGHUP, a Puma/Unicorn app, and a compiled static binary do not).
  2. Confirm it distinguishes reload from restart: record `MainPID` before, issue the reload, and assert `MainPID` is **unchanged** and `InvocationID` is **unchanged**. A real reload keeps the process; if the PID or InvocationID changes, the app "reloaded" by exiting and being restarted by systemd — which is a restart wearing a disguise, and a strong signal that `Restart=on-failure` is papering over a failed reload.
  3. Prove no requests were dropped: run a continuous request generator against the app's own port (bypassing nginx) for the duration of the reload, and require zero non-2xx/3xx. This is the only test that distinguishes "graceful" from "fast".
  4. Confirm the app actually re-read what changed (a reload that silently keeps old config is worse than a restart).
  Shipyard should store the result as a per-app capability flag (`reload_strategy: signal-sighup | notify-reload | restart-only`) rather than probing at deploy time — a deploy must never discover the answer by trying.
- **Use `try-reload-or-restart`, not `reload-or-restart`, in a deploy script.** `reload-or-restart` "If the units are not running yet, they will be started" — so a deploy that intended to leave a deliberately-stopped app stopped would instead start it. `try-reload-or-restart` "does nothing if the units are not running" (systemd ≥ 229). This is a small, concrete outage-class bug.
- **A code deploy must `restart`, full stop.** Reload semantics are "re-read configuration"; the new release's *code* is on disk but the running process still has the old code mapped. Using reload for a code deploy is a silent no-op that produces the worst possible outcome: the deploy reports success, `NRestarts` is unchanged, `ActiveEnterTimestamp` is unchanged, and the host serves old code. **Shipyard should assert that a code deploy changed `InvocationID`** — this is a cheap, decisive guard against exactly this class of bug.
- **Draining needs both signals set correctly and the right `KillMode=`.** `KillSignal=SIGTERM` (the default) plus a `TimeoutStopSec=` sized above the longest in-flight request is the drain mechanism; SIGKILL follows automatically. For apps that fork workers *after* the main process (Puma/Unicorn cluster mode, forking prefork servers), the default `KillMode=control-group` sends SIGTERM to every process in the cgroup simultaneously, which can make the parent exit before the workers finish draining — a `SIGTERM`-to-parent-then-workers ordering is usually wanted instead. `KillMode=mixed` (SIGTERM to main, SIGKILL to the rest after the timeout) is the safer default for these apps, and is why it appears in the unit in Q3.
- **Trap: `TimeoutStopSec=` too short = dropped requests, and it is silent.** The deploy looks successful; in-flight requests are SIGKILLed and the client sees a truncated response. There is no journal entry for a SIGKILL-caused truncation from the app's perspective. Set `TimeoutStopSec=` above the app's slowest endpoint, and have the app extend via `EXTEND_TIMEOUT_USEC=` during real drains (the man page's constraint — first receipt must arrive before the timeout — means an app that only *starts* pinging after the deadline gets no extension).
- **Trap: reload failure is under-reported.** With `ExecReload=kill -HUP $MAINPID`, `systemctl reload` returns success as soon as the signal is enqueued. The app may then refuse the new config and keep the old one (correct behaviour) or die (unhealthy). Neither is visible to the deploy. This is precisely the upstream-documented reason to avoid bare signal reloads, and it is why `Type=notify-reload` (or a blocking `ExecReload=`) is the correct choice for a control plane that must report deploy status.

### Gaps
- **`Type=notify-reload` and `ReloadSignal=` are systemd 253** (see Q4: systemd 253 NEWS + the `ReloadSignal=` "Added in version 253" annotation); **262 breaking change** requires the handler to be caught/blocked before `READY=1`. `ExecReloadPost=` is confirmed v259. `ExecCondition=` is confirmed v243.
- I did not verify `SendSIGHUP=`'s default value in the current `systemd.kill(5)` — the man page text I read ("Optionally, this is immediately followed by a SIGHUP (if enabled with `SendSIGHUP=`)") does not state the default, and whether SIGHUP is sent by default matters for apps with unusual SIGHUP handling. Verify before relying on it.
- No single authoritative source states "reload does not load new code". This is a general property of how `sd_notify`/SIGHUP reload protocols are specified in the app, and it is app-specific rather than a systemd guarantee. It should be verified per app in Shipyard's capability probe rather than asserted as a universal.

### Concrete deploy-time reload vs restart
```bash
# --- 1. capture the pre-deploy identity ------------------------------
before_invocation="$(systemctl show -p InvocationID --value blog.service)"
before_mainpid="$(systemctl show -p MainPID     --value blog.service)"

# --- 2. swap the release (atomic, same dir) -------------------------
ln -sfn -- "releases/${RELEASE}" /var/www/blog/.current.next
mv -T   -- /var/www/blog/.current.next /var/www/blog/current

# --- 3a. CODE deploy: always restart. Never reload. ------------------
# No daemon-reload: the unit file did not change, only the symlink.
systemctl reset-failed blog.service 2>/dev/null || true
systemctl restart blog.service

# --- 3b. CONFIG-ONLY deploy, and only if the app declares reload
#         capability. `try-` prefix so a stopped app stays stopped.
systemctl try-reload-or-restart blog.service

# --- 4. assert the identity actually changed -------------------------
after_invocation="$(systemctl show -p InvocationID --value blog.service)"
if [[ "$after_invocation" == "$before_invocation" ]]; then
  echo "shipyard: InvocationID unchanged ($after_invocation) —" \
       "the app was reloaded, not restarted. New code is NOT running." >&2
  exit 1
fi

# --- 5. for reload-capable apps, also assert the process survived ----
# (a "reload" that changed MainPID was a restart in disguise)
```

---

## Q8. Log capture: `StandardOutput=journal`, `journalctl -u`, resumable cursors, cursor stability, and journald storage limits

### Takeaway
Use `--cursor-file=` for resumable streaming — it is the only documented primitive built for exactly this. But treat the cursor as an opaque, undocumented, potentially-invalid token: the format is "private and subject to change", and a cursor can be invalidated by a reboot, a journald version change, or vacuuming. A correct client must detect a non-zero `journalctl` exit, discard the cursor file, and fall back to a time-based start. **The much better answer for a deploy tool is an invocation-scoped match, which needs no cursor at all and is immune to rotation, vacuum and reboot.** Use `journalctl _SYSTEMD_INVOCATION_ID=<ID>` (works on every systemd that has invocation IDs, v232+) or, on v257+, `journalctl --invocation=<ID>`. **Do NOT write `journalctl -I <ID>`:** the short `-I` takes *no argument* — it is a literal alias for `--invocation=0` ("the latest invocation") — so the `<ID>` after it is parsed as a positional MATCH and the command fails with `Failed to add match '<ID>': Invalid argument`. This is an empirically verified trap on systemd 262 and is mis-signalled by the `journalctl(1)` synopsis line `-I, --invocation=ID[±offset]|offset` (see Q8 Gaps).

### Cited Findings
- `--show-cursor` "The cursor is shown after the last entry after two dashes: `-- cursor: s=0639...` **The format of the cursor is private and subject to change.**" — **Added in version 209.**
- `-c, --cursor=` "Start showing entries from the location in the journal specified by the passed cursor." — **Added in version 193.**
- `--after-cursor=` "Start showing entries from the location in the journal **after** the location specified by the passed cursor. The cursor is shown when the `--show-cursor` option is used." — **Added in version 206.**
- `--cursor-file=FILE` "**If FILE exists and contains a cursor, start showing entries after this location. Otherwise, show entries according to the other given options. At the end, write the cursor of the last entry to `FILE`. Use this option to continually read the journal by sequentially calling `journalctl`.**" — **Added in version 242.**
- `-b [[ID][±offset]|all], --boot[=[ID][±offset]|all]`: "Show messages from a specific boot. This will add a match for `_BOOT_ID=`." — **Added in version 186.**
- `-I, --invocation=ID[±offset]|offset`: "Show messages from a specific invocation of unit. This will add a match for `_SYSTEMD_INVOCATION_ID=`, `OBJECT_SYSTEMD_INVOCATION_ID=`, `INVOCATION_ID=`, `USER_INVOCATION_ID=`... **`-I` is equivalent to `--invocation=0`, and logs for the latest invocation will be shown.** ... When an offset is specified, a unit name must be specified with `-u/--unit=` or `--user-unit=` option. When specified with `-b/--boot=`, invocations are searched within the specified boot. **Added in version 257.**"
- **The `-I` short option takes NO argument — this is an empirically verified arity trap, and the man page synopsis mis-signals it.** The synopsis line `-I, --invocation=ID[±offset]|offset` reads as though `-I <ID>` works, but the body sentence "-I is equivalent to --invocation=0" is the contract: `-I` is a literal alias for `--invocation=0` (latest invocation) and consumes no value. Verified three ways on systemd 262: (a) local `journalctl` code declares it argument-less (`OPTION_SHORT('I', NULL, "Show logs from the latest invocation of unit")`, body sets `arg_invocation_id = SD_ID128_NULL; arg_invocation_offset = 0`); (b) upstream v259 `getopt_long` optstring is `"...u:INF:xrM:i:W"` — `I` has no trailing `:` (while `F:` does), so `-I` never received an argument; (c) live test `journalctl -u systemd-journald.service -I <32-hex-ID>` → rc=1, `Failed to add match '<ID>': Invalid argument`, 0 lines, because the ID is parsed as a positional match. **To scope to a specific ID you MUST use the long form `--invocation=<ID>` (verified working, rc=0, no unit needed) or, portably, the raw field match `journalctl _SYSTEMD_INVOCATION_ID=<ID>` (verified working, rc=0).** The raw field `_SYSTEMD_INVOCATION_ID=` is documented in `systemd.journal-fields(7)` ("The invocation ID for the runtime cycle of the unit the message was generated in, as available to processes of the unit in `$INVOCATION_ID`") and works on every systemd that has invocation IDs, removing the v257 floor entirely. An invocation *offset* (e.g. `--invocation=-1`) still requires `-u`; an explicit 32-hex ID does not.
- **An explicit `--invocation=<ID>` requires no `-u`; an offset does.** Verified live: `journalctl --invocation=<ID>` (no `-u`) → rc=0, 6 lines; `journalctl --invocation=0` (no `-u`) → rc=1, `Failed to add match '0': Invalid argument` (offsets are resolved against a unit); `journalctl -u systemd-journald.service --invocation=0` → rc=0, 6 lines.
- `-u, --unit=UNIT|PATTERN` "Show messages for the specified systemd unit UNIT (such as a service unit), or for any of the units matched by PATTERN... For each unit name, a match is added for messages from the unit (`_SYSTEMD_UNIT=UNIT`), along with additional matches for messages from systemd and messages about coredumps for the specified unit." The man page gives the expansion: `journalctl -u name` expands to `_SYSTEMD_UNIT=name.service` + `UNIT=name.service _PID=1` + `OBJECT_SYSTEMD_UNIT=name.service _UID=0` + `COREDUMP_UNIT=name.service _UID=0 MESSAGE_ID=fc2e22bc6ee647b6b90729ab34a250b1`. "This parameter can be specified multiple times."
- Journal access control: "All users are granted access to their private per-user journals. However, by default, **only root and users who are members of a few special groups are granted access to the system journal** and the journals of other users. Members of the groups `systemd-journal`, `adm`, and `wheel` can read all journal files."
- `Storage=`: "Controls where to store journal data. One of 'volatile', 'persistent', 'auto' and 'none'. If 'volatile', journal log data will be stored only in memory, i.e. below the `/run/log/journal` hierarchy... If 'persistent', data will be stored preferably on disk, i.e. below the `/var/log/journal` hierarchy (which is created if needed), **with a fallback to `/run/log/journal`** (which is created if needed), during early boot and if the disk is not writable. **'auto' behaves like 'persistent' if the `/var/log/journal` directory exists, and 'volatile' otherwise** (the existence of the directory controls the storage mode). 'none' turns off all storage, all log data received will be dropped... **Defaults to 'persistent' in the default journal namespace (this value is determined at compilation time)**, and 'persistent' in all others."
- `SystemMaxUse=, SystemKeepFree=, SystemMaxFileSize=, SystemMaxFiles=, RuntimeMaxUse=, RuntimeKeepFree=, RuntimeMaxFileSize=, RuntimeMaxFiles=`: "Enforce size limits on the journal files stored. The options prefixed with 'System' apply to the journal files when stored on a persistent file system, more specifically `/var/log/journal`. The options prefixed with 'Runtime' apply to the journal files when stored on a volatile... `SystemMaxUse=` and `RuntimeMaxUse=` control how much disk space the journal may use up at most. `SystemKeepFree=` and `RuntimeKeepFree=` control how much disk space systemd-journald shall leave free for other uses."
- `--vacuum-size=, --vacuum-time=, --vacuum-files=`: `--vacuum-size=` removes the oldest archived journal files until disk space falls below the specified size; `--vacuum-time=` removes archived journal files older than the specified timespan; `--vacuum-files=` leaves only the specified number of separate journal files. "Note that running `--vacuum-size=` has only an indirect effect on the output shown by `--disk-usage`, as the latter includes active journal files, while the vacuuming operation only operates on archived journal files. ... These three switches may also be combined with `--rotate` into one command. If so, all active files are rotated first, and the requested vacuuming operation is executed right after. **The rotation has the effect that all currently active files are archived (and potentially new, empty journal files opened as replacement)**". — **Added in version 218** (vacuum); `--rotate` **added in version 227**; `--disk-usage` **added in version 190**.
- "On success, 0 is returned; otherwise, a non-zero failure code is returned." — `journalctl(1)` EXIT STATUS, read locally.
- `-f, --follow`: "Show only the most recent journal entries, and continuously print new entries as they are appended to the journal, until Ctrl-C is hit... **journalctl will send an `sd_notify(3)` `READY=1` message once it initialized and successfully established its watch on the journal.**" — This is a concrete, documented fact that lets a deploy `systemd-run --wait` a log tail and be *ordered* after the log watch is live.
- `--synchronize-on-exit=` "Takes a boolean argument. If true and operating in `--follow` mode, a journal synchronization request (equivalent to `journalctl --sync`) is issued when SIGTERM/SIGINT is received, and log output continues until this request completes. This is useful for synchronizing journal log output to the runtime of services or external events, ensuring that any log data enqueued to the logging subsystem by the time SIGTERM/SIGINT is issued is guaranteed to be processed and displayed by the time log output ends. Defaults to false." — **Added in version 258.**
- Implicit dependency: "Units whose standard output or error output is connected to journal or kmsg (or their combinations with console output) automatically acquire dependencies of type `After=` on `systemd-journald.socket`." — `systemd.exec(5)`.
- `ExecSearchPath=` — **Added in version 250** (cited as evidence that this is a recent-but-notable `systemd.exec` option; not otherwise relevant here).

### Inferences
- **What "the format of the cursor is private and subject to change" means operationally.** It is an explicit upstream refusal to make the cursor a stable interface. Consequences a client must honour: (a) **never parse a cursor** — do not split `s=...;i=...;b=...;m=...;t=...;x=...` on `;`/`=`, do not extract the boot ID from it, do not synthesize one; (b) **never construct a cursor** — there is no documented constructor; (c) **never persist a cursor across a systemd upgrade**, because the encoding may change; (d) treat it strictly as an opaque token passed back to `--after-cursor=` or stored by `--cursor-file=`. `--cursor-file=` exists precisely so clients do not have to do any of this.
- **"Cursors are scoped to a boot" is a consequence of the encoding, not a documented rule.** The `journalctl(1)` text documents `--boot=` and `--cursor=` as independent orthogonal filters and never states that a cursor from boot *N* is invalid in boot *N+1*. But the cursor must encode *some* position, and the journal file set is rebuilt on every boot (`/run/log/journal` is volatile; `/var/log/journal` gets new files per boot), so a cursor naming a byte offset in a file that no longer exists cannot resolve. **Therefore: after a reboot, a saved cursor is at best meaningless and at worst rejected. Treat any cursor as invalid across a boot boundary.** Shipyard should record the `_BOOT_ID` (or the `ActiveEnterTimestamp`) alongside each stored cursor and invalidate the cursor when the boot ID changes. This is an inference from the encoding, and is stated as such.
- **The graceful-degradation story.** `--cursor-file=FILE` is documented to fall back ("Otherwise, show entries according to the other given options") when the *file does not exist* — that is the "first run" case. It says **nothing** about the case where the file exists but contains a *stale or invalid* cursor, which is precisely the reboot/vacuum/upgrade case. Since the only signal available is `journalctl`'s exit status ("On success, 0 is returned; otherwise, a non-zero failure code is returned"), the correct client behaviour is: **always check the exit status; on non-zero, delete the cursor file and retry once with an explicit `--since=` fallback.** A client that pipes `journalctl` into `tail` without checking the exit status will silently show zero new entries forever and report a healthy log stream — a silent, high-cost failure mode.
- **What happens when logs are vacuumed out from under a reader.** Three distinguishable outcomes, none of which the man page spells out for the reader case, and all of which the client must handle identically by falling back:
  1. The journal file containing the cursor's position is deleted by `--vacuum-size=`/`--vacuum-time=`/`--vacuum-files=`. The cursor no longer resolves; the reader either errors (non-zero) or, worst case, resumes at a *later* position with a gap that is invisible.
  2. The file is rotated (`--rotate`, or journald's own size/`SystemMaxFileSize=`-triggered rotation) and becomes an *archived* file. `--rotate` explicitly creates "new, empty journal files ... in their place" while making the old ones archived, and vacuum only "operates on archived journal files". So a cursor spanning a rotation is the common, expected case — not an error — and `--cursor-file=` is designed to handle it. This is the *normal* case, and the reason cursors work at all.
  3. Storage is `volatile` or the deployment used `Storage=none`. With `volatile`, everything is under `/run/log/journal` and is **gone on reboot**, so the cursor's entire file set is gone. With `none`, "all log data received will be dropped". In both cases a resume cursor is guaranteed invalid, and there are no logs to fall back to. **Shipyard must check `Storage=` on the host at install time** and refuse (or warn loudly) if it is not `persistent`, because a deploy control plane whose log history evaporates on reboot cannot debug its own failed deploys.
- **`Storage=auto` is a silent trap.** It "behaves like 'persistent' if the `/var/log/journal` directory exists, and 'volatile' otherwise". A host that has never had `systemd-tmpfiles` create `/var/log/journal` runs on volatile logs while the config *looks* persistent. Shipyard should read the effective value (and/or the existence of `/var/log/journal`), not the configured string.
- **The recommended design: prefer `InvocationID` over cursors entirely — and use the raw field match, not `-I`.** `journalctl _SYSTEMD_INVOCATION_ID=<ID>` (or `--invocation=<ID>` on ≥257) is exact, needs no cursor file, no `--show-cursor` parsing, no boot-ID bookkeeping, and is immune to rotation, vacuum and reboot. It is the natural fit for a deploy control plane because the deploy *itself* caused the invocation and therefore knows the ID. Limit: the ID itself requires systemd ≥ 232 (when `InvocationID`/`$INVOCATION_ID` was introduced); the *reader* option `--invocation=` is ≥257, but the raw field match lifts that floor because the field is present on any systemd that has invocation IDs. **The critical correction: never write `-I <ID>`** — it consumes no argument, so the ID becomes a positional match and the command fails (see Cited Findings). Fallback ladder: (1) raw field match `_SYSTEMD_INVOCATION_ID=<ID>` (universal, ≥232), or `--invocation=<ID>` (≥257); (2) `ActiveEnterTimestamp` + `--since` (universal, but subject to clock changes — and `journalctl --header` exists "particularly [as a] useful [tool] when trying to identify out-of-order journal entries, as happens for example when the machine is booted with the wrong system time"); (3) `--cursor-file` with exit-status-checked fallback (≥242).
- **Set `StandardOutput=journal`/`StandardError=journal` explicitly rather than relying on defaults.** The implicit `After=systemd-journald.socket` dependency is the observable proof that journal-connected output is the intended default path, but the *default value itself* is a manager setting (`DefaultStandardOutput=` in `systemd-system.conf(5)`, also settable per-boot via `systemd.default_standard_output=`) that operators and image builders do change. A control plane that silently loses an app's stdout because someone set `DefaultStandardOutput=null` is a bad failure mode; Shipyard should assert the property with `systemctl show -p StandardOutput`.
- **Use `-f` + `--synchronize-on-exit=yes` + `READY=1` for a live tail that must not lose the shutdown lines.** The documented combination is: `journalctl -f` announces `READY=1` once its watch is established (so a wrapping `systemd-run --wait` orders correctly against the unit's start), and `--synchronize-on-exit=yes` (v258) guarantees every message enqueued before the SIGTERM is displayed before the tail exits. Without it, a deploy that kills the log tail at the same moment it stops the app is likely to lose exactly the shutdown lines that explain the failure.

### Gaps
- **The man pages do not state a minimum version for the `NRestarts` / `InvocationID` properties** (see Q6). `--cursor-file` is v242, `--after-cursor` v206, `--show-cursor` v209, `-c/--cursor` v193, `--invocation=` v257 (but the `-I` short alias and the `_SYSTEMD_INVOCATION_ID=` raw field are older/undocumented as to version), `--synchronize-on-exit` v258, `--rotate` v227, vacuum v218, `--disk-usage` v190, `-b/--boot` v186 — these are all explicitly annotated and are safe to state.
- **The man pages do not describe `journalctl`'s behaviour on an invalid/stale cursor — but it has now been established empirically on systemd 262 (see Q8 Cited Findings update below): the behaviour is split and partly fail-OPEN, which is dangerous.** Results: (a) **garbage cursor** in `--cursor-file` → rc=1, `Failed to seek to cursor: Invalid argument` (fail-closed); (b) **empty cursor file** → rc=0, "show entries according to the other given options" (documented, benign); (c) **cursor whose boot ID is wrong/unknown** → **rc=0, NO warning, silently ignored**, and the reader seeks by sequence number *within the current journal* — a fail-OPEN that can present current-boot entries as if they were the requested position. `journalctl -b <unrelated-well-formed-boot-id>` by contrast FAILS CLOSED (rc=1, `No journal boot entry found for the specified boot (<id>+0).`), and the all-zeros boot ID is treated as null → current boot. **Consequence: `--cursor-file`/`--after-cursor` do NOT validate the cursor's boot ID, so a client MUST itself compare the stored cursor's boot ID against `/proc/sys/kernel/random/boot_id` and treat any mismatch as "no valid cursor" — never trust the cursor blindly.** The "delete the cursor and retry once" recommendation is now confirmed necessary but insufficient on its own (the silent case never returns non-zero, so exit-status checking alone misses it).
- The exact `Storage=` effective value and whether `/var/log/journal` exists must be checked at runtime; I have no way to determine either from documentation.
- I did not read `sd_journal_get_cursor(3)` / `systemd.journal-fields(7)` in full, so the internal structure of a cursor (my claim that it encodes a boot ID and a file offset) is inferred from the `--show-cursor` sample output format `s=...` and from the `-b`/cursor boot-ID behaviour above, not from a specification. It is an inference; do not build anything that depends on the internal structure.
- **Journal vacuum/rotation effect on a persisted cursor was deliberately NOT tested** (would have destructively vacuumed/rotated the only host journal available). Needs an isolated journal or a disposable target. The rotation case (cursor spans archived files) is expected to be the normal, working case, but is unverified.

### Concrete log capture
```bash
# --- preferred: scope to exactly one start, no cursor -----------------
# Use the RAW FIELD MATCH (works on every systemd with invocation IDs,>=232).
# NEVER `-I "$ID"`: -I takes no argument and the ID becomes a positional
# match -> rc=1 "Failed to add match '<ID>': Invalid argument".
systemctl show -p InvocationID --value blog.service > /tmp/inv
journalctl _SYSTEMD_INVOCATION_ID="$(cat /tmp/inv)" --no-pager -o short-iso-precise
# On systemd >= 257 the equivalent long form also works (and needs no -u):
# journalctl --invocation="$(cat /tmp/inv)" --no-pager -o short-iso-precise

# --- universal fallback: time-based, tolerant of a bad clock ----------
journalctl -u blog.service --since "$(systemctl show -p ActiveEnterTimestamp --value blog.service)" \
          --no-pager -o short-iso-precise

# --- resumable streaming (systemd >= 242): cursor-file does the work --
# Robust wrapper: NEVER trust a stale cursor; detect it via exit status.
follow_unit_logs() {
  local unit="$1" cur="/var/lib/shipyard/cursors/${1}.cursor" rc=0
  install -d -m 0700 "$(dirname "$cur")"
  journalctl -u "$unit" -f --no-pager --show-cursor \
             --cursor-file="$cur" --synchronize-on-exit=yes || rc=$?
  if (( rc != 0 )); then
    # Reboot, journal rotation/vacuum, or a systemd upgrade invalidated
    # the cursor. Discard it and re-anchor on a time bound. A gap in log
    # coverage is acceptable; a silently dead log stream is not.
    echo "shipyard: cursor invalid for $unit (journalctl rc=$rc); re-anchoring" >&2
    rm -f -- "$cur"
    local since; since="$(systemctl show -p ActiveEnterTimestamp --value "$unit" || date --iso-8601=seconds)"
    journalctl -u "$unit" -f --no-pager --since "$since" \
               --cursor-file="$cur" --synchronize-on-exit=yes
  fi
}

# --- live tail, ordered after the watch is established ---------------
# journalctl sends sd_notify READY=1 once its watch is live (documented),
# so --wait makes systemd wait for that before declaring success.
systemd-run --quiet --wait --pipe --unit=shipyard-log-blog \
  journalctl -u blog.service -f --no-pager --show-cursor \
             --cursor-file=/var/lib/shipyard/cursors/blog.cursor

# --- host preflight for a control plane -------------------------------
# Storage=volatile or a missing /var/log/journal means the cursor strategy
# is unsound on this host: log history dies at reboot.
grep -E '^[[:space:]]*Storage=' /etc/systemd/journald.conf 2>/dev/null \
  || echo "shipyard: Storage= not set explicitly; compile-time default applies"
[[ -d /var/log/journal ]] \
  || echo "shipyard: /var/log/journal absent -> Storage=auto degrades to volatile; logs are RAM-only and lost on reboot"
journalctl --disk-usage
```

---

## Q9. nginx upstream basics worth generating, and symlinked-root gotchas

### Takeaway
`disable_symlinks` defaults to `off`, so nginx *does* follow a `current` symlink in `root` — the symlinked static root works out of the box. The only real gotcha is `open_file_cache`, which is also `off` by default and which, if enabled, can serve stale files from the previous release until `open_file_cache_valid` expires. The other classic footguns are the `proxy_pass` trailing-slash URI-rewriting rule and `proxy_buffering` silently breaking SSE/streaming.

### Cited Findings
- `disable_symlinks on | if_not_owner [from=part]`, **`default: off`**, `context: http, server, location` (module ngx_http_core_module). "If the value matches the whole file name, symbolic links are not checked. The parameter value can contain variables." Example given: `disable_symlinks on from=$document_root;`. "This directive is only available on systems that have the `openat()` and `fstatat()` interfaces." — [OpenBSD nginx.conf(5)](https://man.openbsd.org/OpenBSD-5.6/nginx.conf.5) (a verbatim mirror of the official nginx directive reference).
- `open_file_cache off | max=N [inactive=time]`, **`default: off`**, `context: http, server, location`.
- `open_file_cache_errors on | off`, **`default: off`**.
- `open_file_cache_valid time`, **`default: 60s`** — "Sets a time after which `open_file_cache` elements should be validated."
- `open_file_cache_min_uses` — example given as `open_file_cache max=1000 inactive=20s; open_file_cache_valid 30s; open_file_cache_min_uses 2; open_file_cache_errors on;`
- nginx master/worker signal semantics confirming that a config reload keeps the listening socket: on HUP the master "starts new worker processes, and sends messages to old worker processes requesting them to shut down gracefully. Old worker processes close listen sockets and continue to service old clients." — [Controlling nginx](https://nginx.org/en/docs/control.html)
- **Official `ngx_http_proxy_module` citations** (fetched from [nginx.org/en/docs/http/ngx_http_proxy_module.html](https://nginx.org/en/docs/http/ngx_http_proxy_module.html), module `ngx_http_proxy_module`, context `http, server, location` unless noted):
  - **`proxy_pass` URI rewriting.** `proxy_pass URL;` — "Sets the protocol and address of a proxied server and an optional URI to which a location should be mapped. ... **If the `proxy_pass` directive is specified with a URI, then when a request is passed to the server, the part of a normalized request URI matching the location is replaced by a URI specified in the directive**". "In some cases, the part of a request URI to be replaced cannot be determined: when ... the location is given by a regular expression, or ... inside a named location." So `proxy_pass http://127.0.0.1:8080;` → original URI passed unchanged; `proxy_pass http://127.0.0.1:8080/;` → matched location prefix replaced by `/`. (This confirms the notes' working-knowledge claim — the trailing-slash rule is now sourced.)
  - **`proxy_set_header` defaults.** `proxy_set_header field value;` **Default: `proxy_set_header Host $proxy_host; proxy_set_header Connection close;`** — "Allows redefining or appending fields to the request header passed to the proxied server. ... By default, only two fields are redefined: `Host` and `Connection`" (the original client `Host`/`Connection` are NOT forwarded as-is). "the `Host` field is set to the name of the proxied server ... for HTTP/2 requests the `:authority` field is used". (Confirms the notes' claim that `Host`/`Connection` need explicit setting.)
  - **`proxy_http_version`.** `proxy_http_version 1.0 | 1.1;` — "Sets the HTTP protocol version for proxying. **By default, version 1.0 is used**, but see also the `proxy_http_version` ... **Since version 1.29.7, the default is 1.1.**" (So on nginx < 1.29.7 the default is 1.0, and upstream keepalive requires explicitly setting `1.1`. Shipyard's generated block sets it explicitly, which is correct for all versions.)
  - **`proxy_read_timeout`.** `proxy_read_timeout time;` **Default: `60s`** — "Defines a timeout for reading a response from the proxied server. The timeout is set only between two successive read operations, not for the transmission of the whole response. If the proxied server does not transmit anything within this time, the connection is closed." (Notes' generated block lowers this to 30s deliberately.)
  - **`proxy_connect_timeout`** **Default: `60s`**; **`proxy_send_timeout`** **Default: `60s`**.
  - **`proxy_redirect`.** `proxy_redirect default | off | redirect replacement;` **Default: `proxy_redirect default;`** — "Sets the text that should be changed in the `Location` and `Refresh` header fields of a proxied server response"; with `default`, "replaces ... the location given in the `proxy_pass` directive and the `Location` ... value". (Relevant because a proxied app that emits absolute redirects with its own origin will be rewritten — usually desired, sometimes not.)
  - **`proxy_buffering`.** `proxy_buffering on | off;` **Default: `proxy_buffering on;`** — "When buffering is enabled, nginx receives a response from the proxied server as soon as possible, saving it into the buffers set by the `proxy_buffer_size` and `proxy_buffers` directives. ... **nginx is able to respond to the client faster, but at the cost of ... a delay in processing**". "Buffering can also be enabled or disabled by passing 'yes' or 'no' in the `X-Accel-Buffering` response header field of the proxied server." (Confirms notes: buffering default on; `X-Accel-Buffering: no` is the per-response escape hatch; `proxy_buffering off;` is the per-location one.)
  - **`proxy_buffers`** default `8 4k|8k`; **`proxy_buffer_size`** default `4k|8k`; **`proxy_busy_buffers_size`** default `8k|16k` (platform-dependent; see also `proxy_max_temp_file_size`). The generated block's values are explicit overrides, not the defaults.
  - **`proxy_intercept_errors`** **Default: `off`** — "Determines whether proxied responses with codes greater than or equal to 300 should be passed to a client or be intercepted and redirected to nginx for processing with the `error_page` directive." (Default `off` means upstream 5xx reaches the deploy health check unmasked — the behaviour the generated block wants.)
  - **`keepalive` in an `upstream` block** — from `ngx_http_upstream_module`: "Activates the cache for connections to upstream servers. The connections are ... kept in the cache". A `server` name in `upstream` is resolved at configuration time unless a `resolver` is configured and the v1.27.3+ `resolve` parameter is used — confirming the generated block's warning to use a literal `127.0.0.1` address, not a DNS name.

### Inferences
- **`disable_symlinks off` (the default) is what makes a symlinked root work.** nginx performs ordinary path resolution, so `root /var/www/blog/current/public;` transparently follows `current` → `releases/<id>` on every request. No `disable_symlinks` tuning is needed for Shipyard. Conversely, if a Shipyard hardening pass ever sets `disable_symlinks on` (a real recommendation for root-owned, non-symlink trees), it will **break every symlinked release root** with 403/404s — a configuration interaction that must be checked whenever a global nginx hardening change lands.
- **The `open_file_cache` gotcha is the one real symlink hazard, and it is opt-in.** With `open_file_cache on`, nginx caches file lookups. After `mv -T current`, a cached entry still names the pre-swap path, so nginx can serve the *previous release's* static assets until `open_file_cache_valid` (default 60s) elapses and the entry is revalidated. Practical consequences: hashed/never-changing filenames (which is the normal case for a build pipeline) make this invisible; a deploy that changes a filename without changing its content hash produces a confusing mixed-version asset graph. **Recommendation: leave `open_file_cache off` for any `root` under a `current` symlink.** It is the default, so this requires no action — it only needs to be *not* enabled by a performance pass. If a host genuinely needs `open_file_cache`, set a short `open_file_cache_valid` and treat a `systemctl reload nginx` as mandatory after a release swap (a reload starts fresh workers, which begin with an empty `open_file_cache`, so the stale entries drain with the old workers) — that last step is an inference from the reload semantics quoted above, not a documented guarantee, so do not treat reload as a substitute for simply leaving the cache off.
- **`proxy_pass` trailing slash is the highest-frequency generated-config bug.** `proxy_pass http://127.0.0.1:8080;` (no URI part) passes the original, unmodified request URI. `proxy_pass http://127.0.0.1:8080/;` (with a URI part) replaces the matched `location` prefix with that URI. Shipyard's generator must emit exactly one of these forms deterministically; a per-app inconsistency produces 404s on every nested path and a puzzling 200 on `/`. This is now sourced from the official `ngx_http_proxy_module` documentation (see Cited Findings above): "the part of a normalized request URI matching the location is replaced by a URI specified in the directive".
- **`proxy_buffering` is the second big one, and it is on by default.** Buffering the upstream response means nginx reads the whole response (or fills the buffer) before forwarding, which breaks Server-Sent Events and long-poll streaming: the client sees nothing until the buffer fills or the response ends. SSE endpoints need `proxy_buffering off;` plus `add_header X-Accel-Buffering no;` (some frameworks need the response header `X-Accel-Buffering: no` instead). Shipyard's generator needs a per-app or per-location flag for streaming endpoints; getting this wrong looks like a hung request, not an error, so it will be hard to diagnose in production.
- **`/healthz` has two distinct meanings and Shipyard must not conflate them.** An nginx-served health endpoint (`location = /healthz { access_log off; return 200 "ok\n"; }`) proves only that the nginx *master and workers* are alive and the `server` block matched. It says nothing about the upstream application. An application health check must be `proxy_pass`ed to the app's own port. Using the nginx-local one as a deploy gate is a **false-positive machine**: it passes while the app is down, so the deploy "succeeds" against a dead backend. Recommendation: two endpoints with unambiguous names — `/healthz` (nginx liveness, served locally, cheap, used by an external load balancer) and `/__shipyard/health` (proxied to the app, used by the deploy gate). Reserve a distinct listener/port for the app-facing health path so it is never publicly routable.
- **Static root and proxy must agree on the symlink.** If nginx serves `root /var/www/blog/current/public;` directly and also proxies `/` to the app, the two halves resolve `current` independently and can briefly straddle a swap (static from release N, dynamic from release N-1's already-running process) if the swap happens between the app restart and the nginx reload. Shipyard's ordering — swap symlink → restart app → (reload nginx if its config changed) — leaves a window where nginx's static root already points at N while the app process is still N-1. This is a genuine consistency hazard for a `current`-symlink layout with mixed static/dynamic serving, and it is inherent to the layout, not to any particular tool. Mitigation: prefer serving *all* assets through the app, or accept the window and keep the static asset set version-independent (hashed filenames).

### Gaps
- ~~I did not fetch the official nginx `ngx_http_proxy_module` documentation in this pass.~~ **RESOLVED:** the module docs were fetched; `proxy_pass` URI-rewriting, `proxy_set_header` defaults (`Host $proxy_host; Connection close`), `proxy_http_version` default (`1.0`, becoming `1.1` in nginx ≥ 1.29.7), `proxy_read_timeout` (`60s`), `proxy_redirect` (`default`), `proxy_buffering` (`on` + `X-Accel-Buffering`) and `proxy_intercept_errors` (`off`) are now cited in Q9 Cited Findings. Remaining nginx gap: behaviour of `open_file_cache` across a reload (below), and config-load vs request-time symlink resolution (below).
- I did not verify the behaviour of `open_file_cache` across a `systemctl reload` from documentation. The claim that new workers start with an empty cache (and therefore that reload flushes it) is an inference.
- Whether nginx opens `root` directories at configuration-load time or at request time (the "resolving at config load vs request time" question in the assignment) is not answered by any source I read. The `-t` documentation ("then tries to open files referred in the configuration") implies some validation happens at config-load time for referenced files, but it does not say which, and it does not say that a symlink target is re-resolved per request. The safe operational position — which does not depend on resolving this question — is: validate the symlink target explicitly in the deploy script, and don't rely on `nginx -t` or on a reload to surface a broken static root.
- The `$realpath_root` technique for `fastcgi_pass` with symlinked roots (a widely-circulated community fix: `fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;`) is documented only in community/aggregator sources — [DEV.to](https://dev.to/ibrarturi/how-to-fix-nginx-symlink-caching-issue-3loe) — and is specific to the FastCGI module, not `proxy_pass`. I would not rely on it and would not design around it.

### Concrete generated server block
```nginx
# /etc/nginx/sites-available/blog.conf
# GENERATED BY SHIPYARD — do not hand-edit; the next deploy overwrites it.
# Deploy applies this file with:  mv -T (atomic) -> nginx -t -> systemctl reload nginx

upstream blog_app {
    # Single upstream per app; nginx keeps a worker-side connection to it.
    # `server` here is a literal address, NOT a DNS name — a DNS name would
    # be resolved at config-load time only and would need a `resolver`
    # directive plus `resolve` parameter (nginx >= 1.27.3) to be dynamic.
    server 127.0.0.1:8080 max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name blog.example.com;

    # --- security headers / TLS -------------------------------------
    # include /etc/nginx/snippets/shipyard-tls.conf;   # listen 443 ssl;
    # add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    # ^ ONLY meaningful once the redirect below is served over TLS, otherwise
    #   you can lock yourself out of your own site (HSTS preload / includeSubDomains).

    access_log /var/log/nginx/blog.access.log;
    error_log  /var/log/nginx/blog.error.log warn;

    # --- static assets, served straight off the release ----------------
    # Follows the `current` symlink automatically: `disable_symlinks` defaults
    # to `off`, so ordinary path resolution applies. Do NOT set
    # `disable_symlinks on` here without also verifying every release path.
    #
    # Do NOT enable `open_file_cache` for a root under `current`: cached
    # lookups name the pre-swap path and can serve the previous release's
    # assets until `open_file_cache_valid` (default 60s) expires.
    root /var/www/blog/current/public;
    index index.html;
    location ^~ /assets/ {
        # hashed filenames: safe to cache hard at the edge
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    # --- application ----------------------------------------------------
    # NO trailing slash after the port: the original request URI is passed
    # through unchanged. A trailing slash (proxy_pass http://...:8080/;)
    # rewrites every request, replacing the matched location prefix.
    location / {
        proxy_pass http://blog_app;

        proxy_http_version 1.1;

        # Required for upstream keepalive to be usable.
        proxy_set_header Connection "";

        # Proxy identity headers. X-Real-IP and X-Forwarded-For must be
        # *set*, not appended, or every hop in the chain gets a longer
        # comma-separated list and any naive parser breaks.
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  $server_port;

        # Timeouts. proxy_connect_timeout bounds the TCP connect;
        # proxy_read_timeout bounds the gap between successive upstream
        # reads, so a slow endpoint must be covered here or nginx returns
        # 504 to the client while the app is still working.
        proxy_connect_timeout 5s;
        proxy_send_timeout    30s;
        proxy_read_timeout    30s;

        # Buffering is ON by default. For SSE / long-poll / streaming
        # endpoints you MUST set `proxy_buffering off;` here, or the client
        # sees nothing until the response completes. Symptom is a hung
        # request, not an error.
        proxy_buffering on;
        proxy_buffers 16 16k;
        proxy_buffer_size 32k;
        proxy_busy_buffers_size 64k;

        # Do not let nginx mask upstream 5xx as its own error page if you
        # want the deploy health check to see the real status.
        proxy_intercept_errors off;
    }

    # --- nginx's own liveness -------------------------------------------
    # Proves nginx is serving. Proves NOTHING about the app. Never use this
    # as a deploy gate.
    location = /healthz {
        access_log off;
        add_header Cache-Control "no-store" always;
        default_type text/plain;
        return 200 "ok\n";
    }

    # --- the app's own health, for the deploy gate ----------------------
    # Deliberately distinct name so it is never confused with /healthz.
    location = /__shipyard/health {
        access_log off;
        proxy_pass http://blog_app/__shipyard/health;
        proxy_set_header Host $host;
        proxy_connect_timeout 2s;
        proxy_read_timeout 3s;
    }

    # Deny dotfiles and anything outside the release tree.
    location ~ /\. { deny all; access_log off; log_not_found off; }
}
```

---

## Q10. Permissions and the user model: `deploy` owner vs service `User=`

### Takeaway
Two distinct identities with disjoint needs: `deploy` needs **write + execute on the parent of `current`** (to `rename(2)` the symlink) and ownership of the release tree; the service `User=` needs **read + traverse** on the release tree plus **write only on directories outside it**. The two failure modes to design against are nginx getting 403s because it serves the same tree the app's service user writes to, and the app getting `EROFS`/`EACCES` because `ProtectSystem=strict` plus a write into `current/`.

### Cited Findings
- `User=`, `Group=`: "Set the UNIX user or group that the processes are executed as... If no group is set, the default group of the user is used. **This setting does not affect commands whose command line is prefixed with `+`.** ... If `DynamicUser=` is not used the specified user and group must have been created statically in the user database no later than the moment the service is started, for example using the `sysusers.d(5)` facility, which is applied at boot or package install time. **If the user does not exist by then program invocation will fail.**" — `systemd.exec(5)`, read locally.
- `SupplementaryGroups=`: "Sets the supplementary Unix groups the processes are executed as... In any way, this setting does not override, but extends the list of group(s) configured in the system group database for the user."
- `WorkingDirectory=` is documented in Q3 above, including: "If the setting is prefixed with the `-` character, a missing working directory is not considered fatal." and the `RequiresMountsFor=`-equivalent automatic dependency.
- `DynamicUser=` (Added in version 232): "...the user/group name to use may be configured via `User=` and `Group=`. ... Dynamic users/groups are allocated from the UID/GID range 61184...65519. **It is recommended to avoid this range for regular system or login users.** ... care should be taken that no processes running as part of a unit for which dynamic user/group allocation is enabled do not leave files or directories owned by these users/groups around, as a different unit might get the same UID/GID assigned later on, and thus gain access to these files or directories. ... If `DynamicUser=` is enabled, `RemoveIPC=` is implied (and cannot be turned off) ... Furthermore `NoNewPrivileges=` and `RestrictSUIDSGID=` are implicitly enabled (and cannot be disabled) ... Moreover, `ProtectSystem=strict` and `ProtectHome=read-only` are implied, thus prohibiting the service to write to arbitrary file system locations. **In order to allow the service to write to certain directories, they have to be allow-listed using `ReadWritePaths=`** ... Use `RuntimeDirectory=` in order to assign a writable runtime directory to a service, owned by the dynamic user/group and removed automatically when the unit is terminated. Use `StateDirectory=`, `CacheDirectory=` and `LogsDirectory=` in order to assign a set of writable directories for specific purposes to the service in a way that they are protected from vulnerabilities due to UID reuse."
- `BindPaths=`, `BindReadOnlyPaths=` (Added in version 233): "**Note that the destination directory must exist or systemd must be able to create it. Thus, it is not possible to use those options for mount points nested underneath paths specified in `InaccessiblePaths=`, or under `/home/` and other protected directories if `ProtectHome=yes` is specified.** TemporaryFileSystem= with ':ro' or `ProtectHome=tmpfs` should be used instead."
- `ProtectProc=` (Added in version 247): "...it is generally recommended to run most system services with this option set to `invisible`. This is implemented via file system namespacing, and thus cannot be used with services that shall be able to install mount points in the host file system hierarchy. Note that the root user is unaffected by this option, so for it to be effective it has to be used together with `User=` or `DynamicUser=yes`..." — `systemd.exec(5)`, read locally.
- nginx runs its master as root and its workers as an unprivileged user (default `nobody` in the upstream build; distributions conventionally set `user www-data;` in the main `nginx.conf`); the process listing in the official docs shows `nginx: master process` as `root` and `nginx: worker process` as `nobody` — [Controlling nginx](https://nginx.org/en/docs/control.html). The `user` directive is main-context only.

### Inferences
- **Directory-by-directory permission requirements:**
  - `/var/www/` and `/var/www/<app>/` — `root:deploy 0755`. The service user needs `o+x` here purely to *traverse* down to the release; `deploy` needs `o+x` so nginx can also traverse. The `deploy` user needs **write + execute on this directory** (the parent of `current`) because `rename(2)` of the `current` symlink requires write+execute on the *parent directory*, not on the symlink or its target. This is the single most commonly mis-set permission: owning `current` is not enough; you must be able to replace the directory entry.
  - `/var/www/<app>/releases/` — `root:deploy 0755` (or `deploy:deploy 0755` if `deploy` creates releases). `deploy` needs `rwx` here. The service user and nginx need `r-x` (traverse + list).
  - `/var/www/<app>/releases/<id>/` — `root:deploy 0755` for code (read-only to the service user: `r-x`). If releases are created with `0700` or `0750` and the service user is not in the owning group, the app fails to start with a confusing permission error at exec time. **Release directories must be world-traversable and world-readable (`o+rx`) unless a shared group is used deliberately.** Since the `deploy` user may be an unprivileged account while the service runs as a different one, and `systemctl` may run as root, `o+rx` on the release tree is the simplest correct default.
  - `/var/www/<app>/current` — a symlink, owned by `deploy`. Symlink ownership is irrelevant to resolution; what matters is the permissions of the directory containing it and of the target.
  - `/var/lib/<app>/` — `blog:blog 0750` via `StateDirectory=blog` (systemd creates and chowns this, and it survives `ProtectSystem=strict` because it is the sanctioned writable path). This is where uploads, caches-that-must-persist, and any mutable state belong.
  - `/var/cache/<app>/` — `blog:blog 0750` via `CacheDirectory=blog`. Safe to delete; must be outside the release tree.
  - `/etc/nginx/sites-available/<app>.conf` — `root:root 0644`. Owned by root because the deploy's `nginx -t` and `systemctl reload nginx` need root, and a config file writable by the app's service user is a privilege-escalation path.
  - The systemd unit `/etc/systemd/system/<app>.service` — `root:root 0644`.
- **Pitfall: an app that writes into `current/`.** Because `current` is a symlink into an immutable release directory, any write there (compiled assets, logs, `tmp/`, an SQLite file) either mutates the release artifact — so a rollback "rolls back" to already-corrupted code — or is lost the instant the symlink is swapped. Combined with `ProtectSystem=strict` (implied by `DynamicUser=`, and explicitly set in the Q3 unit) it becomes a hard `EROFS`/`EACCES` failure. **Shipyard must enforce at install time that the app's writable paths are outside the release tree, using `StateDirectory=`/`CacheDirectory=`/`RuntimeDirectory=` plus explicit `ReadWritePaths=`.** Every `ReadWritePaths=`/`BindPaths=` destination must exist before the unit starts, or systemd fails to set up the namespace — a hard start failure, not a warning.
- **Pitfall: the two identities disagreeing over the release tree.** If nginx workers (`www-data` by convention) serve static files directly out of the same release directory, `www-data` needs `o+rx` on the release tree. If the release tree is `0700`/`0750` because it is "deploy-private", every static asset 403s while the proxied dynamic route keeps working — a partial outage that looks like an application bug. Either grant `o+rx` on releases, or add `www-data` to the app's group via `SupplementaryGroups=www-data` on the nginx unit, or serve all static files through the app.
- **Pitfall: `DynamicUser=` is a bad fit for a Shipyard app that also runs an nginx-served static tree or a worker.** It allocates from UIDs 61184–65519 which recycle, the man page explicitly warns about leftover files being re-owned by a *different* service later, and it implies `ProtectSystem=strict` and `ProtectHome=read-only`. Use a **statically created** service user (e.g. via `sysusers.d`, as the man page recommends) so that `User=` names a stable identity that permissions, ACLs and `SupplementaryGroups=` can all reference.
- **Pitfall: the `deploy` user needing to drive systemd.** A deploy that runs `systemctl restart` must either be root or be granted a narrowly scoped sudoers rule. Granting the `deploy` user `sudo systemctl restart <its-own-unit>` is the right shape; granting passwordless `sudo systemctl restart nginx` as well is necessary for config deploys; granting blanket `sudo ALL` to the deploy account defeats the entire purpose of the control plane. Note also that the `deploy` user needs read access to the system journal — by default "only root and users who are members of a few special groups are granted access to the system journal", specifically `systemd-journal`, `adm`, `wheel` — or `journalctl -u` from the deploy's own health-check context will silently return nothing.
- **Pitfall: `ProtectHome=yes`/`tmpfs` interacting with writable paths.** The `BindPaths=` documentation is explicit that destinations "nested underneath paths specified in `InaccessiblePaths=`, or under `/home/` and other protected directories if `ProtectHome=yes`" are not usable, and that `TemporaryFileSystem= with ':ro'` or `ProtectHome=tmpfs` should be used instead. If an app's `StateDirectory=`-equivalent happens to land under a protected path, the namespace setup fails and the service does not start.

### Gaps
- I did not verify whether `StateDirectory=`, `CacheDirectory=`, `LogsDirectory=` and `RuntimeDirectory=` accept absolute paths outside `/var/lib` and `/var/cache`, nor the exact minimum versions of each. The `DynamicUser=` text confirms they exist and their purpose, but not their version history or path constraints. Shipyard should confirm the directory-creation semantics on the target systemd version.
- I did not find an authoritative statement that `rename(2)` requires write+execute on the *parent* directory rather than on the symlink. This is standard POSIX filesystem semantics, well established, but it is not from a source I fetched in this pass. It is load-bearing for the permission design, so it is worth confirming against a filesystem-semantics reference before the permission model is finalised.
- The conventional nginx worker username (`www-data` on Debian/Ubuntu, `nginx` on RHEL) is distribution-specific and I did not confirm any particular distro's value. Shipyard should discover it, not assume it.
- I did not research `ACL`-based solutions (`setfacl -m u:www-data:rx`) as an alternative to `o+rx` on releases; that would likely be the more secure answer but is unverified here.

---

## Cross-cutting: verified minimum-version summary

| Feature | Min systemd | Source |
|---|---|---|
| `Type=exec` | **240** | [systemd 240 release announcement](https://lists.freedesktop.org/archives/systemd-devel/2018-December/041852.html) |
| `journalctl --cursor-file=FILE` | **242** | `journalctl(1)`, local |
| `journalctl --after-cursor=` | **206** | `journalctl(1)`, local |
| `journalctl --show-cursor` | **209** | `journalctl(1)`, local |
| `journalctl -c/--cursor=` | **193** | `journalctl(1)`, local |
| `journalctl -b/--boot=` | **186** | `journalctl(1)`, local |
| `systemctl --disk-usage` | **190** | `journalctl(1)`, local |
| `journalctl --vacuum-*` | **218** | `journalctl(1)`, local |
| `journalctl --rotate` | **227** | `journalctl(1)`, local |
| `systemctl try-reload-or-restart` | **229** | `systemctl(1)`, local |
| `systemctl -P` (`--value --property`) | **246** | `systemctl(1)`, local |
| `journalctl --invocation=ID[±offset]` | **257** | `journalctl(1)`, local — **short `-I` takes NO argument (it ≡ `--invocation=0`); pass an ID only via the long form** |
| `journalctl _SYSTEMD_INVOCATION_ID=<ID>` (raw field match) | **232** | `systemd.journal-fields(7)`; systemd 232 NEWS — version floor is when invocation IDs appeared, not the reader option |
| `journalctl --synchronize-on-exit=` | **258** | `journalctl(1)`, local |
| `ExecCondition=` | **243** | `systemd.service(5)`, local (line 408) |
| `ExecReloadPost=` | **259** | `systemd.service(5)`, local (line 447) |
| `RestartSteps=`, `RestartMaxDelaySec=` | **254** | `systemd.service(5)`, local (lines 546, 557) |
| `DynamicUser=` | **232** | `systemd.exec(5)`, local |
| `ProtectProc=`, `ProcSubset=` | **247** | `systemd.exec(5)`, local |
| `BindPaths=`, `BindReadOnlyPaths=` | **233** | `systemd.exec(5)`, local |
| `ExecSearchPath=` | **250** | `systemd.exec(5)`, local |
| `Type=notify-reload`, `ReloadSignal=` | **253** | [systemd 253 NEWS](https://github.com/systemd/systemd/blob/main/NEWS) ("A new service type `Type=notify-reload` is defined … A new setting `ReloadSignal=` …"); `systemd.service(5)` annotates `ReloadSignal=` "Added in version 253" |
| `NRestarts` property | **235** | systemd 235 NEWS ("For each service unit a restart counter is now kept … `systemctl show -p NRestarts`") |
| `InvocationID` property / `$INVOCATION_ID` / `GetUnitByInvocationID()` | **232** | systemd 232 NEWS (CHANGES WITH 232) |
| `notify-reload`: must catch/block `ReloadSignal=` before `READY=1` | **262 (breaking)** | systemd 262 NEWS (CHANGES WITH 262) |
| `StartLimitIntervalSec=`/`StartLimitBurst=` in `[Unit]` | **unconfirmed** (present in `[Unit]` today) | `systemd.unit(5)`, local |
| `daemon-reload` refuses with <16 MiB free in `/run` | **233** | [systemd 233 release announcement](https://lists.freedesktop.org/archives/systemd-devel/2017-March/038419.html) |

## Cross-cutting: outage-causing pitfalls, ranked

1. **Writing a config file in place instead of `mv -T`-ing it into place.** nginx's master or an `include` glob can read a partial file. Always stage in the same directory and rename.
2. **Using `systemctl restart nginx` for a config change.** Drops in-flight requests and creates a window with no listener. Use reload.
3. **Using `nginx -s reload` instead of `systemctl reload nginx`.** Signals whichever master the *default* pid path points at, which is not necessarily the running one under a custom `-c`/`-p`/sandbox. Use systemd, which carries the unit's own flags.
4. **Running `nginx -t` and the reload without an exclusive lock.** Two concurrent deploys interleave and nginx can end up on a config neither intended.
5. **Building deploy auto-restart on `PathChanged=`/`PathModified=`.** Confirmed broken for `ln -sfn` + `mv -T` on systemd 255.2 and still open upstream (#31941). The deploy silently does not take effect. Drive `systemctl restart` explicitly.
6. **Putting the unit file inside the release directory.** It vanishes on the next deploy; the app fails to start on the next reboot or `daemon-reload`. Keep it in `/etc/systemd/system`.
7. **Using `Type=simple`.** `systemctl start` reports success even when the binary is missing or `User=` does not exist — a broken deploy reports as green. Use `Type=exec` (v240+) or `Type=notify`.
8. **Leaving `RestartSec=` at its 100 ms default with a restart-looping app.** A health check polls a briefly-open port, sees 200, and declares a crash-looping deploy healthy. Also: a health check that only samples the *end* state misses the race — diff `NRestarts` (and/or `SubState=auto-restart`) across the whole observation window.
9. **Not setting `StartLimitBurst`/`StartLimitIntervalSec` explicitly.** A crash loop may run forever on whatever the distro's `DefaultStartLimitBurst=` happens to be. And the reverse trap: those limits "apply to all kinds of starts (including manual)", so a deploy that retries a few times can trip the limiter and strand the unit in `failed`. Set them generously and `systemctl reset-failed` before each deploy attempt.
10. **Using `restart` where `reload` was intended — or vice versa.** `reload` on a code deploy is a silent no-op that reports success while old code runs. Guard by asserting `InvocationID` changed.
11. **Using `reload-or-restart` instead of `try-reload-or-restart`.** `reload-or-restart` *starts* a unit that is not running, so a deploy can resurrect an app an operator deliberately stopped.
12. **`TimeoutStopSec=` shorter than the app's slowest request.** In-flight requests are SIGKILLed; the client sees truncated responses and the deploy sees success. Silent data-corruption-shaped failure.
13. **Default `KillMode=control-group` with a preforking app.** SIGTERM hits every process in the cgroup at once, so the parent can exit before workers finish draining. `KillMode=mixed` for Puma/Unicorn-style apps.
14. **Using an nginx-local `/healthz` as the deploy gate.** It passes while the app is down. Use a distinct, app-proxied health path.
15. **Enabling `open_file_cache` on a root under `current`.** Serves the previous release's assets until `open_file_cache_valid` (default 60s) expires — mixed-version asset graphs.
16. **Setting `disable_symlinks on` in a global nginx hardening pass.** Breaks every symlinked release root with 403/404s.
17. **Leaving `proxy_buffering on` for SSE/streaming endpoints.** Clients hang; looks like an app bug, not a proxy bug.
18. **Trusting a journal resume cursor indefinitely.** The format is "private and subject to change"; cursors die with reboots, vacuuming and upgrades. A client that does not check `journalctl`'s exit status shows zero new entries forever and reports a healthy log stream. Worse, a cursor whose **boot ID is wrong/unknown is silently ignored (rc=0, no warning) and the reader seeks by sequence number in the current journal** — a fail-OPEN (verified on 262). Store the boot ID beside the cursor and compare it to `/proc/sys/kernel/random/boot_id`; do not rely on exit status alone. Prefer an invocation-scoped match (`journalctl _SYSTEMD_INVOCATION_ID=<ID>`, or `--invocation=<ID>` on ≥257).
19. **Writing `journalctl -I <InvocationID>`.** The short `-I` takes **no argument** (it is `--invocation=0`, "latest invocation"), so the ID is parsed as a positional match and the command fails with `Failed to add match '<ID>': Invalid argument` (verified on 262). Use `--invocation=<ID>` or the raw field match `_SYSTEMD_INVOCATION_ID=<ID>`. The `journalctl(1)` synopsis line `-I, --invocation=ID…` actively misleads here.
20. **Deploying to a host with `Storage=volatile` or `Storage=auto` and no `/var/log/journal`.** Log history is RAM-only and evaporates on reboot; a deploy control plane that cannot read its own failed deploy's logs cannot debug them.
21. **Not checking `journalctl`'s exit status** in any log-capture path, per the above.
22. **An app writing into `current/`.** Mutates the release artifact (breaking rollback) or hits `EROFS` under `ProtectSystem=strict`. All mutable state goes to `StateDirectory=`/`CacheDirectory=`/`ReadWritePaths=`.
23. **Release directories not world-traversable.** `0700`/`0750` releases mean the service user and nginx workers cannot `exec` the binary or read assets; failures appear as permission errors at exec time, or 403s on static files only.
24. **Using `ExecCondition=` for release preflight.** A skip "causes the unit to transition from `active` to `inactive`", so a failed preflight *stops the running release* instead of leaving it up. Preflight before the swap, in the deploy script.
25. **Calling `systemctl daemon-reload` on every deploy for no reason.** Pointless, and it can hard-fail the deploy (16 MiB `/run` guard) while providing zero benefit, because the unit file did not change.
26. **Using `Type=forking`.** Discouraged upstream; makes `MainPID` heuristic, which corrupts every reconciliation signal and makes `ExecReload=kill -HUP $MAINPID` unreliable.
27. **Shipping a `notify-reload` unit that installs its `ReloadSignal=` handler after `READY=1`.** systemd 262 requires the handler to be caught or blocked before `READY=1`, else the service fails to start with a protocol error (breaking change on 262).

## Gaps (consolidated)

- ~~**`NRestarts` and `InvocationID` minimum versions: not found.**~~ **RESOLVED: `NRestarts` = systemd 235; `InvocationID` / `$INVOCATION_ID` / `GetUnitByInvocationID()` = systemd 232** (systemd NEWS, CHANGES WITH 235 and 232). Still feature-detect at runtime on ancient hosts.
- **`NRestarts` reset semantics: not verified.** Whether it resets on `systemctl restart`, `reset-failed`, `daemon-reload`, or a state transition is unknown and directly affects whether it can serve as a per-deploy counter. Working hypothesis from the 235 NEWS wording ("increased each time the service is restarted due to `Restart=`") is that it counts **automatic** restarts only and is *not* bumped by a deploy-initiated `systemctl restart` — which would make it a good crash-loop signal but a poor "did the deploy take effect" signal. **Must be measured empirically before relying on it.**
- ~~**`Type=notify-reload` / `ReloadSignal=` minimum version: not found.**~~ **RESOLVED: systemd 253** (systemd 253 NEWS introduces both; `systemd.service(5)` annotates `ReloadSignal=` "Added in version 253"). Additional **262 breaking change**: a `notify-reload` service must catch or block `ReloadSignal=` before sending `READY=1`, or it fails to start with a protocol error.
- **journalctl's behaviour on an invalid/stale cursor: now partly established empirically (systemd 262), still undocumented.** Garbage cursor → rc=1 fail-closed; empty file → rc=0 documented fallback; **wrong/unknown boot ID → rc=0, silent, fail-OPEN** (seeks by sequence number in the current journal). `-b <unknown-boot>` by contrast fails closed. **Consequence: exit-status checking alone is insufficient — the client must itself compare the cursor's boot ID to `/proc/sys/kernel/random/boot_id`.** Still untested: effect of `--vacuum-size`/`--rotate` on a persisted cursor (not destructive-tested here).
- ~~**Cursors being scoped to a boot: not documented.**~~ **Partly resolved:** the boot ID inside a cursor is **not validated** (silently ignored when unknown), so the client must do the boot-ID comparison itself. The client-side recommendation stands but the mechanism is now observed, not merely inferred.
- **`Result=` string enumeration: not verified.** Only the exit-*causes* were sourced (from the `Restart=` table), not the `Result=` values. Still needs a live failure to confirm.
- ~~**nginx `ngx_http_proxy_module` not fetched.**~~ **RESOLVED:** the official module docs were fetched; `proxy_pass` URI-rewriting, `proxy_set_header` defaults (`Host $proxy_host; Connection close`), `proxy_http_version` default (`1.0`, →`1.1` in nginx ≥ 1.29.7), `proxy_read_timeout` (`60s`), `proxy_redirect` (`default`), `proxy_buffering` (`on` + `X-Accel-Buffering`), `proxy_intercept_errors` (`off`) are now cited in Q9.
- **Whether nginx resolves `root` symlinks at config-load time or request time: not answered.** The design recommendation (validate the symlink target explicitly; don't rely on `-t`) holds regardless.
- **`open_file_cache` behaviour across `systemctl reload`: inferred**, not documented.
- **Issue #19726** (the PR that closed #17727) was not read; whether it was a fix or a wontfix is unverified. The evidence that #31941 remains open on 255.2 is the stronger signal.
- **Maintained diagnosis for the path-unit failure: not found.** No upstream maintainer statement of root cause; the ATTRIB/DELETE_SELF + watch-on-inode explanation is my reconstruction from the two observed inotify traces.
- **`systemctl daemon-reload` man-page text: not captured verbatim.** The <16 MiB `/run` failure is from the v233 announcement.
- **This session's host DOES run systemd (262, `262-1-arch`), so `systemctl show`/`journalctl`/`systemctl --version` were executed and the invocation-arity and cursor behaviours were measured (Q8).** What is still unvalidated on a **deploy target** is the unit-specific behaviour: exact `Result=`/`SubState=` spellings under real failures, `NRestarts` reset semantics, and the `current`-symlink/restart interaction (Q3). **Shipyard's integration test suite must cover all three.**
- **Distribution-specific `ExecReload=` for nginx: unverified.** Read it from the installed unit rather than hardcoding.
- **`SendSIGHUP=` default: unverified.**
- **Version history of `StateDirectory=`/`CacheDirectory=`/`RuntimeDirectory=`/`LogsDirectory=`, and their path constraints: unverified.**
- **Conventional nginx worker username: unverified and distro-specific.** Discover, do not assume.
- **Permission model detail (write+execute on the parent dir for `rename(2)`): standard POSIX, not sourced in this pass.** Load-bearing; confirm.
