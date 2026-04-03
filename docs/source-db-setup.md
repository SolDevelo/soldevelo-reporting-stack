# Source Database Setup for Reporting Stack

This guide explains how to configure an adopter's PostgreSQL database as a CDC source for the reporting stack. OpenLMIS (via `openlmis-ref-distro`) is used as the reference example.

## Prerequisites

- PostgreSQL 10+ (logical replication support required)
- `wal_level = logical` in `postgresql.conf` (requires restart if changed)
- `max_replication_slots >= 2` (at least 1 for Debezium + headroom)
- `max_wal_senders >= 4`

> **Note:** The `openlmis/postgres:14-debezium` image used by `openlmis-ref-distro` ships with `wal_level = logical` and the decoder plugins pre-installed. No `postgresql.conf` changes or restarts are needed.

## Automated setup (openlmis-ref-distro)

The `reporting-stack-integration` branch of `openlmis-ref-distro` automates the entire setup. Start ref-distro with the overlay and everything is configured automatically:

```bash
docker compose -f docker-compose.yml -f docker-compose.reporting-stack.yml up -d
```

This:
1. Creates the `reporting-shared` Docker network
2. Attaches the DB with hostname `olmis-db`
3. Runs a one-shot init container that waits for Flyway migrations, then applies the CDC SQL

See `reporting-stack/README.md` in `openlmis-ref-distro` for details.

## Manual setup (other adopters)

For databases not managed by the ref-distro overlay, run the following SQL:

```sql
-- 1. Create a publication for the tables the reporting stack will capture.
--    Adjust the table list to match your deployment.
CREATE PUBLICATION dbz_publication FOR TABLE
  referencedata.facilities,
  referencedata.programs,
  referencedata.geographic_zones,
  referencedata.orderables,
  referencedata.processing_periods,
  referencedata.processing_schedules,
  referencedata.facility_types,
  referencedata.supported_programs,
  referencedata.requisition_group_members,
  referencedata.requisition_group_program_schedules,
  requisition.requisitions,
  requisition.requisition_line_items,
  requisition.status_changes;

-- 2. Create a heartbeat table to prevent WAL bloat during idle periods.
CREATE TABLE IF NOT EXISTS public.reporting_heartbeat (
  id  INT PRIMARY KEY DEFAULT 1,
  ts  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
INSERT INTO public.reporting_heartbeat (id, ts) VALUES (1, NOW())
  ON CONFLICT (id) DO NOTHING;

-- 3. Ensure the database user has replication privileges.
ALTER ROLE postgres WITH REPLICATION;
```

## Expanding the table allowlist

1. Add tables to the publication: `ALTER PUBLICATION dbz_publication ADD TABLE schema.tablename;`
2. Update `SOURCE_PG_TABLE_ALLOWLIST` in the reporting stack's `.env`.
3. Re-register the connector: `make register-connector`.

## Network connectivity

The reporting stack needs TCP access to the source PostgreSQL on port 5432.

**With openlmis-ref-distro (automated):** The `docker-compose.reporting-stack.yml` overlay creates a `reporting-shared` network and attaches the DB as `olmis-db`. The reporting stack's `kafka-connect` joins this network automatically.

**In production:** Set `SOURCE_PG_HOST` to the actual database hostname or IP. No shared Docker network is needed — the reporting stack connects directly.

**Reporting stack `.env` configuration:**

```env
SOURCE_PG_HOST=olmis-db       # or the production DB hostname
SOURCE_PG_PORT=5432
SOURCE_PG_DB=open_lmis
SOURCE_PG_USER=postgres
SOURCE_PG_PASSWORD=p@ssw0rd
```

## Cleanup

To remove the CDC configuration from the source database:

```sql
DROP PUBLICATION IF EXISTS dbz_publication;
DROP TABLE IF EXISTS public.reporting_heartbeat;
-- Drop the replication slot (only after the connector is removed)
SELECT pg_drop_replication_slot('debezium_reporting')
  FROM pg_replication_slots WHERE slot_name = 'debezium_reporting';
```

## WAL retention and disk safety

**This is a critical production concern.** When the reporting stack is down (crash, maintenance, network issue), the Debezium replication slot prevents PostgreSQL from cleaning up WAL segments. Without a limit, WAL grows until the disk fills, at which point PostgreSQL stops accepting writes — a full production outage.

### Prevention: `max_slot_wal_keep_size` (required for production)

PostgreSQL 13+ provides `max_slot_wal_keep_size` — a hard cap on WAL retained per replication slot. Once exceeded, PostgreSQL drops the oldest WAL segments and **invalidates** the slot. The database stays operational; Debezium re-snapshots on reconnect.

```sql
-- Set the limit (takes effect immediately, no restart needed)
ALTER SYSTEM SET max_slot_wal_keep_size = '2GB';
SELECT pg_reload_conf();
```

The ref-distro `init-db.sql` sets this to `2GB` by default. **Production deployments should size this based on:**

| Factor | Consideration |
|---|---|
| Write volume | High-write databases fill WAL faster; increase the limit proportionally |
| Expected downtime tolerance | How long can the reporting stack be down before you'd prefer a re-snapshot? |
| Available disk | The limit should be well below free disk space |
| Recovery time | A re-snapshot after invalidation takes time; larger datasets = longer recovery |

**Sizing guideline:** monitor `pg_wal_lsn_diff` during normal operation to understand your WAL generation rate per hour. Set `max_slot_wal_keep_size` to cover your maximum acceptable downtime window (e.g., if you generate 500MB/hour and want 8 hours of tolerance, set to `4GB`).

### What the heartbeat table does (and doesn't do)

The `reporting_heartbeat` table prevents WAL bloat during **idle periods** — when no writes happen to captured tables, the replication slot doesn't advance, and WAL accumulates even though there's nothing new. Debezium's heartbeat writes periodically advance the slot.

The heartbeat **does NOT help** when the reporting stack is down. If the consumer isn't running, heartbeat writes don't happen, and `max_slot_wal_keep_size` is the only protection.

### Monitoring recommendations

```sql
-- Check replication slot lag (run periodically)
SELECT
  slot_name,
  active,
  pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS lag_size,
  wal_status  -- 'reserved', 'extended', 'unreserved', or 'lost' (invalidated)
FROM pg_replication_slots;
```

Alert when:
- `active = false` for more than a few minutes (consumer is down)
- `lag_size` exceeds 50% of `max_slot_wal_keep_size` (approaching limit)
- `wal_status = 'lost'` (slot was invalidated — Debezium needs a re-snapshot)

### Recovery after slot invalidation

If `max_slot_wal_keep_size` is exceeded and the slot is invalidated:

1. Delete the connector: `make delete-connector`
2. Drop the orphaned slot: `SELECT pg_drop_replication_slot('debezium_reporting');`
3. Re-register the connector: `make register-connector`
4. Debezium will perform a new initial snapshot, then resume streaming

## Other operational notes

- **Publication changes**: After adding/removing tables from the publication, also update the Debezium connector's `table.include.list` and re-register it.
- **Debezium plugin**: The connector uses `pgoutput` (built into PostgreSQL 10+). No additional server-side plugins are needed.
- **Slot cleanup on decommission**: If the reporting stack is permanently removed, drop the replication slot manually. Orphaned slots retain WAL indefinitely (up to `max_slot_wal_keep_size`).
