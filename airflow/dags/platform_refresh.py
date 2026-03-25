"""
platform_refresh — Reporting Stack orchestration DAG.

Runs on a schedule (default: hourly). Tasks:
  1. check_freshness  — queries ClickHouse raw tables, skips if data is stale
  2. dbt_build        — runs dbt deps + build via scripts/dbt/build.sh
  3. dbt_test         — runs dbt test via scripts/dbt/test.sh

Environment variables (from .env via compose env_file):
  CLICKHOUSE_HOST              default: clickhouse
  CLICKHOUSE_PORT              default: 8123
  CLICKHOUSE_USER              default: default
  CLICKHOUSE_PASSWORD          default: changeme
  SOURCE_PG_TABLE_ALLOWLIST    required: comma-separated schema.table list
  DEBEZIUM_TOPIC_PREFIX        default: openlmis
  FRESHNESS_MAX_AGE_MINUTES    default: 60
  AIRFLOW_REFRESH_SCHEDULE     default: @hourly
  REPORTING_HOST_ROOT          required when running dbt from Airflow container
"""

import os
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen
from base64 import b64encode

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import ShortCircuitOperator


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


def check_freshness(**kwargs):
    """
    Check that all raw event tables have recent data.
    Returns True if fresh (proceed with dbt), False if stale (skip).
    """
    topics = _get_topics()
    if not topics:
        print("WARNING: No topics configured, skipping freshness check")
        return True

    threshold = datetime.now(timezone.utc) - timedelta(minutes=FRESHNESS_MAX_AGE)

    for safe_name in topics:
        table = f"raw.events_{safe_name}"
        result = _ch_query(
            f"SELECT max(_ingested_at) FROM {table} FORMAT TabSeparated"
        )
        if not result or result == "1970-01-01 00:00:00.000":
            print(f"STALE: {table} has no data")
            return False

        # Parse ClickHouse DateTime64 format
        try:
            max_ts = datetime.strptime(result, "%Y-%m-%d %H:%M:%S.%f")
            max_ts = max_ts.replace(tzinfo=timezone.utc)
        except ValueError:
            print(f"WARNING: Could not parse timestamp '{result}' from {table}")
            return True  # don't block on parse errors

        if max_ts < threshold:
            print(
                f"STALE: {table} last ingested at {result}, "
                f"threshold is {threshold.isoformat()}"
            )
            return False

        print(f"FRESH: {table} last ingested at {result}")

    print("All tables are fresh")
    return True


default_args = {
    "owner": "reporting-platform",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
}

with DAG(
    dag_id="platform_refresh",
    default_args=default_args,
    description="Freshness check, dbt build, dbt test",
    schedule=SCHEDULE,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    max_active_runs=1,
    tags=["reporting-platform", "dbt"],
) as dag:

    freshness = ShortCircuitOperator(
        task_id="check_freshness",
        python_callable=check_freshness,
        ignore_downstream_trigger_rules=True,
    )

    build = BashOperator(
        task_id="dbt_build",
        bash_command="bash /opt/reporting/scripts/dbt/run.sh build",
    )

    test = BashOperator(
        task_id="dbt_test",
        bash_command="bash /opt/reporting/scripts/dbt/run.sh test",
    )

    freshness >> build >> test
