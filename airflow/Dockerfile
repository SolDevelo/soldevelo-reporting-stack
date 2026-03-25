FROM apache/airflow:2.9.3-python3.12

# Install Docker CLI so BashOperator can invoke dbt via docker run
USER root
COPY --from=docker:26-cli /usr/local/bin/docker /usr/local/bin/docker
USER airflow
