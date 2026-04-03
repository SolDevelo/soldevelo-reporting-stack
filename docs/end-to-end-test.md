# End-to-End Test: OLMIS change → Superset dashboard

This guide walks through making a change in the OLMIS system and verifying it appears in the Superset dashboard, proving the full pipeline works.

## Prerequisites

- openlmis-ref-distro running with the reporting-stack overlay
- Reporting stack running (`make up && make setup` completed)
- Both stacks on the `reporting-shared` Docker network
- `settings.env` in ref-distro configured with your host IP as `BASE_URL`, `VIRTUAL_HOST`, and `PUBLIC_URL`

## Step 1: Open Superset and note the "before" state

1. Open **http://localhost:8088**
2. Login: `admin` / `changeme`
3. Go to **Dashboards** → **OLMIS Requisition Overview**
4. Look at the **Requisitions by Facility** table — note the facility names (e.g., "Comfort Health Clinic")

## Step 2: Rename a facility in OLMIS

We rename a facility that has requisitions, so the change is visible in the dashboard table chart. "Comfort Health Clinic" (code `HC01`) has 4 requisitions in the demo data.

### Option A — Via the OLMIS UI

1. Open the OLMIS UI (default: `http://<your-host-ip>`)
2. Login: `administrator` / `password`
3. Go to **Administration** → **Facilities**
4. Find and click on **Comfort Health Clinic** (code `HC01`)
5. Change the name to **Comfort Health Clinic (E2E TEST)**
6. Click **Save**

### Option B — Via the OLMIS API

```bash
# Get auth token (replace IP with your OLMIS host)
OLMIS_HOST=http://192.168.68.59
TOKEN=$(curl -sf -X POST \
  "$OLMIS_HOST/api/oauth/token?grant_type=password&username=administrator&password=password" \
  -H "Authorization: Basic dXNlci1jbGllbnQ6Y2hhbmdlbWU=" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Find the facility UUID
HC01_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$OLMIS_HOST/api/facilities?code=HC01" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['content'][0]['id'])")

# Fetch, rename, update
FACILITY=$(curl -sf -H "Authorization: Bearer $TOKEN" "$OLMIS_HOST/api/facilities/$HC01_ID")
UPDATED=$(echo "$FACILITY" | python3 -c "
import sys,json
f = json.load(sys.stdin)
f['name'] = 'Comfort Health Clinic (E2E TEST)'
print(json.dumps(f))")

curl -sf -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$UPDATED" \
  "$OLMIS_HOST/api/facilities/$HC01_ID" \
  | python3 -c "import sys,json; print(f'Renamed to: {json.load(sys.stdin)[\"name\"]}')"
```

## Step 3: Verify CDC captured the change

CDC is real-time. Within a few seconds, the change appears in ClickHouse raw landing:

```bash
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT op, JSONExtractString(after, 'name') as name \
  FROM raw.events_openlmis_referencedata_facilities \
  WHERE JSONExtractString(after, 'code') = 'HC01' \
  ORDER BY ts_ms DESC LIMIT 3 FORMAT Pretty"
```

You should see `op = 'u'` (update) with the new name, above the original `op = 'r'` (snapshot) row.

## Step 4: Rebuild curated marts

```bash
make dbt-build
```

This takes ~30 seconds. dbt reconstructs current-state views from CDC events and rebuilds the mart tables.

> **Note:** In production, this happens automatically — Airflow runs `dbt build` on a schedule (default: hourly). You can also trigger it from the Airflow UI at `http://localhost:8080`.

## Step 5: Verify the mart reflects the change

```bash
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT facility_name, program_name, status \
  FROM curated.mart_requisition_summary \
  WHERE facility_code = 'HC01' FORMAT Pretty"
```

All requisitions for HC01 should now show "Comfort Health Clinic (E2E TEST)".

## Step 6: See the change in Superset

1. Go back to **http://localhost:8088** → **OLMIS Requisition Overview**
2. Click the **refresh icon** (circular arrow) in the top-right, or use the chart's **...** menu → **Force refresh**
3. The **Requisitions by Facility** table now shows **"Comfort Health Clinic (E2E TEST)"** instead of "Comfort Health Clinic"

## Step 7: Revert the change (optional)

Rename the facility back to "Comfort Health Clinic" via the UI or API:

```bash
FACILITY=$(curl -sf -H "Authorization: Bearer $TOKEN" "$OLMIS_HOST/api/facilities/$HC01_ID")
UPDATED=$(echo "$FACILITY" | python3 -c "
import sys,json
f = json.load(sys.stdin)
f['name'] = 'Comfort Health Clinic'
print(json.dumps(f))")

curl -sf -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$UPDATED" \
  "$OLMIS_HOST/api/facilities/$HC01_ID" \
  | python3 -c "import sys,json; print(f'Reverted to: {json.load(sys.stdin)[\"name\"]}')"
```

Then run `make dbt-build` and refresh Superset to confirm the revert.

## What this proves

```
PostgreSQL (OLMIS facility rename)
  → Debezium CDC (real-time capture, seconds)
    → Kafka (transport)
      → ClickHouse raw landing (append-only: snapshot + update events)
        → dbt (current-state reconstruction picks latest name)
          → ClickHouse curated mart (all requisitions show new name)
            → Superset dashboard table chart (visible change)
```

## Troubleshooting

**CDC not capturing changes**: check that the publication includes the table:
```bash
docker compose exec -T db psql -U postgres -d open_lmis \
  -c "SELECT * FROM pg_publication_tables WHERE pubname = 'dbz_publication';"
```
If empty, the tables were lost (e.g., DB container was recreated). Re-add them:
```bash
docker compose exec -T db psql -U postgres -d open_lmis \
  -c "ALTER PUBLICATION dbz_publication ADD TABLE referencedata.facilities, referencedata.programs, referencedata.geographic_zones, referencedata.orderables, referencedata.processing_periods, referencedata.processing_schedules, referencedata.facility_types, referencedata.supported_programs, referencedata.requisition_group_members, referencedata.requisition_group_program_schedules, requisition.requisitions, requisition.requisition_line_items, requisition.status_changes;"
```
Then restart the connector task: `curl -X POST http://localhost:8083/connectors/openlmis-postgres-cdc/tasks/0/restart`

**OLMIS API returns 500**: check that all services are using the current `BASE_URL` in `settings.env`. If the IP changed or services were restarted individually, recreate all services and restart nginx.

**Superset chart shows stale data**: use **Force refresh** (not regular refresh) from the chart's `...` menu. Superset caches query results.
