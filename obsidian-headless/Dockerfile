FROM node:22-alpine

ENV HOME=/state

RUN apk add --no-cache bash tini

# Pinned version: bump deliberately. As of 0.0.3+ obsidian-headless dropped
# the keytar dependency and switched to flat-file credential storage, which
# removes the libsecret/dbus/X11 requirement that broke headless containers.
ARG OBSIDIAN_HEADLESS_VERSION=0.0.8
WORKDIR /tmp
RUN npm install -g "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}"

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
