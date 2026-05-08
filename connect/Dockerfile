# ---------------------------------------------------------------------------
# Debezium PostgreSQL connector
# Downloaded directly from Maven Central (confluent-hub may not carry all versions).
# Extracted in a separate stage because cp-kafka-connect 8.x does not include tar.
# ---------------------------------------------------------------------------
FROM alpine:3 AS debezium-plugin
ARG DEBEZIUM_VERSION=3.5.0.Final
RUN apk add --no-cache curl tar gzip && \
    mkdir -p /opt/debezium-connector-postgresql && \
    cd /opt/debezium-connector-postgresql && \
    curl -sL "https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/${DEBEZIUM_VERSION}/debezium-connector-postgres-${DEBEZIUM_VERSION}-plugin.tar.gz" \
      | tar xz --strip-components=1

FROM confluentinc/cp-kafka-connect:8.2.0
COPY --from=debezium-plugin /opt/debezium-connector-postgresql /usr/share/java/debezium-connector-postgresql
