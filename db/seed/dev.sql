-- =====================================================================
-- Shipyard :: dev seed data.
--
-- Produces a working, believable database from repo files alone:
--     make db-reset   # createdb + migrate + seed + shipyard_seed (Go, bulk logs)
--     make db-load    # just this file
--
-- Deterministic: no random(), no clock-dependent branches, so two checkouts
-- produce byte-comparable data and EXPLAIN plans are stable.
-- Wrapped in one transaction: a failed seed leaves an empty database, never a
-- half-populated one.
-- =====================================================================

BEGIN;

-- 6 servers: a 4-host production pool, a staging pair, one dev box.
INSERT INTO servers (id, name, ssh_host, ssh_user, work_dir, last_seen_at) VALUES
    (1, 'web-01',  '10.0.1.11', 'deploy', '/srv/shipyard', now() - interval '12 seconds'),
    (2, 'web-02',  '10.0.1.12', 'deploy', '/srv/shipyard', now() - interval '11 seconds'),
    (3, 'web-03',  '10.0.1.13', 'deploy', '/srv/shipyard', now() - interval '9 seconds'),
    (4, 'api-01',  '10.0.2.21', 'deploy', '/srv/shipyard', now() - interval '30 seconds'),
    (5, 'stg-01',  '10.0.9.31', 'deploy', '/srv/shipyard', now() - interval '4 minutes'),
    (6, 'dev-01',  '10.0.99.5', 'deploy', '/srv/shipyard', now() - interval '2 hours');
SELECT setval('servers_id_seq', 100, true);

INSERT INTO projects (id, name, repository_url, build_command, run_command, next_deployment_no) VALUES
    (1, 'shop',    'git@github.com:operator/shop.git',    'make build',            'make run',    2501),
    (2, 'api',     'git@github.com:operator/api.git',     'go build -o ./bin/api', './bin/api',    901),
    (3, 'web',     'git@github.com:operator/web.git',     'pnpm build',            'pnpm start',  751),
    (4, 'landing', 'git@github.com:operator/landing.git', 'make build',            'make serve',   98);
SELECT setval('projects_id_seq', 100, true);

INSERT INTO environments (id, project_id, name) VALUES
    (1, 1, 'production'), (2, 1, 'staging'),
    (3, 2, 'production'), (4, 2, 'staging'),
    (5, 3, 'production'),
    (6, 4, 'production');
SELECT setval('environments_id_seq', 100, true);

INSERT INTO services (id, server_id, name, unit_name, observed_state, observed_at) VALUES
    (1, 1, 'web',  'shop-web.service',    'running',  now() - interval '14 seconds'),
    (2, 1, 'api',  'shop-api.service',    'running',  now() - interval '14 seconds'),
    (3, 2, 'web',  'shop-web.service',    'running',  now() - interval '13 seconds'),
    (4, 2, 'api',  'shop-api.service',    'running',  now() - interval '13 seconds'),
    (5, 3, 'web',  'shop-web.service',    'degraded', now() - interval '8 minutes'),
    (6, 3, 'api',  'shop-api.service',    'degraded', now() - interval '8 minutes'),
    (7, 4, 'api',  'api-api.service',     'running',  now() - interval '28 seconds'),
    (8, 5, 'web',  'web-web.service',     'running',  now() - interval '4 minutes'),
    (9, 6, 'web',  'landing-web.service', 'down',     now() - interval '2 hours');
SELECT setval('services_id_seq', 100, true);

