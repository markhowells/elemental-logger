# syntax=docker/dockerfile:1
#
# Custom SignalK image: SignalK server + the signalk-to-influxdb2 plugin fork
# + CAN helper scripts + a supervising entrypoint.
#
# The image contains NO site configuration and NO secrets. Managed config is
# bind-mounted at /marine-config by docker-compose (rendered on the Pi by
# marine-apply). See docs/config-model.md.
#
# Versions come from plugin.version (SIGNALK_BASE / PLUGIN_REPO / PLUGIN_REF):
#   set -a; . images/signalk/plugin.version; set +a
#   docker build -f images/signalk/Dockerfile \
#       --build-arg SIGNALK_BASE --build-arg PLUGIN_REPO --build-arg PLUGIN_REF \
#       -t elemental-signalk:dev images/signalk
ARG SIGNALK_BASE
# hadolint ignore=DL3006  (pinned by tag+digest via plugin.version)
FROM ${SIGNALK_BASE}

ARG PLUGIN_REPO
ARG PLUGIN_REF

RUN if [ -z "${PLUGIN_REPO}" ] || [ -z "${PLUGIN_REF}" ]; then \
        echo "PLUGIN_REPO and PLUGIN_REF build args are required (see plugin.version)" >&2; exit 1; \
    fi

# Install and build the plugin from an immutable commit, then stash a copy
# outside the volume mount point; the entrypoint syncs it into the volume on
# every start so image rebuilds always take effect.
RUN npm install --prefix /home/node/.signalk \
        "https://github.com/${PLUGIN_REPO}/archive/${PLUGIN_REF}.tar.gz" && \
    npm install --prefix /home/node/.signalk/node_modules/signalk-to-influxdb2 --include=dev && \
    npm run build --prefix /home/node/.signalk/node_modules/signalk-to-influxdb2 && \
    mkdir -p /home/node/.signalk-defaults/node_modules && \
    cp -r /home/node/.signalk/node_modules/signalk-to-influxdb2 \
        /home/node/.signalk-defaults/node_modules/signalk-to-influxdb2

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        can-utils && \
    rm -rf /var/lib/apt/lists/*
USER node

COPY --chmod=755 bin/candump2analyzer /usr/local/bin/candump2analyzer
COPY --chmod=755 bin/signalk-analyzer /usr/local/bin/analyzer
COPY --chmod=755 bin/merge-settings.js /usr/local/bin/merge-settings

COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/markhowells/elemental-logger" \
      org.opencontainers.image.description="SignalK + signalk-to-influxdb2 fork for the Elemental logger"

ENTRYPOINT ["/docker-entrypoint.sh"]
