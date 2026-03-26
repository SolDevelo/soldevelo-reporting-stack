FROM apache/superset:6.0.0

# Install ClickHouse driver and PostgreSQL adapter for the metadata DB.
# Superset 6.0.0 uses a venv at /app/.venv built with uv.
USER root
RUN uv pip install --python /app/.venv/bin/python clickhouse-connect psycopg2-binary
USER superset

# Platform configuration
COPY superset_config.py /app/superset_config.py
ENV SUPERSET_CONFIG_PATH=/app/superset_config.py
