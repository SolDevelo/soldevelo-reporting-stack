# Development Guide

This guide covers verification, debugging, and the developer workflow for contributing to the reporting-stack platform.

## Verification targets

Each target verifies a specific layer. Run them in order — each depends on the previous.

| Target | What it checks |
|---|---|
| `make verify-services` | Kafka, Kafka Connect, Apicurio, Kafka UI are healthy |
| `make verify-cdc` | Debezium connector is RUNNING, CDC topics exist |
| `make verify-ingestion` | ClickHouse databases exist, events tables have rows |

Or run all at once via `make setup` (idempotent — also re-registers the connector and re-inits ClickHouse).

### verify-services

Checks each platform service is reachable via HTTP health endpoints.

Manual checks:

```bash
# Kafka broker
docker compose --env-file .env -f compose/docker-compose.yml exec kafka \
  kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# Kafka Connect REST API
curl -s http://localhost:${CONNECT_PORT:-8083}/connectors

# Apicurio Registry
curl -s http://localhost:${APICURIO_PORT:-8085}/health

# Kafka UI
curl -s http://localhost:${KAFKA_UI_PORT:-9080}/ | head -5
```

### verify-cdc

Checks the Debezium connector is RUNNING and at least one CDC topic exists.

Connector management:

```bash
make register-connector    # create or update connector config
make connector-status      # show connector + task status
make delete-connector      # remove connector (cleanup)
```

The connector template is loaded from `${ANALYTICS_CORE_PATH}/connect/` (default: `examples/olmis-analytics-core/connect/`). Environment variables in the JSON are substituted at registration time via `envsubst`.

#### Serialization

Messages use JSON converters (not Avro) for ClickHouse compatibility. ClickHouse has documented issues with Apicurio's AvroConfluent endpoint. Apicurio remains in the stack for schema governance if other consumers need Avro.

#### Table allowlist

The default allowlist (`SOURCE_PG_TABLE_ALLOWLIST` in `.env`) captures a small set of tables. To add tables:

1. Update `SOURCE_PG_TABLE_ALLOWLIST` in `.env`
2. Add the tables to the PostgreSQL publication (see [source-db-setup.md](source-db-setup.md))
3. Re-register: `make register-connector`
4. Re-init ClickHouse: `make clickhouse-init`

### verify-ingestion

Runs `clickhouse-init` (idempotent), then checks each `raw.events_*` table for row counts.

Manual ClickHouse queries:

```bash
# Check row counts
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT name, total_rows FROM system.tables WHERE database = 'raw' AND name LIKE 'events_%' FORMAT Pretty"

# Query a specific table
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT op, count() FROM raw.events_openlmis_referencedata_programs GROUP BY op FORMAT Pretty"

# Parse JSON payload
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT JSONExtractString(after, 'name') as name FROM raw.events_openlmis_referencedata_programs LIMIT 5 FORMAT Pretty"
```

## Source database setup

See [source-db-setup.md](source-db-setup.md) for configuring the adopter's PostgreSQL database for CDC, including:
- Publication and heartbeat table setup
- WAL retention safety (`max_slot_wal_keep_size`)
- Network connectivity options
- Slot invalidation recovery

## Developer workflow

1. Make changes to platform code
2. `make build` to rebuild any modified Docker images
3. `make up` to apply compose changes
4. `make setup` to re-configure (idempotent)
5. Run the relevant `make verify-*` to verify

## Implementation plan

See [implementation-plan.md](implementation-plan.md) for the full task breakdown (Tasks 3–10).