-- ---- 10,000 deployments ---------------------------------------------
-- One generator row per deployment. The last ~12 rows are pinned to a known
-- in-flight/live mix so the reconcile and fleet queries have real work to do.
WITH g AS (
    SELECT
        n,
        -- deterministic pseudo-random from n: md5 is stable across runs,
        -- unlike random()
        (('x' || substr(md5(n::text), 1, 8))::bit(32)::bigint & 2147483647) AS r
    FROM generate_series(1, 10000) AS n
), shaped AS (
    SELECT
        n,
        (('x' || substr(md5(n::text), 1, 8))::bit(32)::bigint & 2147483647) AS r,
        1 + (n % 4)                 AS project_id,
        1 + (n % 6)                 AS server_id,
        substr(md5(n::text), 1, 40) AS commit_sha,
        now() - (interval '90 days' * (n / 10000.0))
          - (interval '4 minutes' * (n % 10000))            AS created_at
    FROM g
), numbered AS (
    -- Gapless, monotonic per project. #42 means a81c92e forever.
    SELECT s.*,
           row_number() OVER (PARTITION BY project_id ORDER BY n)::integer AS deployment_no
    FROM shaped s
), decided AS (
    SELECT
        d.*,
        -- environment must belong to the same project
        CASE d.project_id
            WHEN 1 THEN 1 + (d.n % 2)   -- production | staging
            WHEN 2 THEN 3 + (d.n % 2)
            WHEN 3 THEN 5
            ELSE 6
        END AS environment_id,
        CASE
            -- a deliberately small, realistic in-flight population: at most a
            -- handful of deploys can be running at once, no matter how much
            -- history exists. This is what makes deployments_inflight_idx small.
            WHEN d.n > 9994 THEN CASE d.n % 3
                WHEN 0 THEN 'CLONING'::deployment_status
                WHEN 1 THEN 'BUILDING'::deployment_status
                ELSE  'FAILED'::deployment_status
            END
            WHEN d.n % 997  = 1 THEN 'BUILDING'::deployment_status   -- a few stale
            WHEN d.n % 101  = 0 THEN 'PENDING'::deployment_status
            WHEN d.n % 37   = 0 THEN 'FAILED'::deployment_status
            ELSE 'RUNNING'::deployment_status
        END AS status
    FROM numbered d
), winner AS (
    -- Newest RUNNING deployment per (server, project) pair.
    --
    -- The filter MUST happen in a subquery, not as a CASE around the window:
    -- a CASE wrapping row_number() still numbers every row in the partition,
    -- so the newest (in-flight) row would take rank 1 and no RUNNING row would
    -- ever be marked active. row_number() has no FILTER clause.
    SELECT server_id, project_id, min(n) AS winner_n
      FROM (
          SELECT n, server_id, project_id
            FROM decided
           WHERE status = 'RUNNING'
      ) AS running_only
     GROUP BY server_id, project_id
)
INSERT INTO deployments (
    id, project_id, deployment_no, server_id, environment_id, commit_sha, status,
    active, attempt, queued_at, started_at, finished_at, error_message, created_at
)
SELECT
    k.n,
    k.project_id,
    k.deployment_no,
    k.server_id,
    k.environment_id,
    k.commit_sha,
    k.status,
    -- one active per (server, project) pair; the partial unique index is the
    -- real enforcement, this just makes the seed satisfy it
    (w.winner_n = k.n),
    CASE WHEN k.status = 'PENDING' THEN 1 ELSE 2 END,
    k.created_at,
    CASE WHEN k.status = 'PENDING' THEN NULL ELSE k.created_at + interval '1 second' END,
    CASE WHEN deployment_status_is_terminal(k.status)
         THEN k.created_at + interval '3 minutes' ELSE NULL END,
    CASE WHEN k.status = 'FAILED' THEN 'exit status 1: build target ' || (k.r % 7)::text
         ELSE NULL END,
    k.created_at
FROM decided k
LEFT JOIN winner w
       ON w.server_id = k.server_id AND w.project_id = k.project_id;
SELECT setval('deployments_id_seq', 100000, true);

-- ---- deployment_services --------------------------------------------
-- Each non-pending deployment owns its project's services on its server.
INSERT INTO deployment_services (deployment_id, service_id)
SELECT d.id, s.id
  FROM deployments d
  JOIN services s ON s.server_id = d.server_id
                 AND s.name IN (SELECT name FROM services WHERE server_id = d.server_id LIMIT 2)
 WHERE d.status <> 'PENDING'
  AND d.id % 3 = 0;

-- ---- log partitions for the seed range ------------------------------
-- The seed backfills 90 days of history, so the monthly partitions must exist
-- first. In production this is a scheduled job (`make db-partitions`).
-- Because there is deliberately no default partition, a month with no partition
-- fails loudly right here rather than silently accumulating forever.
SELECT shipyard_ensure_log_partition(date_trunc('month', g)::date)
  FROM generate_series(
         date_trunc('month', now()) - interval '5 months',
         date_trunc('month', now()) + interval '1 month',
         interval '1 month') AS g;

-- ---- env vars -------------------------------------------------------
-- value_sealed is fake ciphertext for dev; the real path is AES-256-GCM.
-- Development/test only.
INSERT INTO project_env (project_id, name, value_sealed, value_fingerprint) VALUES
    (1, 'DATABASE_URL', '\x000102030405060708090a0b0c'::bytea, decode(md5('postgres://shop'), 'hex')),
    (1, 'SESSION_SECRET', '\x101112131415161718191a1b1c'::bytea, decode(md5('s3cr3t'), 'hex')),
    (2, 'API_KEY', '\x202122232425262728292a2b2c'::bytea, decode(md5('key-1'), 'hex')),
    (2, 'PORT', '\x303132333435363738393a3b3c'::bytea, decode(md5('8080'), 'hex')),
    (3, 'SENTRY_DSN', '\x404142434445464748494a4b4c'::bytea, decode(md5('https://sentry.example/1'), 'hex'));

-- Env snapshot for the 40 most recent non-pending deployments: this is what
-- proves reproducibility later.
INSERT INTO deployment_env (deployment_id, name, value_sealed, value_fingerprint)
SELECT d.id, e.name, e.value_sealed, e.value_fingerprint
  FROM deployments d
  JOIN project_env e ON e.project_id = d.project_id
 WHERE d.id > 9960 AND d.status <> 'PENDING';

COMMIT;

-- ---- build logs -----------------------------------------------------
-- 100k lines across ~1k deployments. Loaded by `cmd/seed` via pgx CopyFrom
-- (10-20x faster than INSERT and it takes the FK lock once per COPY rather
-- than once per row). Left out of this file for that reason; see
-- db/seed/logs/seed.go.
