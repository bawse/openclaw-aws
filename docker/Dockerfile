# =============================================================================
# OpenClaw Docker Image
# =============================================================================
# This Dockerfile creates a production-ready OpenClaw gateway image.
# It's designed for AWS EC2 deployment with Bedrock integration.
# =============================================================================

FROM node:22-bookworm-slim

# Install system dependencies
# Note: openssh-client is required by libsignal-node (an openclaw dependency)
# which uses SSH to clone a git repository during npm install
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    openssh-client \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd -m -s /bin/bash openclaw

# Set working directory
WORKDIR /app

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create OpenClaw directories
RUN mkdir -p /home/openclaw/.openclaw/workspace \
    && chown -R openclaw:openclaw /home/openclaw

# Switch to non-root user
USER openclaw

# Set environment variables
ENV HOME=/home/openclaw
ENV NODE_ENV=production

# Expose Gateway port
EXPOSE 18789

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:18789/health || exit 1

# Default command
CMD ["openclaw", "gateway", "--port", "18789", "--bind", "lan", "--verbose"]
