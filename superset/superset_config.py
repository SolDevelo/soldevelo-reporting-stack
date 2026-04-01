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
    "EMBEDDED_SUPERSET": True,
}

# --- Embedding configuration ---
# Allows adopter applications to embed Superset dashboards in iframes.
# Set SUPERSET_EMBEDDING_ORIGINS in .env to a comma-separated list of allowed origins.
# Example: SUPERSET_EMBEDDING_ORIGINS=http://192.168.68.59,https://olmis.example.org

_embedding_origins_str = os.environ.get("SUPERSET_EMBEDDING_ORIGINS", "")
_embedding_origins = [o.strip() for o in _embedding_origins_str.split(",") if o.strip()]

# CORS — allow the embedding application to call Superset APIs (guest token, etc.)
if _embedding_origins:
    ENABLE_CORS = True
    CORS_OPTIONS = {
        "supports_credentials": True,
        "allow_headers": ["*"],
        "resources": ["/api/*", "/static/*"],
        "origins": _embedding_origins,
    }

# Guest token authentication for embedded dashboards.
# Lets users view dashboards without Superset accounts.
GUEST_ROLE_NAME = "Public"
GUEST_TOKEN_JWT_SECRET = os.environ.get(
    "SUPERSET_GUEST_TOKEN_SECRET", SECRET_KEY
)
GUEST_TOKEN_JWT_EXP_SECONDS = 300

# Allow embedded dashboard charts to send modified query payloads.
# The default Superset check rejects guest token requests where the chart query
# differs from the stored query_context (e.g. sorting, pagination, filter state).
# This is overly strict for embedded dashboards. Guest tokens are already scoped
# to a specific dashboard, so payload modification within that scope is safe.
def _allow_guest_payload_modification():
    """Patch query_context_modified to skip the check for guest users only."""
    try:
        import superset.security.manager as mgr
        _original = mgr.query_context_modified

        def _patched(query_context):
            from flask_login import current_user
            if hasattr(current_user, 'is_guest_user') and current_user.is_guest_user:
                return False
            return _original(query_context)

        mgr.query_context_modified = _patched
    except Exception:
        pass

_allow_guest_payload_modification()

# Talisman CSP — controls iframe embedding via frame-ancestors.
# Disabled when no embedding origins are set (dev default).
if _embedding_origins:
    TALISMAN_ENABLED = True
    TALISMAN_CONFIG = {
        "content_security_policy": {
            "default-src": ["'self'"],
            "img-src": ["'self'", "blob:", "data:"],
            "worker-src": ["'self'", "blob:"],
            "connect-src": ["'self'"],
            "object-src": "'none'",
            "style-src": ["'self'", "'unsafe-inline'"],
            "script-src": ["'self'", "'unsafe-inline'"],
            "frame-ancestors": ["'self'"] + _embedding_origins,
        },
        "force_https": False,
        "session_cookie_secure": False,
    }
else:
    TALISMAN_ENABLED = False

# CSRF
WTF_CSRF_ENABLED = True

# Row limit for SQL Lab queries
ROW_LIMIT = 50000
SQL_MAX_ROW = 100000
