# Build openclaw from source to avoid npm packaging gaps (some dist files are not shipped).
FROM node:22-bookworm AS openclaw-build

# Dependencies needed for openclaw build
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    curl \
    python3 \
    make \
    g++ \
  && rm -rf /var/lib/apt/lists/*

# Install Bun (openclaw build uses it)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

RUN npm install --global corepack@latest \
  && corepack enable pnpm \
  && corepack use pnpm@latest-10

WORKDIR /openclaw

# Pin to a known ref (tag/branch). If it doesn't exist, fall back to main.
ARG OPENCLAW_GIT_REF=main
RUN git clone --depth 1 --branch "${OPENCLAW_GIT_REF}" https://github.com/openclaw/openclaw.git .

# Patch: relax version requirements for packages that may reference unpublished versions.
# Apply to all extension package.json files to handle workspace protocol (workspace:*).
RUN set -eux; \
  find ./extensions -name 'package.json' -type f | while read -r f; do \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*">=[^"]+"/"openclaw": "*"/g' "$f"; \
    sed -i -E 's/"openclaw"[[:space:]]*:[[:space:]]*"workspace:[^"]+"/"openclaw": "*"/g' "$f"; \
  done

RUN pnpm install --no-frozen-lockfile
RUN pnpm build
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:install && pnpm ui:build

# Build wrapper (TypeScript -> JS)
FROM node:22-bookworm AS wrapper-build
WORKDIR /app
COPY package.json ./
COPY tsconfig.json ./
COPY src ./src
RUN npm install
RUN npm run build

# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    nano \
    git \
    tmux \
  && rm -rf /var/lib/apt/lists/*

# Tailscale (https://tailscale.com/download/linux)
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
  && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null \
  && apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tailscale \
  && rm -rf /var/lib/apt/lists/*

# Ensure pnpm is available in the runtime container too.
RUN npm install --global corepack@latest \
  && corepack enable pnpm \
  && corepack use pnpm@latest-10

# Persist OpenClaw state/workspace on the mounted /data volume.
# - Default OpenClaw paths resolve to ~/.openclaw/... (HOME=/root in containers).
ENV OPENCLAW_STATE_DIR=/data/.openclaw
ENV OPENCLAW_HOME=/data/.openclaw
ENV OPENCLAW_WORKSPACE_DIR=/data/.openclaw/workspace

# Runtime init (volume is mounted at container start, not build time)
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Extra tooling
# Convex CLI: https://docs.convex.dev/cli
RUN npm install -g convex && npm cache clean --force

# OpenAI Codex CLI (provides `codex`)
RUN npm install -g @openai/codex && npm cache clean --force

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy built openclaw
COPY --from=openclaw-build /openclaw /openclaw

# Provide an openclaw executable
RUN set -eux; \
  entry=""; \
  for p in \
    /openclaw/dist/entry.js \
    /openclaw/dist/entry.mjs \
    /openclaw/packages/openclaw/dist/entry.js \
    /openclaw/packages/openclaw/dist/entry.mjs \
  ; do \
    if [ -f "$p" ]; then entry="$p"; break; fi; \
  done; \
  if [ -z "$entry" ]; then \
    echo "openclaw entry not found under /openclaw (expected dist/entry.{js,mjs})" >&2; \
    exit 1; \
  fi; \
  printf '%s\n' '#!/usr/bin/env bash' "exec node ${entry} \"\$@\"" > /usr/local/bin/openclaw; \
  chmod +x /usr/local/bin/openclaw

COPY --from=wrapper-build /app/dist ./dist

# The wrapper listens on this port.
ENV OPENCLAW_PUBLIC_PORT=8080
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["node", "dist/server.js"]
