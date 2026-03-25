FROM python:3.12-slim

RUN pip install --no-cache-dir dbt-core==1.11.7 dbt-clickhouse==1.10.0

WORKDIR /dbt
COPY . /dbt/

ENTRYPOINT ["dbt"]
CMD ["build"]
