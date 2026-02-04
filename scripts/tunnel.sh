#!/bin/bash
# =============================================================================
# Create SSH Tunnel for OpenClaw Gateway Access
# =============================================================================
# This creates a secure tunnel to access the Gateway at localhost:18789
#
# Usage: ./scripts/tunnel.sh [--background]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Parse arguments
BACKGROUND=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --background|-b) BACKGROUND=true; shift ;;
        --help|-h)
            echo "SSH Tunnel for OpenClaw Gateway"
            echo ""
            echo "Usage: $0 [--background]"
            echo ""
            echo "Options:"
            echo "  --background, -b  Run tunnel in background"
            echo ""
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$TERRAFORM_DIR"

# Check if Terraform state exists
if [[ ! -f "terraform.tfstate" ]]; then
    echo "Error: No Terraform state found. Run ./scripts/deploy.sh apply first."
    exit 1
fi

# Get connection details from Terraform output
INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null)
KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)

if [[ -z "$INSTANCE_IP" ]] || [[ -z "$KEY_PATH" ]]; then
    echo "Error: Could not get connection details from Terraform outputs."
    exit 1
fi

# Key path is relative to project root
cd "$PROJECT_ROOT"
RESOLVED_KEY_PATH="$PROJECT_ROOT/$KEY_PATH"

if [[ ! -f "$RESOLVED_KEY_PATH" ]]; then
    echo "Error: SSH key not found at $RESOLVED_KEY_PATH"
    exit 1
fi

# Check if tunnel is already running
if pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" > /dev/null 2>&1; then
    EXISTING_PID=$(pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" | head -1)
    echo "Tunnel already running (PID: $EXISTING_PID)"
    echo ""
    echo "  Local:  http://localhost:18789"
    echo ""
    echo "To stop: kill $EXISTING_PID"
    exit 0
fi

if [[ "$BACKGROUND" == "true" ]]; then
    echo "Starting SSH tunnel in background..."
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no \
        -f -N -L 18789:127.0.0.1:18789 "ec2-user@$INSTANCE_IP"
    
    sleep 1
    TUNNEL_PID=$(pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" | head -1)
    
    if [[ -n "$TUNNEL_PID" ]]; then
        echo "Tunnel started (PID: $TUNNEL_PID)"
        echo ""
        echo "  Local:  http://localhost:18789"
        echo ""
        echo "To stop: kill $TUNNEL_PID"
    else
        echo "Error: Failed to start tunnel"
        exit 1
    fi
else
    echo "Creating SSH tunnel to OpenClaw Gateway..."
    echo ""
    echo "  Local:  http://localhost:18789"
    echo "  Remote: http://$INSTANCE_IP:18789"
    echo ""
    echo "Press Ctrl+C to close the tunnel."
    echo ""
    
    exec ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no \
        -N -L 18789:127.0.0.1:18789 "ec2-user@$INSTANCE_IP"
fi
