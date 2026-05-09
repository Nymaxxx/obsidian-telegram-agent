FROM python:3.13-slim

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    procps \
    tini \
  && rm -rf /var/lib/apt/lists/*

# Both Takopi and Claude Code CLI install into /root/.local/bin and expect
# a writable HOME for config/state. Running as root inside the container is
# intentional — the container is single-purpose and network-isolated (no
# inbound ports). The vault is the only shared surface, mounted as a volume.
#
# Pinned versions: bump these deliberately so a Claude Code or Takopi
# upstream release can't silently change behavior in production.
ARG TAKOPI_VERSION=0.22.3
ARG CLAUDE_CODE_VERSION=2.1.128
WORKDIR /tmp
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# SC2016: $PATH in single quotes is intentional — the string is written to a
# profile script that expands it at shell startup, not at image build time.
# hadolint ignore=SC2016
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && /root/.local/bin/uv tool install "takopi==${TAKOPI_VERSION}" \
  && curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}" \
  && echo 'export PATH="/root/.local/bin:$PATH"' > /etc/profile.d/local-bin.sh

ENV PATH="/root/.local/bin:${PATH}" \
    HOME=/state

COPY --chmod=755 entrypoint.sh /entrypoint.sh

WORKDIR /vault
ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
