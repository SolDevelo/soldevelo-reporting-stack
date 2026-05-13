"""
backfill — manual-trigger DAG for targeted PG→ClickHouse re-export.

Wraps the host-side bootstrap export/import pipeline so operators can run a
backfill from the Airflow UI instead of shelling into the host. Suitable for:

  - re-snapshotting a single table after a dbt model fix
  - re-snapshotting a set of tables after a data correction at the source
  - any case where you want fresh row state in ClickHouse raw without going
    through Debezium's incremental snapshot path

Triggering parameters (set when you run the DAG):

  tables   comma-separated schema.table list (required). Each entry must be
           one of the tables in SOURCE_PG_TABLE_ALLOWLIST (and present in the
           publication). Example: 'requisition.stock_adjustments,requisition.stock_adjustment_reasons'.

  run_dbt  bool (default true). If true, runs scripts/dbt/run.sh build after
           the import so curated marts pick up the refreshed rows. Set false
           if you want to inspect raw rows before rebuilding marts.

Tasks (sequential):
  1. export_tables       — scripts/bootstrap/export.sh writes NDJSON + manifest
                           under .bootstrap/export-<ts>/ and updates the
                           .bootstrap/latest symlink.
  2. import_to_clickhouse — scripts/bootstrap/import.sh reads .bootstrap/latest
                           and inserts synthetic op='r' events into raw.events_*.
  3. dbt_build           — scripts/dbt/run.sh build. Gated by run_dbt param.
  4. reconcile           — scripts/dbt/run.sh test --select tag:reconcile.
                           Cross-system row count + PK checksum comparison.
                           Runs only when dbt_build succeeded (skipped if
                           run_dbt=false). Hard-fails the DAG run on any
                           divergence — re-trigger or run `make reconcile`
                           manually after CDC catches up.

Notes on running from Airflow:
  - The airflow-scheduler container has the host docker socket bind-mounted,
    so export.sh's `docker run postgres:17-alpine` works through the host
    daemon. The one-shot container joins the reporting-shared network to
    reach the source DB the same way it would from a host invocation.
  - import.sh detects /.dockerenv and connects to ClickHouse via the
    compose-network hostname (CLICKHOUSE_HOST, default 'clickhouse')
    instead of localhost.
  - The .bootstrap/ directory lives under /opt/reporting (the host repo
    mounted into the scheduler), so artifacts are visible from the host.
"""

from datetime import datetime, timedelta

from airflow.sdk import DAG, Param
from airflow.providers.standard.operators.bash import BashOperator
from airflow.providers.standard.operators.python import ShortCircuitOperator


default_args = {
    "owner": "reporting-platform",
    "retries": 0,
    "retry_delay": timedelta(minutes=5),
}


def _gate_dbt(**context):
    """Short-circuit the dbt_build task when run_dbt=false."""
    run_dbt = context["params"].get("run_dbt", True)
    # CLI --conf delivers Python booleans, but the UI trigger form may
    # serialise the value to a string before it reaches the renderer. A naïve
    # `if not run_dbt` would treat "False" (a non-empty string) as truthy and
    # run dbt anyway — defeating the operator's explicit choice.
    if isinstance(run_dbt, str):
        run_dbt = run_dbt.strip().lower() not in ("false", "0", "no", "")
    if not run_dbt:
        print("run_dbt=false — skipping dbt_build")
        return False
    print("run_dbt=true — proceeding with dbt_build")
    return True


with DAG(
    dag_id="backfill",
    default_args=default_args,
    description="Manual backfill: export PG → import ClickHouse → optional dbt rebuild",
    schedule=None,  # manual trigger only
    start_date=datetime(2024, 1, 1),
    catchup=False,
    is_paused_upon_creation=False,
    max_active_runs=1,
    tags=["reporting-platform", "backfill"],
    params={
        "tables": Param(
            "",
            type="string",
            title="Tables",
            description=(
                "Comma-separated schema.table list (required). "
                "Example: requisition.stock_adjustments,requisition.stock_adjustment_reasons"
            ),
        ),
        "run_dbt": Param(
            True,
            type="boolean",
            title="Run dbt build after import",
            description="Uncheck to skip dbt build (useful for inspecting raw rows first).",
        ),
    },
    render_template_as_native_obj=True,
) as dag:

    # The export script reads TABLES from env. Pass it through bash_command's
    # env so Jinja templating doesn't accidentally interpret embedded characters.
    export_tables = BashOperator(
        task_id="export_tables",
        bash_command="""
set -e
if [ -z "$TABLES" ]; then
  echo "ERROR: tables param is empty — set it when triggering the DAG" >&2
  exit 2
fi
bash /opt/reporting/scripts/bootstrap/export.sh
""",
        env={"TABLES": "{{ params.tables }}"},
        append_env=True,
    )

    import_to_clickhouse = BashOperator(
        task_id="import_to_clickhouse",
        # No TABLES env here — import defaults to .bootstrap/latest which is
        # what export_tables just produced. If the operator later wants to
        # import only a subset of the manifest, they can re-run the DAG with
        # a smaller `tables` param (re-exports the subset).
        # Trailing space defeats Jinja's "command ends in .sh → look up as a
        # template file" heuristic. `template_ext` is a class attribute on
        # BashOperator in Airflow 3.x, not an __init__ kwarg, so it can't be
        # overridden per-instance without subclassing — the space is the
        # least-intrusive workaround.
        bash_command="bash /opt/reporting/scripts/bootstrap/import.sh ",
    )

    gate_dbt = ShortCircuitOperator(
        task_id="gate_dbt",
        python_callable=_gate_dbt,
        ignore_downstream_trigger_rules=True,
    )

    dbt_build = BashOperator(
        task_id="dbt_build",
        bash_command="bash /opt/reporting/scripts/dbt/run.sh build",
    )

    # Reconciliation runs only when the preceding dbt_build succeeded. We do
    # NOT soft-fail: if source/target diverge, the Airflow run is marked
    # failed and the operator sees it without having to read every task log.
    # In the common case where divergence is transient (CDC still catching
    # up), the operator re-triggers `make reconcile` from the host a minute
    # later, and the next run is clean. False-green runs were the alternative
    # and they cost more than the noise of an honest failure.
    reconcile = BashOperator(
        task_id="reconcile",
        bash_command="bash /opt/reporting/scripts/dbt/run.sh test --select tag:reconcile",
    )

    export_tables >> import_to_clickhouse >> gate_dbt >> dbt_build >> reconcile
