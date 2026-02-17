FROM ubuntu:24.04

ARG TAKOPI_VERSION=0.22.1

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git jq ripgrep bash openssh-client \
    gh tini procps \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash agent

USER agent
WORKDIR /home/agent
ENV PATH="/home/agent/.local/bin:${PATH}"

# uv + takopi (pinned version)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && uv python install 3.14 \
 && uv tool install takopi==${TAKOPI_VERSION}

# Claude Code
RUN curl -fsSL https://claude.ai/install.sh | bash

USER root
WORKDIR /
COPY entrypoint.sh /entrypoint.sh
COPY templates/CLAUDE.md /opt/templates/CLAUDE.md
RUN chmod +x /entrypoint.sh \
 && mkdir -p /work/repos /home/agent/.takopi \
 && chown -R agent:agent /work /home/agent /opt/templates

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD pgrep -f takopi > /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini","--","/entrypoint.sh"]
