"""
Superset configuration for the SolDevelo Reporting Stack.

Environment-driven — all secrets come from env vars, never from Git.
"""

import os

# Secret key for session signing — MUST be set via env var in production.
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "replace-with-a-long-random-string")

# Metadata database (PostgreSQL, managed by superset-db service)
_db_password = os.environ.get("SUPERSET_DB_PASSWORD", "superset")
SQLALCHEMY_DATABASE_URI = os.environ.get(
    "SUPERSET_SQLALCHEMY_DATABASE_URI",
    f"postgresql+psycopg2://superset:{_db_password}@superset-db:5432/superset",
)

# Disable example data loading
SUPERSET_LOAD_EXAMPLES = False

# Feature flags
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
}

# CSRF and embedding
WTF_CSRF_ENABLED = True
TALISMAN_ENABLED = False

# Row limit for SQL Lab queries
ROW_LIMIT = 50000
SQL_MAX_ROW = 100000
