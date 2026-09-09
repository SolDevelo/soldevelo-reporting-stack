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

# Draw the LAST label on a time x-axis, and only the last. Upstream pins the
# edge labels but only when the labels are not rotated, so any chart with a
# rotation loses the guarantee and the final month never gets a label.
#
# An earlier revision of this file pinned BOTH edges. That was wrong on the
# minimum side: showMinLabel labels the axis EXTENT minimum, not the first data
# point, and a bar chart widens the extent by half a band to fit its bars - so
# with twelve months selected the leftmost label read "Dec 24" over a bar that
# was January 2025. A label that disagrees with its own bar is worse than a
# missing one. Line charts need no band width, their extent hugs the data, which
# is why only the bar charts showed it.
#
# So gate on the SIDE, not on the chart type. seriesType is in scope at both
# call sites but under different minified names with several candidate bindings
# each, and a patch that has to pick the right one of those would break silently
# on the next Superset bump - which is exactly what the resolve-by-content
# contract exists to prevent.
#
# Keep the explicit alignment only on the unrotated path: with a rotation
# ECharts derives the anchor from the angle and forcing an alignment fights it.
#
# Same contract as the patches above - exactly one chunk carries the expression,
# at exactly two call sites (the regular and the mixed Timeseries transforms).
# An upstream change to either fails the build loudly.
USER root
RUN set -eu; \
    needle='&&{showMaxLabel:!0,alignMaxLabel:"right"})'; \
    matches="$(grep -F -l "$needle" /app/superset/static/assets/*.js || true)"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
      echo "expected exactly 1 chunk with the time-axis edge-label expression, found $count: [$matches]" >&2; \
      exit 1; \
    fi; \
    sites="$(grep -o -e '},[A-Za-z0-9_$]*&&{showMaxLabel:!0,alignMaxLabel:"right"})' "$matches" | grep -c . || true)"; \
    if [ "$sites" -ne 2 ]; then \
      echo "expected exactly 2 time-axis edge-label call sites, found $sites" >&2; \
      exit 1; \
    fi; \
    perl -0777 -pi -e 's{axisLabel:([\w\$]+)\(\{hideOverlap:([\w\$]+)!==([\w\$]+\.[\w\$]+)\.Time\|\|0===([\w\$]+),formatter:([\w\$]+),rotate:\4,interval:([\w\$]+)\},[\w\$]+&&\{showMaxLabel:!0,alignMaxLabel:"right"\}\)}{axisLabel:$1({hideOverlap:$2!==$3.Time||0===$4,formatter:$5,rotate:$4,interval:$6},$2===$3.Time&&(0===$4?{showMaxLabel:!0,alignMaxLabel:"right"}:{showMaxLabel:!0}))}g' "$matches"; \
    patched="$(grep -o -e ':{showMaxLabel:!0}))' "$matches" | grep -c . || true)"; \
    leftover="$(grep -o -e '},[A-Za-z0-9_$]*&&{showMaxLabel:!0,alignMaxLabel:"right"})' "$matches" | grep -c . || true)"; \
    minpinned="$(grep -o -e 'showMinLabel:!0' "$matches" | grep -c . || true)"; \
    if [ "$patched" -ne 2 ] || [ "$leftover" -ne 0 ] || [ "$minpinned" -ne 0 ]; then \
      echo "max-label patch did not apply cleanly: patched=$patched leftover=$leftover minpinned=$minpinned" >&2; \
      exit 1; \
    fi
USER superset

# Stop a time x-axis repeating the same label. Two distinct cases produce it,
# both only when the labels are rotated:
#   - the axis end lands mid-month, so the last month tick and the axis-extent
#     label both render as e.g. "Apr '26", side by side;
#   - zoomed inside a single month, every sub-month tick formats to the same
#     month string.
# Measured on a rotated monthly chart over 104 zoom windows (both slider
# handles): 91 of them showed a repeat.
#
# The transform already carries a de-duplicating formatter for exactly this,
# behind the same "no rotation" guard as the edge labels above, so widen it to
# every time axis. It cannot be reused verbatim: upstream keeps the previous
# label in a closure that outlives a single layout pass, and ECharts formats the
# labels more than once per render, so a legitimate label whose text matches the
# tail of the previous pass is blanked — that turns the repeat into a MISSING
# month, which is worse. Keying the reset off the tick value instead (labels are
# formatted in ascending order, so a value that does not advance means a new
# pass has begun) survives repeated passes. Verified over the same 104 windows:
# 0 repeats, and no window loses a month that upstream would have shown.
#
# Resolve-by-content with the same fail-loud contract as the patches above.
USER root
RUN set -eu; \
    matches="$(grep -F -l '&&0===' /app/superset/static/assets/*.js | xargs grep -l -E '=[A-Za-z0-9_$]+===[A-Za-z0-9_$.]+\.Time&&0===[A-Za-z0-9_$]+,[A-Za-z0-9_$]+=[A-Za-z0-9_$]+\?\(' || true)"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
      echo "expected exactly 1 chunk with the time-axis label formatter, found $count: [$matches]" >&2; \
      exit 1; \
    fi; \
    sites="$(grep -o -E '=[A-Za-z0-9_$]+===[A-Za-z0-9_$.]+\.Time&&0===[A-Za-z0-9_$]+,[A-Za-z0-9_$]+=[A-Za-z0-9_$]+\?\(' "$matches" | grep -c . || true)"; \
    if [ "$sites" -ne 2 ]; then \
      echo "expected exactly 2 time-axis label formatter sites, found $sites" >&2; \
      exit 1; \
    fi; \
    perl -0777 -pi -e 's{([\w\$]+)=([\w\$]+)===([\w\$]+\.[\w\$]+)\.Time&&0===([\w\$]+),([\w\$]+)=\1\?\(([\w\$]+)=([\w\$]+)=>\{let ([\w\$]+)="function"==typeof ([\w\$]+)\?\9\(\7\):String\(\7\);return \8===([\w\$]+)\?"":\(\10=\8,\8\)\},"function"==typeof \9&&"id"in \9&&\(\6\.id=\9\.id\),\6\):\9}{$1=$2===$3.Time&&0===$4,$5=$2===$3.Time?($6=$7=>{let $8="function"==typeof $9?$9($7):String($7),_n=+$7;if(!(_n>$6._pv))$6._pt=void 0;$6._pv=_n;return $8===$6._pt?"":($6._pt=$8,$8)},"function"==typeof $9&&"id"in $9&&($6.id=$9.id),$6):$9}g' "$matches"; \
    applied="$(grep -o -e '_pt=void 0' "$matches" | grep -c . || true)"; \
    leftover="$(grep -o -E '=[A-Za-z0-9_$]+===[A-Za-z0-9_$.]+\.Time&&0===[A-Za-z0-9_$]+,[A-Za-z0-9_$]+=[A-Za-z0-9_$]+\?\(' "$matches" | grep -c . || true)"; \
    if [ "$applied" -ne 2 ] || [ "$leftover" -ne 0 ]; then \
      echo "time-axis label dedupe did not apply: applied=$applied leftover=$leftover" >&2; \
      exit 1; \
    fi
USER superset
