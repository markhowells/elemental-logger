FROM signalk/signalk-server:latest

RUN npm install --prefix /home/node/.signalk \
        https://github.com/markhowells/signalk-to-influxdb2/archive/refs/heads/tag-consolidated.tar.gz && \
    cd /home/node/.signalk/node_modules/signalk-to-influxdb2 && \
    npm install --include=dev && \
    npm run build && \
    mkdir -p /home/node/.signalk-defaults/node_modules && \
    cp -r /home/node/.signalk/node_modules/signalk-to-influxdb2 \
        /home/node/.signalk-defaults/node_modules/signalk-to-influxdb2

# Copy defaults to a location outside the volume mount point.
# The entrypoint seeds these into the volume on first run only —
# runtime changes (e.g. units, vessel name) are never overwritten.
COPY --chown=node:node config/signalk/settings.json \
    /home/node/.signalk-defaults/settings.json
COPY --chown=node:node config/signalk/plugin-config-data/signalk-to-influxdb2.json \
    /home/node/.signalk-defaults/plugin-config-data/signalk-to-influxdb2.json

COPY --chmod=755 docker-entrypoint.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
