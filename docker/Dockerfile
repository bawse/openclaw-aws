# =============================================================================
# OpenClaw Docker Image
# =============================================================================
# This Dockerfile creates a production-ready OpenClaw gateway image with all
# dependencies pre-installed for fast, reliable container restarts.
#
# Designed for AWS EC2 deployment with Bedrock integration.
#
# Build: docker build -t openclaw-gateway .
# Run:   docker-compose up -d
# =============================================================================

FROM node:22-bookworm-slim

# =============================================================================
# System Dependencies
# =============================================================================
# - curl: Health checks and HTTP operations
# - git: Required by npm for git-based dependencies
# - openssh-client: Required by libsignal-node during npm install
# - ca-certificates: HTTPS/TLS connections
# - python3 + pip + venv: Automation scripts and skill dependencies
# - python3-requests: HTTP library for Python scripts
# - cron: Scheduled jobs (OpenClaw cron feature)
# - procps: Process management (ps, top, kill)
# =============================================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    openssh-client \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    python3-requests \
    cron \
    procps \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Python Packages (pip)
# =============================================================================
# Install Python packages that aren't available via apt.
# --break-system-packages is required on Debian 12+ (PEP 668)
# =============================================================================

RUN pip3 install --break-system-packages \
    duckdb

# =============================================================================
# OpenClaw Installation
# =============================================================================
# Install OpenClaw globally. Note: We may reinstall at runtime to get latest.
# =============================================================================

WORKDIR /app

RUN npm install -g openclaw@latest

# =============================================================================
# Runtime Configuration
# =============================================================================

# Create OpenClaw directories (will be overwritten by volume mounts)
RUN mkdir -p /root/.openclaw/workspace

ENV NODE_ENV=production

EXPOSE 18789

# Health check with generous start period for npm updates
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
    CMD curl -sf http://localhost:18789/health || exit 1

# Start cron service and OpenClaw gateway
# npm install runs at startup to ensure latest version
CMD ["sh", "-c", "service cron start && npm install -g openclaw@latest && openclaw gateway --port 18789 --bind lan --verbose"]
