FROM apache/airflow:3.2.1-python3.12

# Install Docker CLI so BashOperator can invoke dbt via docker run
USER root
COPY --from=docker:29.4.1-cli /usr/local/bin/docker /usr/local/bin/docker
USER airflow

# Pin the standard provider (BashOperator / ShortCircuitOperator live here in 3.x)
RUN pip install --no-cache-dir apache-airflow-providers-standard==1.12.3
