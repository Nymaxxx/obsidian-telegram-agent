FROM node:22-alpine

ENV HOME=/state

RUN apk add --no-cache bash tini

WORKDIR /tmp
# Pin to a specific version when one is known stable: npm install -g obsidian-headless@x.y.z
RUN npm install -g obsidian-headless

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
