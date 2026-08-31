FROM apache/superset:6.1.0rc3-py312

# Install ClickHouse driver and PostgreSQL adapter for the metadata DB.
# Superset uses a venv at /app/.venv built with uv.
# Pinned to 6.1.0rc3 (pre-release) because 6.0.0 stable has a native-filter
# bug — Apply button stays disabled and selections don't propagate to charts
# (issue apache/superset#34617). The fix (PR #38479) landed in master after
# 6.0.1, and 6.1.0rc3 contains it. Move back to a stable pin when 6.1.0
# stable ships — see docs/operations.md.
USER root
# Install via pip rather than uv. uv is a Rust binary whose Tokio runtime spawns
# threads with the clone3 syscall; on hosts with an old Docker/libseccomp the
# default seccomp profile rejects clone3 (EPERM, not ENOSYS) and uv panics at
# build time. pip is single-threaded for wheel installs and avoids clone3, so
# the image builds on both old and modern engines. ensurepip bootstraps pip into
# the uv-created venv (which ships without it).
# --progress-bar off: pip's rich progress bar starts a background refresh
# thread (clone3), which the old-host seccomp profile rejects at build time
# ("can't start new thread"). Disabling it keeps pip single-threaded.
RUN /app/.venv/bin/python -m ensurepip --upgrade && \
    /app/.venv/bin/python -m pip install --no-cache-dir --progress-bar off clickhouse-connect==0.15.1 psycopg2-binary==2.9.12
USER superset

# Platform configuration
COPY superset_config.py /app/superset_config.py
COPY init-guest-permissions.py /app/init-guest-permissions.py
ENV SUPERSET_CONFIG_PATH=/app/superset_config.py

# Superset Embedded SDK — served at /static/superset-embedded-sdk.js
# Adopter UIs load this at runtime to embed dashboards via guest tokens.
COPY superset-embedded-sdk.js /app/superset/static/superset-embedded-sdk.js

# MW-1482: patch the bundled Malawi districts GeoJSON for the Country Map viz.
# The upstream bundled Malawi map (legacy-plugin-chart-country-map) is MISSING
# Karonga (MW-KR) and DUPLICATES Chitipa (MW-CT) — the eastern lakeshore polygon
# was mislabelled MW-CT/Chitipa; the patch relabels it MW-KR/Karonga so all 28
# districts render (see superset/patches/malawi.geojson). Upstream fix proposed:
# https://github.com/apache/superset/pull/42707
#
# Resolve the bundled asset by CONTENT at build time — it is the only bundled
# geojson whose FeatureCollection name is "malawi" — rather than by a webpack
# content-hash filename. A Superset image bump then makes the build FAIL LOUDLY
# (0 or >1 matches) instead of silently patching a stale filename nothing
# references, which would let the map regress on an otherwise-green build.
COPY patches/malawi.geojson /tmp/malawi.geojson
USER root
RUN set -eu; \
    matches="$(grep -l '"name": "malawi"' /app/superset/static/assets/*.geojson || true)"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
      echo "MW-1482: expected exactly 1 bundled 'malawi' geojson asset, found $count: [$matches]" >&2; \
      exit 1; \
    fi; \
    cp /tmp/malawi.geojson "$matches"; \
    rm /tmp/malawi.geojson
USER superset

# Give the Country Map readable district borders by default. The
# plugin strokes districts with the theme's colorSplit token — rgba(5,5,5,.06),
# effectively invisible — and exposes no border control, so adjacent districts
# painted in similar colours blur together. Rewrite the style template inside
# the plugin chunk: white 1.6px borders (the plugin's own
# vector-effect: non-scaling-stroke keeps the width constant under zoom).
# Same resolve-by-content contract as the geojson patch above: exactly one
# bundled chunk carries the template, and an upstream change to it fails the
# build loudly instead of silently dropping the border styling.
USER root
RUN set -eu; \
    needle='.superset-legacy-chart-country-map path.region'; \
    matches="$(grep -rl "$needle" /app/superset/static/assets/*.js || true)"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
      echo "expected exactly 1 chunk with the country-map region style, found $count: [$matches]" >&2; \
      exit 1; \
    fi; \
    perl -pi -e 's/stroke: \$\{e\.colorSplit\};/stroke: #ffffff; stroke-width: 1.6px;/' "$matches"; \
    grep -q 'stroke: #ffffff; stroke-width: 1.6px;' "$matches"
USER superset
