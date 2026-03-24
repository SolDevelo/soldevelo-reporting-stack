-- =============================================================================
-- Create the two core databases for the reporting stack.
-- raw:     append-only CDC event landing (immutable event log)
-- curated: dbt-managed reporting marts (BI contract)
-- =============================================================================

CREATE DATABASE IF NOT EXISTS raw;
CREATE DATABASE IF NOT EXISTS curated;
