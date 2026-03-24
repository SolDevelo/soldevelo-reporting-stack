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

# ---------------------------------------------------------------------------
# Apicurio Registry converter (Avro serialization)
#
# The 2.6.x converter JARs are compatible with Apicurio Registry 3.x
# (the registry exposes /apis/registry/v2 for backward compatibility).
# ---------------------------------------------------------------------------
ARG APICURIO_CONVERTER_VERSION=2.6.4.Final
RUN mkdir -p /usr/share/java/apicurio-registry-converter && \
    cd /usr/share/java/apicurio-registry-converter && \
    curl -sL "https://repo1.maven.org/maven2/io/apicurio/apicurio-registry-distro-connect-converter/${APICURIO_CONVERTER_VERSION}/apicurio-registry-distro-connect-converter-${APICURIO_CONVERTER_VERSION}.tar.gz" \
      | tar xz
