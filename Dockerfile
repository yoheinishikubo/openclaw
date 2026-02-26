FROM node:22-bookworm@sha256:cd7bcd2e7a1e6f72052feb023c7f6b722205d3fcab7bbcbd2d1bfdab10b1e935

# Install Bun (required for build scripts)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash
ENV PATH="/usr/local/bin:${PATH}"

RUN corepack enable

# Create a non-root user with a specific UID and GID
RUN groupadd -g 1001 ubuntu && useradd -u 1001 -g 1001 -m -s /bin/bash ubuntu

WORKDIR /app
# Allow non-root user to write temp files during runtime/tests.
RUN chown -R ubuntu:ubuntu /app

ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
  fi

# Google Workspace CLI needed for gog-based skills (Gmail watch, etc.)
RUN set -eux; \
  arch="$(dpkg --print-architecture)"; \
  case "$arch" in \
  amd64) suffix=linux_amd64 ;; \
  arm64) suffix=linux_arm64 ;; \
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; \
  esac; \
  download_url=$(curl -fsSL https://api.github.com/repos/steipete/gogcli/releases/latest \
  | python3 -c 'import json,sys; urls=[a.get("browser_download_url","") for a in json.load(sys.stdin).get("assets",[]) if sys.argv[1] in a.get("name","") and a.get("name","").endswith(".tar.gz")]; print(urls[0]) if urls else sys.exit(1)' "$suffix"); \
  curl -fsSL "$download_url" -o /tmp/gog.tgz; \
  tar -xzf /tmp/gog.tgz -C /tmp gog; \
  mv /tmp/gog /usr/local/bin/gog; \
  chmod +x /usr/local/bin/gog; \
  rm /tmp/gog.tgz

COPY --chown=ubuntu:ubuntu package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY --chown=ubuntu:ubuntu ui/package.json ./ui/package.json
COPY --chown=ubuntu:ubuntu patches ./patches
COPY --chown=ubuntu:ubuntu scripts ./scripts

USER ubuntu
# Reduce OOM risk on low-memory hosts during dependency installation.
# Docker builds on small VMs may otherwise fail with "Killed" (exit 137).
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

# Optionally install Chromium and Xvfb for browser automation.
# Build with: docker build --build-arg OPENCLAW_INSTALL_BROWSER=1 ...
# Adds ~300MB but eliminates the 60-90s Playwright install on every container start.
# Must run after pnpm install so playwright-core is available in node_modules.
USER root
ARG OPENCLAW_INSTALL_BROWSER=""
RUN if [ -n "$OPENCLAW_INSTALL_BROWSER" ]; then \
  apt-get update && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xvfb && \
  mkdir -p /home/ubuntu/.cache/ms-playwright && \
  PLAYWRIGHT_BROWSERS_PATH=/home/ubuntu/.cache/ms-playwright \
  node /app/node_modules/playwright-core/cli.js install --with-deps chromium && \
  chown -R ubuntu:ubuntu /home/ubuntu/.cache/ms-playwright && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*; \
  fi

USER ubuntu
COPY --chown=ubuntu:ubuntu . .
RUN pnpm build
# Force pnpm for UI build (Bun may fail on ARM/Synology architectures)
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

ENV NODE_ENV=production


# Security hardening: Run as non-root user
USER ubuntu

# Start gateway server with default config.
# Binds to loopback (127.0.0.1) by default for security.
#
# For container platforms requiring external health checks:
#   1. Set OPENCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_PASSWORD env var
#   2. Override CMD: ["node","openclaw.mjs","gateway","--allow-unconfigured","--bind","lan"]
CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
