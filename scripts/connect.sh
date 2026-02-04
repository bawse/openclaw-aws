#!/bin/bash
# =============================================================================
# OpenClaw Connect - One Command to Start Using OpenClaw
# =============================================================================
# This script handles everything needed to connect to OpenClaw:
#   1. Starts SSH tunnel (background)
#   2. Opens browser with token
#   3. Auto-approves device pairing
#
# Usage: ./scripts/connect.sh [--no-browser]
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }

# Parse arguments
OPEN_BROWSER=true
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-browser) OPEN_BROWSER=false; shift ;;
        --help|-h)
            echo "OpenClaw Connect"
            echo ""
            echo "Usage: $0 [--no-browser]"
            echo ""
            echo "Options:"
            echo "  --no-browser  Don't open browser automatically"
            echo ""
            echo "This script starts the SSH tunnel, opens your browser,"
            echo "and auto-approves device pairing."
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

cd "$TERRAFORM_DIR"

# Check if Terraform state exists
if [[ ! -f "terraform.tfstate" ]]; then
    log_error "No deployment found. Run ./scripts/deploy.sh apply first."
    exit 1
fi

# Get connection details
INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null)
KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)

cd "$PROJECT_ROOT"
RESOLVED_KEY_PATH="$PROJECT_ROOT/$KEY_PATH"

if [[ ! -f "$RESOLVED_KEY_PATH" ]]; then
    log_error "SSH key not found at $RESOLVED_KEY_PATH"
    exit 1
fi

# Get gateway token
log_step "Getting gateway token..."
TOKEN=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    "ec2-user@$INSTANCE_IP" 'cat ~/.openclaw/gateway-token.txt' 2>/dev/null || echo "")

if [[ -z "$TOKEN" ]]; then
    log_error "Could not retrieve gateway token. Is the instance ready?"
    log_info "Check status: ./scripts/deploy.sh status"
    exit 1
fi

ACCESS_URL="http://localhost:18789?token=$TOKEN"

# Check if tunnel is already running
TUNNEL_PID=""
if pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" > /dev/null 2>&1; then
    log_success "SSH tunnel already running"
    TUNNEL_PID=$(pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" | head -1)
else
    # Start SSH tunnel in background
    log_step "Starting SSH tunnel..."
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no \
        -f -N -L 18789:127.0.0.1:18789 "ec2-user@$INSTANCE_IP"
    
    TUNNEL_PID=$(pgrep -f "ssh.*18789:127.0.0.1:18789.*$INSTANCE_IP" | head -1)
    
    if [[ -n "$TUNNEL_PID" ]]; then
        log_success "SSH tunnel started (PID: $TUNNEL_PID)"
    else
        log_error "Failed to start SSH tunnel"
        exit 1
    fi
    
    # Wait for tunnel to be ready
    sleep 1
fi

# Verify tunnel is working
if curl -s --connect-timeout 2 "http://localhost:18789/health" &> /dev/null; then
    log_success "Gateway accessible at localhost:18789"
else
    log_warning "Gateway not responding yet (may still be starting)"
fi

# Open browser
if [[ "$OPEN_BROWSER" == "true" ]]; then
    log_step "Opening browser..."
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open "$ACCESS_URL"
    elif command -v xdg-open &> /dev/null; then
        xdg-open "$ACCESS_URL" &
    elif command -v wslview &> /dev/null; then
        wslview "$ACCESS_URL" &
    else
        log_warning "Could not detect browser. Open manually: $ACCESS_URL"
    fi
    
    # Give browser time to connect
    sleep 2
fi

# Auto-approve device pairing
log_step "Checking for device pairing requests..."

# Wait a moment for the device to register
sleep 2

# Get pending devices
PENDING_OUTPUT=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
    "docker exec openclaw-gateway openclaw devices list 2>/dev/null || echo 'NO_CONTAINER'" 2>/dev/null)

if [[ "$PENDING_OUTPUT" == *"NO_CONTAINER"* ]]; then
    log_warning "OpenClaw container not ready. Try again in a moment."
elif [[ "$PENDING_OUTPUT" == *"No pending"* ]] || [[ -z "$PENDING_OUTPUT" ]]; then
    log_info "No pending pairing requests"
else
    # Extract and approve request IDs
    REQUEST_IDS=$(echo "$PENDING_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)
    
    if [[ -n "$REQUEST_IDS" ]]; then
        for REQUEST_ID in $REQUEST_IDS; do
            ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
                "docker exec openclaw-gateway openclaw devices approve '$REQUEST_ID'" &>/dev/null && \
                log_success "Approved device: ${REQUEST_ID:0:8}..."
        done
        log_info "Refresh your browser if needed"
    fi
fi

# Print summary
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  OpenClaw is ready!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BOLD}Access URL:${NC}"
echo -e "  ${CYAN}$ACCESS_URL${NC}"
echo ""
echo -e "${BOLD}Tunnel:${NC} Running in background (PID: $TUNNEL_PID)"
echo ""
echo "To stop the tunnel:  kill $TUNNEL_PID"
echo "To reconnect:        ./scripts/connect.sh"
echo ""

# Copy to clipboard
if command -v pbcopy &> /dev/null; then
    echo "$ACCESS_URL" | pbcopy
    log_success "URL copied to clipboard"
elif command -v xclip &> /dev/null; then
    echo "$ACCESS_URL" | xclip -selection clipboard
    log_success "URL copied to clipboard"
fi
