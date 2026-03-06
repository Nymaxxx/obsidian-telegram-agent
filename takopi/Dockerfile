FROM python:3.14-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PATH="/root/.local/bin:${PATH}" \
    HOME=/state

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    nodejs \
    npm \
    tini \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && /root/.local/bin/uv tool install -U takopi \
  && curl -fsSL https://claude.ai/install.sh | bash

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
