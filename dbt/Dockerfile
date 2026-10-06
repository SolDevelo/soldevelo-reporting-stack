# bookworm (Debian 12, LTS until June 2028). bullseye (Debian 11) reached end of
# life in August 2026 and its security archive left the mirrors, so apt-get in
# this image no longer works there. bookworm's glibc (2.36) uses clone3, which an
# outdated host seccomp profile rejects (EPERM, e.g. Docker 19.03): the image does
# not build there (apt-get fails) and docker build cannot take --security-opt on
# Linux, so such hosts need a Docker engine upgrade. Modern engines (verified on
# 20.10.21) build and run it unchanged.
FROM python:3.12-slim-bookworm

# git is required for dbt's Git package loading mode
RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
# --progress-bar off: pip's rich progress bar starts a background thread
# (clone3), which an old host seccomp profile rejects at build time. Disabling
# it keeps pip single-threaded; harmless on modern hosts.
RUN pip install --no-cache-dir --progress-bar off dbt-core==1.11.9 dbt-clickhouse==1.10.0

WORKDIR /dbt
COPY . /dbt/

ENTRYPOINT ["dbt"]
CMD ["build"]
