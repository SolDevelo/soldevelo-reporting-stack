# Runbook: Source database major upgrade (PostgreSQL)

A major version upgrade of the source PostgreSQL (for example 14 → 17, in place with `pg_upgrade`, as an RDS in-place upgrade, through an RDS Blue/Green deployment, or by dump/restore) always loses the Debezium replication slot: PostgreSQL only migrates logical slots when the *old* cluster is already 17 or newer, RDS refuses to upgrade while a logical slot exists, and a Blue/Green deployment refuses to be created when the blue instance has one ("external replication on the blue primary instance"). The publication and the `reporting_heartbeat` / `debezium_signal` tables survive `pg_upgrade`, both RDS paths and a whole-database `pg_dump`; a filtered restore (per schema, `--schema`, a target database created from another init) may drop them, so step 1 of the re-attach verifies them on every path.

This runbook keeps the pipeline consistent across the upgrade: no lost changes, no duplicates in the marts, and — if application writes are blocked for the duration — no re-snapshot. It was tested on a copy of the Malawi database (17 captured tables, 30 M `requisition_line_items`) against RDS and Docker sources (OLMIS-8422, November 2026).

## Prerequisites

- Debezium 3.5.0.Final (pinned in `connect/Dockerfile`) on Kafka Connect 8.2 streams from PostgreSQL 17 with `pgoutput`; tested in OLMIS-8422 on 17.11.
- Access to the Kafka Connect REST API (`localhost:8083` on the stack host) and `psql` on the source as a superuser or the replication role.
- The source application runs with its production profile. A ref-distro instance on `spring_profiles_active=demo-data,refresh-db` recreates its schemas on every start: the connector sees mass deletes and inserts, and the recreated tables fall out of the publication. Switch it to `production` after the demo data is loaded, before attaching the stack.
- For re-attach A: the ability to block application writes from the slot drain until the new slot exists (stop the application containers, or the whole upgrade window is already a maintenance window).
- The new cluster keeps the CDC parameters from [source-db-setup.md](source-db-setup.md): `wal_level = logical`, `max_replication_slots`, `max_wal_senders`, `max_slot_wal_keep_size`. `pg_upgrade` starts the new cluster from the new image's `initdb` defaults, not from the old `postgresql.conf` (in an early test with a plain `postgres:17` image the upgraded cluster came up with `wal_level = replica`; the `openlmis/postgres-upgrade:14-to-17` helper initialises the new cluster from the `openlmis/postgres:17` sample, which has `wal_level = logical`), and an RDS upgrade applies whatever parameter group you pick for the new version — check, do not assume.

## Two ways to re-attach

| | A. No re-snapshot (`snapshot.mode=no_data`) | B. Full re-snapshot (`make recover-slot`) |
|---|---|---|
| Precondition | application writes blocked from the slot drain until the new slot exists | none |
| Captures changes made between drop and re-register | not applicable (there are none) | yes, as a fresh snapshot of the current state — after the raw tables have been truncated, otherwise rows deleted in the meantime stay in the marts |
| Time after the database is back | ~20 s | 30–65 min for the Malawi tables, then `initial-dbt-build` |
| Raw tables | unchanged | one more full copy (`op = 'r'`) per table |
| When to use | planned upgrade window, writes stopped anyway | writes could not be blocked, or something went wrong |

Both start with the same detach steps.

## Detach (before the upgrade)

Do this after the application has been stopped (or put in a state where nothing writes to the captured tables) and before the database goes down.

1. Stop the watchdog. It re-registers a missing connector within a minute, and the re-registered connector will start a full snapshot the moment the database comes back — before you had a chance to choose.

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml stop connect-watchdog
   ```

2. Pause the refresh DAG so dbt does not run against a half-replicated state:

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml exec airflow-scheduler airflow dags pause platform_refresh
   ```

   `airflow dags pause` prints the state *before* the change (`is_paused | False` after a successful pause); confirm with `… exec airflow-scheduler airflow dags details platform_refresh | grep is_paused`.

