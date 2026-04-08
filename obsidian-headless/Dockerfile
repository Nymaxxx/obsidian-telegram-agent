FROM node:22-alpine

ENV HOME=/state

RUN apk add --no-cache bash tini

WORKDIR /tmp
RUN npm install -g obsidian-headless@0.0.2

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
