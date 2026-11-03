# Runbook: Source database major upgrade (PostgreSQL)

A major version upgrade of the source PostgreSQL (for example 14 → 17, in place with `pg_upgrade`, as an
RDS in-place upgrade, through an RDS Blue/Green deployment, or by dump/restore) always loses the Debezium
replication slot: PostgreSQL only migrates logical slots when the *old* cluster is already 17 or newer, RDS
refuses to upgrade while a logical slot exists, and a Blue/Green deployment refuses to be created when the
blue instance has one ("external replication on the blue primary instance"). The publication and the
`reporting_heartbeat` / `debezium_signal` tables survive every path except dump/restore.

This runbook keeps the pipeline consistent across the upgrade: no lost changes, no duplicates in the marts,
and — if application writes are blocked for the duration — no re-snapshot. It was tested on a copy of the
Malawi database (17 captured tables, 30 M `requisition_line_items`) against RDS and Docker sources
(OLMIS-8422, November 2026).

## Two ways to re-attach

| | A. No re-snapshot (`snapshot.mode=no_data`) | B. Full re-snapshot (`make recover-slot`) |
|---|---|---|
| Precondition | application writes blocked from the slot drain until the new slot exists | none |
| Captures changes made between drop and re-register | not applicable (there are none) | yes, as a fresh snapshot of the current state |
| Time after the database is back | ~20 s | 30–60 min for the Malawi tables, then `initial-dbt-build` |
| Raw tables | unchanged | one more full copy (`op = 'r'`) per table |
| When to use | planned upgrade window, writes stopped anyway | writes could not be blocked, or something went wrong |

Both start with the same detach steps.

## Detach (before the upgrade)

Do this after the application has been stopped (or put in a state where nothing writes to the captured
tables) and before the database goes down.

1. Stop the watchdog. It re-registers a missing connector within a minute, and the re-registered connector
   will start a full snapshot the moment the database comes back — before you had a chance to choose.

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml stop connect-watchdog
   ```

2. Pause the refresh DAG so dbt does not run against a half-replicated state:

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml exec airflow-scheduler airflow dags pause platform_refresh
   ```

3. Let the connector drain the slot. On the source:

   ```sql
   select active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
     from pg_replication_slots where slot_name = 'debezium_reporting';
   ```

   Wait until `lag` is a few hundred bytes (the heartbeat keeps writing, it never reaches exactly zero).

4. Stop the connector, **reset its offsets**, delete it:

   ```bash
   C=http://localhost:8083/connectors/openlmis-postgres-cdc
   curl -s -X PUT    $C/stop
   curl -s -X DELETE $C/offsets        # "The Connect framework-managed offsets ... have been reset"
   curl -s -X DELETE $C
   ```

   Resetting the offsets is not optional. With the old offsets left in Kafka Connect, the re-registered
   task fails immediately (`Last recorded offset is no longer available on the server`), creates no slot,
   and every change made after the upgrade is silently missing from the pipeline until someone notices.
   `make delete-connector` alone does **not** reset the offsets.

5. Drop the slot on the source (RDS: required before the upgrade; Docker: it would be lost anyway):

   ```sql
   select pg_drop_replication_slot('debezium_reporting');
   ```

Now upgrade the database (see the `openlmis/postgres` README for the upgrade itself).

## Re-attach A — no re-snapshot

Right after the database is back on the new version, **before application writes resume**:

1. Confirm the CDC objects are still there; after a dump/restore re-apply the source init SQL
   (`reporting-stack/init-db.sql` in ref-distro or its deployment-specific copy):

   ```sql
   select count(*) from pg_publication_tables where pubname = 'dbz_publication';   -- expected: your allowlist + signal table
   select table_name from information_schema.tables
    where table_schema = 'public' and table_name in ('reporting_heartbeat', 'debezium_signal');
   ```

2. Register the connector with `no_data`, so that the new slot is created now and nothing is snapshotted:

   ```bash
   DEBEZIUM_SNAPSHOT_MODE=no_data make register-connector
   ```

   (`.env` values override the environment inside `register-connector.sh`; if `.env` sets
   `DEBEZIUM_SNAPSHOT_MODE`, change it there for this step and revert afterwards.)
   The log shows `According to the connector configuration no snapshot will be executed` and the slot is
   `active` within seconds.

3. Resume application writes, start the watchdog, unpause the DAG, and verify:

   ```bash
   docker compose --env-file .env -f compose/docker-compose.yml start connect-watchdog
   docker compose --env-file .env -f compose/docker-compose.yml exec airflow-scheduler airflow dags unpause platform_refresh
   make verify-cdc && make reconcile
   ```

   A change made now on the source must appear in the matching `raw.events_*` table within seconds, with
   `op = 'u'`/`'c'` and **no** new `op = 'r'` rows.

## Re-attach B — full re-snapshot

Use when writes happened between the slot drain and the new slot, or whenever you are not sure:

```bash
FORCE=1 make recover-slot        # drop slot, reset offsets, re-register, snapshot every captured table
make initial-dbt-build           # incremental marts need --full-refresh after a re-snapshot
make reconcile
```

Then start the watchdog and unpause the DAG as above. The snapshot runs in the background after
`recover-slot` returns; judge its end per table (row counts in ClickHouse versus the source), not by the
connector state, which is `RUNNING` from the first second.

Consequences of every re-snapshot:

- The raw tables are append-only, so each snapshot adds a full copy of every captured table. After three
  snapshots of the Malawi data `raw.events_openlmis_requisition_requisition_line_items` held 92 M rows and
  `stg_requisition_line_items` exceeded the 20 GiB per-query memory limit in ClickHouse. Either purge the
  previous snapshot's rows (`ALTER TABLE raw.events_... DELETE WHERE op = 'r' AND _ingested_at < <start of
  the latest snapshot>`), or lower `CLICKHOUSE_MAX_THREADS` / raise `CLICKHOUSE_MAX_MEMORY_USAGE` in
  `.env` for the rebuild.
- While the snapshot runs the slot is inactive and WAL accumulates on the source; with
  `max_slot_wal_keep_size = 2GB` a long snapshot plus a Kafka hiccup invalidated the slot in the test
  (`wal_status = lost`). Raise the limit for the duration of the snapshot on large databases.

## RDS Blue/Green specifics

- The slot must be gone before `create-blue-green-deployment`; the publication may stay.
- Do not re-attach to the green instance; wait for the switchover (the endpoint name does not change) and
  re-attach to it as in A or B.
- Any large-object write on blue during the deployment degrades the replication and the deployment has to
  be recreated — the OpenLMIS services that write large objects (hapifhir, dhis2-integration) must stay
  down for the whole deployment, not only during the switchover.

## Checklist

- [ ] watchdog stopped, DAG paused
- [ ] slot drained, connector stopped, offsets reset, connector deleted, slot dropped
- [ ] database upgraded, publication and heartbeat/signal tables present
- [ ] connector registered with `no_data` before writes resumed (or `recover-slot` + `initial-dbt-build`)
- [ ] new slot `active`, a test change visible in `raw.events_*` with no new `op = 'r'`
- [ ] `make reconcile` green, watchdog started, DAG unpaused
