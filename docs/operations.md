# Operations Guide

How to monitor, maintain, and recover the reporting stack in a running environment.

## Verifying the pipeline is healthy

Run these checks in order to confirm end-to-end data flow:

```bash
make verify-services    # Kafka, Connect, Kafka UI, ClickHouse healthy
make verify-cdc         # Connector running, topics exist, heartbeat advancing
make verify-ingestion   # ClickHouse raw tables have data
make verify-dbt         # Curated marts built and have data
```

If all pass, the pipeline is flowing normally.

## Common failure scenarios

### Source database restarted

**What happens:** Debezium loses the connection and retries for up to 5 minutes (`errors.retry.timeout: 300000`). If the database recovers within that window, CDC resumes automatically with no data loss.

**If the database is down longer than 5 minutes:** The connector task enters `FAILED` state. The watchdog service detects this within 30 seconds and restarts the task automatically. No manual action needed.

**How to verify:** `make connector-status` — all tasks should show `RUNNING`.

### Kafka Connect restarted

**What happens:** Connect restores connector configuration from its internal Kafka topics (`_connect-configs`, `_connect-offsets`, `_connect-status`). Connectors resume from their last committed offset — no data loss.

**If connector doesn't restore** (e.g., internal topics lost after `make reset`): The watchdog detects the missing connector and re-registers it. This triggers a full re-snapshot of the source database.

**How to verify:** `make connector-status`

### Reporting stack started before source database

**What happens:** Services start normally. The connector registration (during `make setup`) fails because the source DB is unreachable. The watchdog retries registration periodically until the DB becomes available.

**Manual alternative:** Once the source DB is up, run `make recover`.

### Pipeline silently stopped (data not updating)

**Most likely cause:** Connector task is in `FAILED` state. The connector itself shows `RUNNING` but the task inside it has failed — this is the most common silent failure mode.

**Fix:**

```bash
make connector-status     # check task states
make recover              # auto-fixes failed tasks
```

### Replication slot invalidated

**What happens:** If the reporting stack was down for an extended period, PostgreSQL's `max_slot_wal_keep_size` (configured in source DB setup) invalidates the replication slot to protect disk space. CDC events during the gap are permanently lost from the stream.

**Recovery:** Delete the connector, drop the orphaned slot, and re-register. This triggers a full re-snapshot.

```bash
make delete-connector
# On the source database:
# SELECT pg_drop_replication_slot('debezium_reporting');
make register-connector   # creates new slot, triggers full snapshot
make dbt-build            # rebuild curated marts from fresh data
```

