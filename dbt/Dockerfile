FROM python:3.12-slim

# git is required for dbt's Git package loading mode
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir dbt-core==1.11.7 dbt-clickhouse==1.10.0

WORKDIR /dbt
COPY . /dbt/

ENTRYPOINT ["dbt"]
CMD ["build"]
