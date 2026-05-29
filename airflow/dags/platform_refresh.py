"""
platform_refresh — Reporting Stack orchestration DAG.

Runs on a schedule (default: hourly). Tasks:
  1. log_cdc_health   — queries ClickHouse raw tables, emits FRESH/STALE log
                        lines per table. Always succeeds; does NOT gate
                        downstream. dbt itself decides whether there is work
                        to do via _cdc_ts watermarks on incremental models,
                        so an idle source produces cheap no-op runs.
  2. dbt_build        — runs dbt deps + build via scripts/dbt/build.sh
  3. dbt_test         — runs dbt test via scripts/dbt/test.sh

Environment variables (from .env via compose env_file):
  CLICKHOUSE_HOST              default: clickhouse
  CLICKHOUSE_PORT              default: 8123
  CLICKHOUSE_USER              default: default
  CLICKHOUSE_PASSWORD          default: changeme
  SOURCE_PG_TABLE_ALLOWLIST    required: comma-separated schema.table list
  DEBEZIUM_TOPIC_PREFIX        default: openlmis
  FRESHNESS_MAX_AGE_MINUTES    default: 60  (threshold for STALE warnings)
  AIRFLOW_REFRESH_SCHEDULE     default: @hourly
  REPORTING_HOST_ROOT          required when running dbt from Airflow container
"""

import os
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from base64 import b64encode

from airflow.sdk import DAG
from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.standard.operators.python import PythonOperator


CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
CLICKHOUSE_PORT = os.environ.get("CLICKHOUSE_PORT", "8123")
CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "default")
CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "changeme")
DEBEZIUM_TOPIC_PREFIX = os.environ.get("DEBEZIUM_TOPIC_PREFIX", "openlmis")
TABLE_ALLOWLIST = os.environ.get("SOURCE_PG_TABLE_ALLOWLIST", "")
FRESHNESS_MAX_AGE = int(os.environ.get("FRESHNESS_MAX_AGE_MINUTES", "60"))
SCHEDULE = os.environ.get("AIRFLOW_REFRESH_SCHEDULE", "@hourly")
REPORTING_ROOT = os.environ.get("REPORTING_HOST_ROOT", "/opt/reporting")


def _ch_query(sql):
    """Execute a ClickHouse query via HTTP and return the response text."""
    url = f"http://{CLICKHOUSE_HOST}:{CLICKHOUSE_PORT}/"
    creds = b64encode(f"{CLICKHOUSE_USER}:{CLICKHOUSE_PASSWORD}".encode()).decode()
    req = Request(url, data=sql.encode(), headers={"Authorization": f"Basic {creds}"})
    with urlopen(req, timeout=10) as resp:
        return resp.read().decode().strip()


def _get_topics():
    """Derive topic safe names from SOURCE_PG_TABLE_ALLOWLIST."""
    if not TABLE_ALLOWLIST:
        return []
    topics = []
    for table in TABLE_ALLOWLIST.split(","):
        table = table.strip()
        if table:
            topic = f"{DEBEZIUM_TOPIC_PREFIX}.{table}"
            safe_name = topic.replace(".", "_")
            topics.append(safe_name)
    return topics


def log_cdc_health(**kwargs):
    """
    Observability-only: log the most recent _ingested_at for every raw event
    table. Emits a FRESH / STALE line per table relative to
    FRESHNESS_MAX_AGE_MINUTES so an operator scanning the DAG log can spot a
    broken CDC pipeline. Does NOT short-circuit — dbt always runs, and an idle
    source costs only the per-mart incremental no-op.
    """
    topics = _get_topics()
    if not topics:
        print("WARNING: No topics configured; cannot assess CDC health")
        return

    threshold = datetime.now(timezone.utc) - timedelta(minutes=FRESHNESS_MAX_AGE)
    stale = []

    for safe_name in topics:
        table = f"raw.events_{safe_name}"
        result = _ch_query(
            f"SELECT max(_ingested_at) FROM {table} FORMAT TabSeparated"
        )
        if not result or result == "1970-01-01 00:00:00.000":
            print(f"STALE: {table} has no data")
            stale.append(table)
            continue

        try:
            max_ts = datetime.strptime(result, "%Y-%m-%d %H:%M:%S.%f")
            max_ts = max_ts.replace(tzinfo=timezone.utc)
        except ValueError:
            print(f"WARNING: Could not parse timestamp '{result}' from {table}")
            continue

        if max_ts < threshold:
            print(
                f"STALE: {table} last ingested at {result}, "
                f"threshold is {threshold.isoformat()}"
            )
            stale.append(table)
        else:
            print(f"FRESH: {table} last ingested at {result}")

    if stale:
        print(
            f"WARNING: {len(stale)} of {len(topics)} tables stale (>{FRESHNESS_MAX_AGE}m). "
            "dbt will still run — incremental no-op if there is nothing to do."
        )
    else:
        print("All tables are fresh")


default_args = {
    "owner": "reporting-platform",
    # Retry transient ClickHouse / Kafka Connect blips. Exponential
    # backoff (5m → 10m → 20m) gives the underlying service time to
    # recover (e.g. CDC consumer lag clearing, a ClickHouse merge
    # finishing) before each retry attempt. max_retry_delay caps the
    # backoff so a long-running incident still retries within the
    # hourly window.
    "retries": 3,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=20),
}

with DAG(
    dag_id="platform_refresh",
    default_args=default_args,
    description="CDC health log, dbt build, dbt test",
    schedule=SCHEDULE,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    is_paused_upon_creation=False,
    # max_active_runs=1 ensures a slow run doesn't get a sibling started
    # by the next hourly trigger — two concurrent dbt builds against the
    # same ClickHouse session pool deadlock on the 1.10 adapter.
    max_active_runs=1,
    # dagrun_timeout caps a single run so the next hourly trigger isn't
    # starved by a hung previous run. Tuned generously for the initial
    # build window; routine incremental runs finish in seconds.
    dagrun_timeout=timedelta(hours=3),
    tags=["reporting-platform", "dbt"],
) as dag:

    health = PythonOperator(
        task_id="log_cdc_health",
        python_callable=log_cdc_health,
    )

    build = BashOperator(
        task_id="dbt_build",
        bash_command="bash /opt/reporting/scripts/dbt/run.sh build --exclude tag:reconcile",
    )

    test = BashOperator(
        task_id="dbt_test",
        # Cross-system reconcile tests run via `make reconcile` on operator
        # demand; the hourly DAG sticks to the cheap structural tests
        # (uniqueness, not_null, accepted_values, relationships).
        bash_command="bash /opt/reporting/scripts/dbt/run.sh test --exclude tag:reconcile",
    )

    health >> build >> test
