# bullseye (Debian 11, glibc 2.31) predates clone3, so apt/pip/dbt all use the
# old clone syscall and run under an outdated host seccomp profile. The default
# slim tag now tracks Debian trixie (glibc 2.41), whose clone3 calls are
# rejected (EPERM) by old profiles, breaking both the build and dbt at runtime.
# Safe on modern hosts too; revisit when the dev host's Docker/OS is upgraded.
FROM python:3.12-slim-bullseye

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