3. Let the connector drain the slot. On the source:

   ```sql
   select active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
     from pg_replication_slots where slot_name = 'debezium_reporting';
   ```

   Wait until `lag` is a few hundred bytes (the heartbeat keeps writing, it never reaches exactly zero). On RDS the reading jumps: a WAL segment switch (`archive_timeout = 300`, 64 MB segments) moves `pg_current_wal_lsn` by up to 64 MB at once, and Debezium advances `confirmed_flush_lsn` only when it flushes its offsets, about once a minute, so the lag can show tens of MB and be back to a few hundred bytes a minute later. Wait for one such reading, not for a steady value; it took about two minutes in the RDS test. Take readings for two minutes with the application stopped: a few hundred bytes means drained; a few kB that does not move is usually the last heartbeat batch before the next offset flush (about once a minute), so wait one more interval; tens of kB or more that never drop mean the task is not consuming — check `/status` and the Kafka broker before going on.

4. Stop the connector, wait until it is `STOPPED`, **reset its offsets**, delete it:

   ```bash
   C=http://localhost:8083/connectors/openlmis-postgres-cdc
   curl -sf -X PUT $C/stop
   curl -sf $C/status >/dev/null || echo "no such connector — stop here"   # a connector that is already gone makes the loop below spin forever
   for i in $(seq 60); do curl -s $C/status | grep -q '"state":"STOPPED"' && break; sleep 1; done   # stop is asynchronous; offsets can only be reset on a STOPPED connector
   curl -sfS -X DELETE $C/offsets && curl -sfS -X DELETE $C   # "The Connect framework-managed offsets ... have been reset"; the connector is deleted only after the reset succeeded
   ```

   Resetting the offsets is not optional. With the old offsets left in Kafka Connect, the re-registered task fails immediately (`Last recorded offset is no longer available on the server`), creates no slot, and every change made after the upgrade is silently missing from the pipeline until someone notices. `make delete-connector` alone does **not** reset the offsets. The `&&` matters: a rejected reset (connector not yet `STOPPED`) must not be followed by the delete, or the stale offsets stay in Kafka Connect; `-S` prints the error that `-s` would otherwise hide. `-f` makes a rejected reset (connector not yet `STOPPED`) exit non-zero instead of printing a JSON error and going on.

5. Drop the slot on the source (RDS: required before the upgrade; Docker: it would be lost anyway):

   ```sql
   select pg_drop_replication_slot('debezium_reporting');
   ```

   Docker (ref-distro): `docker compose exec db psql -U postgres -d open_lmis -c "select pg_drop_replication_slot('debezium_reporting');"`. RDS: `psql -h <endpoint> -U <master user> -d <db>`.

Now upgrade the database. The upgrade itself is described in the `openlmis/postgres` README, section "Upgrading PostgreSQL 14 → 17"; its step on detaching and re-attaching the reporting stack mirrors this runbook.

## Re-attach A — no re-snapshot

Right after the database is back on the new version, **before application writes resume**:

1. Confirm the server parameters and the CDC objects:

   ```sql
   show wal_level;                 -- logical
   show max_replication_slots;     -- >= 2
   show max_wal_senders;           -- >= 4
   show max_slot_wal_keep_size;    -- what init-db.sql set, e.g. 2GB
   select count(*) from pg_publication_tables where pubname = 'dbz_publication';   -- expected: your allowlist + signal table
   select table_name from information_schema.tables
    where table_schema = 'public' and table_name in ('reporting_heartbeat', 'debezium_signal');
   ```

   Wrong parameters: fix them first ([source-db-setup.md](source-db-setup.md); `wal_level` needs a restart; RDS: `rds.logical_replication = 1` and `max_slot_wal_keep_size` in the parameter group of the new version). Missing publication or tables: re-apply the source init SQL (`reporting-stack/init-db.sql` in ref-distro or its deployment-specific copy).

