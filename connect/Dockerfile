FROM confluentinc/cp-kafka-connect:7.7.1

# ---------------------------------------------------------------------------
# Debezium PostgreSQL connector
# Downloaded directly from Maven Central (confluent-hub may not carry all versions).
# ---------------------------------------------------------------------------
ARG DEBEZIUM_VERSION=2.7.4.Final
RUN mkdir -p /usr/share/java/debezium-connector-postgresql && \
    cd /usr/share/java/debezium-connector-postgresql && \
    curl -sL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      | tar xz --strip-components=1
