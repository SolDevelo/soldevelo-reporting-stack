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
