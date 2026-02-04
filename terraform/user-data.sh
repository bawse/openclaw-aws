#!/bin/bash
# =============================================================================
# OpenClaw EC2 Bootstrap Script
# =============================================================================
# This script runs on first boot to set up OpenClaw with Docker and Bedrock.
# Logs are written to /var/log/user-data.log
# =============================================================================

# Log all output
exec > >(tee /var/log/user-data.log) 2>&1

# Exit on error, but we'll handle critical sections carefully
set -euo pipefail

echo "=== Starting OpenClaw setup at $(date) ==="
echo "Region: ${aws_region}"
echo "Primary model: ${bedrock_model_primary}"

# -----------------------------------------------------------------------------
# Helper function for retrying commands
# -----------------------------------------------------------------------------
retry() {
  local max_attempts=$1
  local delay=$2
  shift 2
  local attempt=1
  
  while [ $attempt -le $max_attempts ]; do
    echo "Attempt $attempt of $max_attempts: $*"
    if "$@"; then
      return 0
    fi
    echo "Attempt $attempt failed, waiting $delay seconds..."
    sleep $delay
    attempt=$((attempt + 1))
  done
  
  echo "All $max_attempts attempts failed for: $*"
  return 1
}

# -----------------------------------------------------------------------------
# Generate Gateway Auth Token
# -----------------------------------------------------------------------------
# Generate a random token for gateway authentication (required for non-loopback binds)
GATEWAY_TOKEN=$(openssl rand -hex 32)
echo "Generated gateway token: $GATEWAY_TOKEN"

# -----------------------------------------------------------------------------
# System Updates
# -----------------------------------------------------------------------------
echo "=== Updating system packages ==="
retry 3 10 dnf update -y

# -----------------------------------------------------------------------------
# Install Docker and dependencies
# -----------------------------------------------------------------------------
echo "=== Installing Docker ==="
# Note: Amazon Linux 2023 has curl-minimal pre-installed which conflicts with curl.
# We use --allowerasing to resolve this conflict and install full curl.
retry 3 10 dnf install -y docker git --allowerasing

# Start and enable Docker
systemctl start docker
systemctl enable docker

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Verify Docker is running
echo "Waiting for Docker to be ready..."
sleep 5
docker info

# -----------------------------------------------------------------------------
# Install Docker Compose
# -----------------------------------------------------------------------------
echo "=== Installing Docker Compose ==="
DOCKER_COMPOSE_VERSION="v2.24.5"
retry 3 10 curl -L "https://github.com/docker/compose/releases/download/$${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Create symlink for docker compose plugin
mkdir -p /usr/local/lib/docker/cli-plugins
ln -sf /usr/local/bin/docker-compose /usr/local/lib/docker/cli-plugins/docker-compose

# Verify installation
docker-compose --version

# -----------------------------------------------------------------------------
# Configure AWS Environment for Bedrock
# -----------------------------------------------------------------------------
echo "=== Configuring AWS environment ==="

# Workaround for IMDS credential detection (see OpenClaw docs)
# The EC2 instance is configured with http_put_response_hop_limit=2 to allow
# Docker containers to access IMDS for credentials.
cat >> /etc/environment <<'EOF'
AWS_REGION=${aws_region}
AWS_DEFAULT_REGION=${aws_region}
EOF

# Also set for ec2-user's shell
cat >> /home/ec2-user/.bashrc <<'EOF'

# AWS Bedrock configuration
export AWS_REGION=${aws_region}
export AWS_DEFAULT_REGION=${aws_region}
EOF

# -----------------------------------------------------------------------------
# Create OpenClaw directories
# -----------------------------------------------------------------------------
echo "=== Creating OpenClaw directories ==="
OPENCLAW_HOME="/home/ec2-user/openclaw"
OPENCLAW_CONFIG="/home/ec2-user/.openclaw"

mkdir -p "$OPENCLAW_HOME"
mkdir -p "$OPENCLAW_CONFIG"
mkdir -p "$OPENCLAW_CONFIG/workspace"