2. Register the connector with `no_data`, so that the new slot is created now and nothing is snapshotted:

   ```bash
   DEBEZIUM_SNAPSHOT_MODE=no_data make register-connector
   ```

   (`.env` values override the environment inside `register-connector.sh`; if `.env` sets `DEBEZIUM_SNAPSHOT_MODE`, change it there for this step and revert afterwards.) The log shows `According to the connector configuration no snapshot will be executed` and the slot is `active` within seconds.

3. Resume application writes, start the watchdog, unpause the DAG, and verify:

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml start connect-watchdog
   docker compose --env-file .env -f compose/docker-compose.yml exec airflow-scheduler airflow dags unpause platform_refresh
   make verify-cdc && make reconcile
   ```

   A change made now on the source must appear in the matching `raw.events_*` table within seconds, with `op = 'u'`/`'c'` and **no** new `op = 'r'` rows.

   Starting the application with the ref-distro overlay re-runs `reporting-stack-init`, which sets the publication back to the table list in `reporting-stack/init-db.sql`: a table added by hand (operations.md, "Adding a new source table") drops out of CDC silently, and `verify-cdc` and `reconcile` stay green. Re-run the `pg_publication_tables` count from step 1 once the application is up, and keep every addition in `init-db.sql`.

4. Put the stored connector config back to the default snapshot mode, so that the next watchdog re-registration or `make recover-slot` behaves as [operations.md](operations.md) describes (`when_needed` with valid offsets does not snapshot; `register-connector.sh` is a `PUT` on the existing connector):

   ```bash
   make register-connector            # DEBEZIUM_SNAPSHOT_MODE unset, .env reverted
   ```

## Re-attach B — full re-snapshot

Use when writes happened between the slot drain and the new slot, whenever you are not sure, and always after the source was rolled back to a pre-upgrade snapshot (ClickHouse then holds changes the restored database never saw).

A re-snapshot only *adds* a current copy of every row; it never removes anything. The staging models keep the latest event per id and drop a row only when that event is a delete, so a record deleted while the stack was detached (no delete event was captured) or created on 17 and lost by a rollback would stay in the marts forever. Truncate the raw tables of the captured tables first — the re-snapshot then rebuilds them from the current state only:

```bash
ch() { docker compose --env-file .env -f compose/docker-compose.yml exec clickhouse clickhouse-client -q "$1"; }   # bash; a plain variable would not word-split in zsh
P=$(grep '^DEBEZIUM_TOPIC_PREFIX=' .env | cut -d= -f2 | tr -d '"'); P=${P:-openlmis}   # raw tables are named after the Debezium topic: <prefix>.<schema>.<table> with dots replaced
for t in $(grep '^SOURCE_PG_TABLE_ALLOWLIST=' .env | cut -d= -f2 | tr -d '"' | tr ',' ' '); do ch "TRUNCATE TABLE raw.events_${P}_${t//./_}"; done
FORCE=1 SKIP_DBT=1 make recover-slot   # drop slot, reset offsets, re-register, snapshot every captured table — no dbt yet
# wait for the snapshot to finish: row counts in ClickHouse raw versus the source, per table
make initial-dbt-build                 # dbt build --full-refresh
make reconcile
```

`recover-slot` also works when the slot and the connector are already gone after the detach (`Slot does not exist. Recovery will re-create it from scratch`, `Connector not registered — skipping delete`). Snapshot progress per table, in ClickHouse against the source:

```sql
select countIf(op = 'r' and _ingested_at >= '<UTC time recover-slot started>') from raw.events_openlmis_<schema>_<table>;  -- ClickHouse
select count(*) from <schema>.<table>;                                                                                    -- source
```

for every table in the allowlist; `requisition_line_items` finishes last.

`SKIP_DBT=1` matters: without it `recover-slot` runs `dbt build` right after the connector is registered, while the snapshot is still loading, and the incremental `mart_stock_status` keeps the rows built from that partial data until a `--full-refresh` (MW-1491). Judge the end of the snapshot per table (row counts in ClickHouse versus the source), not by the connector state, which is `RUNNING` from the first second; the tables finish minutes apart and `requisition_line_items` finishes last.

Then start the watchdog and unpause the DAG as above.

Consequences of every re-snapshot:

- The raw tables are append-only, so each snapshot adds a full copy of every captured table (the truncate above also keeps them from growing). After three snapshots of the Malawi data `raw.events_openlmis_requisition_requisition_line_items` held 92 M rows and `stg_requisition_line_items` exceeded the 20 GiB per-query memory limit in ClickHouse. Either purge the previous snapshot's rows (`ALTER TABLE raw.events_... DELETE WHERE op = 'r' AND _ingested_at < <start of the latest snapshot>`), or lower `CLICKHOUSE_MAX_THREADS` / raise `CLICKHOUSE_MAX_MEMORY_USAGE` in `.env` for the rebuild. The purge throws away the previous snapshot as a replay point (raw is otherwise the replay/debug history); the non-destructive alternative is to let `RAW_TTL_DAYS` expire it.
- Each snapshot also lands in Kafka. With the compose defaults the broker keeps its log segments in `/tmp/kafka-logs` inside the container, not on the mounted volume (a platform defect, tracked separately); two Malawi snapshots filled a 400 GB disk in the test. Watch the stack host's disk during a re-snapshot.
- While the snapshot runs the slot is inactive and WAL accumulates on the source; with `max_slot_wal_keep_size = 2GB` a long snapshot plus a Kafka hiccup invalidated the slot in the test (`wal_status = lost`). Raise the limit for the duration of the snapshot on large databases.

## RDS Blue/Green specifics

- The slot must be gone before `create-blue-green-deployment`; the publication may stay.
- The green instance gets the parameter group passed to `create-blue-green-deployment`: carry `rds.logical_replication = 1` and `max_slot_wal_keep_size` into the group for the new version, or no slot can be created after the switchover.
- Do not re-attach to the green instance; wait for the switchover (the endpoint name does not change) and re-attach to it as in A or B.
- Any large-object write on blue during the deployment degrades the replication and the deployment has to be recreated — the OpenLMIS services that write large objects (hapifhir, dhis2-integration) must stay down for the whole deployment, not only during the switchover.

## Troubleshooting

- **Task `FAILED` right after registering, `Last recorded offset is no longer available on the server`** — the offsets were not reset (detach step 4). Stop the connector, `DELETE /offsets`, delete it and register again. Changes made since the new cluster started are not in the pipeline unless writes were blocked; if they were not, switch to re-attach B.
- **`wal_level` is `replica` after `pg_upgrade`, slot creation fails** — the new cluster did not inherit `postgresql.conf`. Set `wal_level = logical` and the other parameters from [source-db-setup.md](source-db-setup.md), restart PostgreSQL, register again.
- **`wal_status = lost` during the re-snapshot** — retained WAL exceeded `max_slot_wal_keep_size` while the slot was inactive. Raise the limit (RDS: parameter group; self-hosted: `ALTER SYSTEM SET max_slot_wal_keep_size`) and run `recover-slot` again.
- **`MEMORY_LIMIT_EXCEEDED` in `stg_*` during `initial-dbt-build`** — several snapshots in raw. Purge the previous snapshot's rows or tune `CLICKHOUSE_MAX_THREADS` / `CLICKHOUSE_MAX_MEMORY_USAGE` (see the consequences above).

## Checklist

- [ ] watchdog stopped, DAG paused
- [ ] slot drained, connector `STOPPED`, offsets reset, connector deleted, slot dropped
- [ ] database upgraded; `wal_level = logical` and the other CDC parameters set; publication and heartbeat/signal tables present
- [ ] connector registered with `no_data` before writes resumed (or: raw tables truncated, `SKIP_DBT=1 recover-slot`, snapshot finished, `initial-dbt-build`)
- [ ] new slot `active`, a test change visible in `raw.events_*` with no new `op = 'r'`
- [ ] `make reconcile` green, watchdog started, DAG unpaused
- [ ] after re-attach B: the marts `reconcile` does not cover (`logistics_summary`, `reporting_status`, `non_reporting_facilities`) have `count()` equal to `uniqExact(<primary key>)`
- [ ] `.env` reverted, connector config back to the default snapshot mode