See [source-db-setup.md](source-db-setup.md#recovery-after-slot-invalidation) for details.

## The watchdog service

The `connect-watchdog` container runs alongside Kafka Connect and polls connector health every 30 seconds. It handles:

| Condition | Action |
|---|---|
| Kafka Connect unreachable | Waits and retries |
| Connector missing (404) | Re-registers from the analytics-core package config |
| Connector task FAILED | Restarts the task via Connect REST API |
| Everything healthy | No action (silent) |

**Configuration:**

| Variable | Default | Description |
|---|---|---|
| `WATCHDOG_INTERVAL` | `30` | Seconds between health checks |

**Logs:** `docker logs soldevelo-reporting-stack-connect-watchdog-1 -f`

## make recover

One-command pipeline restoration. Safe to run any time — it's idempotent.

```bash
make recover
```

Steps performed:
1. Verifies core services are healthy
2. Checks connector status
3. Restarts any `FAILED` tasks, or re-registers the connector if missing
4. Verifies CDC is streaming (heartbeat advancing)
5. Checks ClickHouse Kafka consumers for transport errors — restarts ClickHouse if needed
6. Verifies ClickHouse ingestion

Note: if the watchdog fires during a `make recover` run, both may restart the same task simultaneously. This is safe — the Kafka Connect API handles duplicate restarts gracefully.

Use this when:
- You suspect the pipeline stopped flowing
- After a source DB restart that exceeded the retry window
- After restarting the reporting stack
- As a general "make it work" command

## Monitoring recommendations

For production deployments, monitor these signals:

| Signal | What to watch | Threshold |
|---|---|---|
| Connector task state | `FAILED` tasks | Any FAILED task = alert |
| Replication slot lag | `pg_replication_slots.confirmed_flush_lsn` lag | > 50% of `max_slot_wal_keep_size` |
| Replication slot status | `pg_replication_slots.wal_status` | `lost` = immediate action |
| ClickHouse freshness | `max(_ingested_at)` in raw tables | Older than expected refresh interval |
| Airflow DAG status | `platform_refresh` DAG failures | Any failure = investigate |
| Kafka consumer lag | ClickHouse Kafka Engine consumer group | Growing lag = ClickHouse falling behind |

The Airflow `platform_refresh` DAG includes a freshness gate — if raw data is stale (older than `FRESHNESS_MAX_AGE_MINUTES`, default 120), it skips the dbt build to avoid serving stale curated data.

## Planned version upgrades

### ClickHouse 26.8 LTS — target window: ~September 2026

ClickHouse 25.8 LTS (the version pinned in `compose/docker-compose.yml`) was released August 2025 and receives security/bug fixes for ~12 months. The next LTS line is expected to be **26.8** (ClickHouse cuts LTS releases at the `.3` and `.8` minor versions twice per year). Once 26.8 is published and has had ~1 month of patch releases, plan a coordinated upgrade.

Upgrade checklist (when 26.8 ships):
1. Verify the `clickhouse/clickhouse-server:26.8.x.y-alpine` tag is available on Docker Hub
2. Read the 26.x release notes for breaking changes affecting Kafka engine DDL, JSONExtract functions, and `kafka_handle_error_mode = 'stream'` (these are the surfaces our pipeline depends on)
3. Bump the image tag in `compose/docker-compose.yml` and the version note in its header
4. `make reset && make up && make setup` against a non-production source, then run all `make verify-*` targets
5. Update the version note at the top of `docs/operations.md` to point at the next LTS

Until then, periodically pick up new patch releases on the `25.8.x.y-alpine` line for security fixes (the `.x.y` segment moves; the `25.8` major.minor stays).

### Superset 6.1.0 stable — move off the `6.1.0rc3` pre-release pin

`superset/Dockerfile` is currently pinned to `apache/superset:6.1.0rc3-py312` (a release candidate). This is intentional: Superset 6.0.0 stable has a native-filter bug ([apache/superset#34617](https://github.com/apache/superset/issues/34617)) where the dashboard filter Apply button stays disabled and user selections never propagate to chart queries. The fix (PR [#38479](https://github.com/apache/superset/pull/38479)) was merged into Superset master after 6.0.1 was cut, so neither 6.0.0 nor 6.0.1 contain it; 6.1.0rc3 does.

**Second known issue carried by 6.1.0rc3:** native filters with `filter_bar_orientation: HORIZONTAL` still exhibit the same Apply-button-disabled / selections-don't-propagate behavior — the fix only landed for the default vertical (sidebar) layout. As a workaround we removed `filter_bar_orientation: HORIZONTAL` from every migrated dashboard. Re-evaluate whether horizontal filter bars work when 6.1.0 stable ships; if so, add the orientation back to dashboards where the horizontal layout fits better.

When **Superset 6.1.0 stable** ships:
1. Confirm `apache/superset:6.1.0-py312` (or whatever the final tag is) is available on Docker Hub
2. Edit `superset/Dockerfile` — change the base image from `6.1.0rc3-py312` to the stable tag, and remove the comment block explaining the rc pin
3. Re-build (`make build SVC=superset-init`) and restart Superset
4. Smoke-test filter behavior on every dashboard (Apply button enables on filter pick → charts re-query with the filter applied) — `make verify-superset` does not cover this; manual click-through is needed
5. If filter Apply button is broken again, [#34617](https://github.com/apache/superset/issues/34617) regressed; downgrade or hold-back accordingly

Track Superset stable releases at <https://github.com/apache/superset/releases>. As of this note, 6.1.0rc3 was published 2026-05-01 and the stable cut typically follows within 2–4 weeks of the final rc.