# -----------------------------------------------------------------------------
# Create OpenClaw configuration for Bedrock
# -----------------------------------------------------------------------------
echo "=== Writing OpenClaw configuration ==="
# Note: We use a here-doc without quotes to allow variable substitution for the token
cat > "$OPENCLAW_CONFIG/openclaw.json" <<EOFCONFIG
{
  "models": {
    "bedrockDiscovery": {
      "enabled": true,
      "region": "${aws_region}",
      "providerFilter": ["anthropic"],
      "refreshInterval": 3600,
      "defaultContextWindow": 200000,
      "defaultMaxTokens": 8192
    },
    "providers": {
      "amazon-bedrock": {
        "baseUrl": "https://bedrock-runtime.${aws_region}.amazonaws.com",
        "api": "bedrock-converse-stream",
        "auth": "aws-sdk",
        "models": [
          {
            "id": "${bedrock_model_primary}",
            "name": "Claude Sonnet 4.5 (Bedrock EU)",
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 8192
          },
          {
            "id": "${bedrock_model_fallback}",
            "name": "Claude 3.7 Sonnet (Bedrock EU)",
            "reasoning": true,
            "input": ["text", "image"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "workspace": "~/.openclaw/workspace",
      "model": {
        "primary": "amazon-bedrock/${bedrock_model_primary}",
        "fallbacks": ["amazon-bedrock/${bedrock_model_fallback}"]
      }
    }
  },
  "gateway": {
    "mode": "local",
    "bind": "lan",
    "port": 18789,
    "auth": {
      "token": "$GATEWAY_TOKEN"
    }
  },
  "logging": {
    "level": "info",
    "consoleLevel": "info"
  }
}
EOFCONFIG

# Save the token to a file for easy retrieval
echo "$GATEWAY_TOKEN" > "$OPENCLAW_CONFIG/gateway-token.txt"
chmod 600 "$OPENCLAW_CONFIG/gateway-token.txt"
echo "Gateway token saved to $OPENCLAW_CONFIG/gateway-token.txt"

# -----------------------------------------------------------------------------
# Create Docker Compose file
# -----------------------------------------------------------------------------
echo "=== Writing Docker Compose configuration ==="
# Note: The node:22-bookworm-slim image is minimal and missing several packages
# that openclaw's npm install requires:
#   - git: Required by npm for some git-based dependencies
#   - openssh-client: Required by libsignal-node to clone via SSH
#   - curl: Required for healthcheck and general HTTP operations
#   - ca-certificates: Required for HTTPS connections
cat > "$OPENCLAW_HOME/docker-compose.yml" <<'EOFDOCKER'
version: "3.8"

services:
  openclaw-gateway:
    image: node:22-bookworm-slim
    container_name: openclaw-gateway
    restart: unless-stopped
    working_dir: /app
    command: >
      sh -c "
        apt-get update && 
        apt-get install -y curl git openssh-client ca-certificates --no-install-recommends &&
        rm -rf /var/lib/apt/lists/* &&
        npm install -g openclaw@latest &&
        openclaw gateway --port 18789 --bind lan --verbose
      "
    ports:
      - "18789:18789"
    volumes:
      - /home/ec2-user/.openclaw:/root/.openclaw
      - /home/ec2-user/.openclaw/workspace:/root/.openclaw/workspace
    environment:
      # AWS_PROFILE=default is a workaround for OpenClaw's credential detection
      # which only checks env vars, not IMDS. See: https://docs.openclaw.ai/bedrock
      - AWS_PROFILE=default
      - AWS_REGION=${aws_region}
      - AWS_DEFAULT_REGION=${aws_region}
      - NODE_ENV=production
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:18789/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 300s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

EOFDOCKER

# -----------------------------------------------------------------------------
# Set permissions
# -----------------------------------------------------------------------------
echo "=== Setting permissions ==="
chown -R ec2-user:ec2-user "$OPENCLAW_HOME"
chown -R ec2-user:ec2-user "$OPENCLAW_CONFIG"

# -----------------------------------------------------------------------------
# Create systemd service for OpenClaw
# -----------------------------------------------------------------------------
echo "=== Creating systemd service ==="
cat > /etc/systemd/system/openclaw.service <<'EOFSVC'
[Unit]
Description=OpenClaw Gateway
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/openclaw
Environment="AWS_REGION=${aws_region}"
Environment="AWS_DEFAULT_REGION=${aws_region}"
ExecStartPre=/usr/local/bin/docker-compose pull --ignore-pull-failures
ExecStart=/usr/local/bin/docker-compose up --remove-orphans
ExecStop=/usr/local/bin/docker-compose down
Restart=always
RestartSec=10
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOFSVC

# Reload systemd and enable service
systemctl daemon-reload
systemctl enable openclaw.service

# -----------------------------------------------------------------------------
# Pre-pull Docker image to speed up first start
# -----------------------------------------------------------------------------
echo "=== Pre-pulling Docker image ==="
docker pull node:22-bookworm-slim || echo "Warning: Failed to pre-pull image, will retry on service start"

# -----------------------------------------------------------------------------
# Start OpenClaw
# -----------------------------------------------------------------------------
echo "=== Starting OpenClaw service ==="
systemctl start openclaw.service

# Wait a moment and check status
sleep 10
systemctl status openclaw.service --no-pager || true

# -----------------------------------------------------------------------------
# Final status
# -----------------------------------------------------------------------------
# Use IMDSv2 to get public IP (requires token)
IMDS_TOKEN=$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" || echo "")
if [ -n "$IMDS_TOKEN" ]; then
  PUBLIC_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 || echo "unknown")
else
  PUBLIC_IP="unknown"
fi

echo ""
echo "=== OpenClaw setup complete at $(date) ==="
echo "Instance public IP: $PUBLIC_IP"
echo "Gateway URL: http://$PUBLIC_IP:18789"
echo "Gateway Token: $GATEWAY_TOKEN"
echo ""
echo "IMPORTANT: Save the gateway token above! You'll need it to connect."
echo "           Token is also saved at: ~/.openclaw/gateway-token.txt"
echo ""
echo "To check status: sudo systemctl status openclaw"
echo "To view logs: sudo journalctl -u openclaw -f"
echo "To view container logs: docker logs -f openclaw-gateway"
echo "To get gateway token: cat ~/.openclaw/gateway-token.txt"
