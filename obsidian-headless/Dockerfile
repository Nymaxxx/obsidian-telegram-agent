FROM node:22-alpine

ENV HOME=/state

RUN apk add --no-cache bash tini

WORKDIR /tmp
RUN npm install -g obsidian-headless

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/sbin/tini", "--", "/entrypoint.sh"]
