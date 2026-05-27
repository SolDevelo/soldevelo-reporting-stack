FROM apache/superset:6.1.0rc3-py312

# Install ClickHouse driver and PostgreSQL adapter for the metadata DB.
# Superset uses a venv at /app/.venv built with uv.
# Pinned to 6.1.0rc3 (pre-release) because 6.0.0 stable has a native-filter
# bug — Apply button stays disabled and selections don't propagate to charts
# (issue apache/superset#34617). The fix (PR #38479) landed in master after
# 6.0.1, and 6.1.0rc3 contains it. Move back to a stable pin when 6.1.0
# stable ships — see docs/operations.md.
USER root
# Install via pip rather than uv. uv is a Rust binary whose Tokio runtime spawns
# threads with the clone3 syscall; on hosts with an old Docker/libseccomp the
# default seccomp profile rejects clone3 (EPERM, not ENOSYS) and uv panics at
# build time. pip is single-threaded for wheel installs and avoids clone3, so
# the image builds on both old and modern engines. ensurepip bootstraps pip into
# the uv-created venv (which ships without it).
# --progress-bar off: pip's rich progress bar starts a background refresh
# thread (clone3), which the old-host seccomp profile rejects at build time
# ("can't start new thread"). Disabling it keeps pip single-threaded.
RUN /app/.venv/bin/python -m ensurepip --upgrade && \
    /app/.venv/bin/python -m pip install --no-cache-dir --progress-bar off clickhouse-connect==0.15.1 psycopg2-binary==2.9.12
USER superset

# Platform configuration
COPY superset_config.py /app/superset_config.py
COPY init-guest-permissions.py /app/init-guest-permissions.py
ENV SUPERSET_CONFIG_PATH=/app/superset_config.py

# Superset Embedded SDK — served at /static/superset-embedded-sdk.js
# Adopter UIs load this at runtime to embed dashboards via guest tokens.
COPY superset-embedded-sdk.js /app/superset/static/superset-embedded-sdk.js
