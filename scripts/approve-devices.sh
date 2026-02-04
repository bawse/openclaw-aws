#!/bin/bash
# =============================================================================
# Auto-Approve Pending Device Pairing Requests
# =============================================================================
# This script approves any pending device pairing requests on the OpenClaw
# instance. Run this after first connecting to the UI when you see
# "pairing required".
#
# Usage: ./scripts/approve-devices.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cd "$TERRAFORM_DIR"

# Check if Terraform state exists
if [[ ! -f "terraform.tfstate" ]]; then
    log_error "No Terraform state found. Run ./scripts/deploy.sh apply first."
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

log_info "Checking for pending device pairing requests..."

# Get the list of pending devices
PENDING_OUTPUT=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
    "docker exec openclaw-gateway openclaw devices list 2>/dev/null || echo 'NO_CONTAINER'" 2>/dev/null)

if [[ "$PENDING_OUTPUT" == *"NO_CONTAINER"* ]]; then
    log_error "OpenClaw container is not running. Wait for setup to complete."
    log_info "Check status with: ./scripts/logs.sh setup"
    exit 1
fi

# Check if there are any pending requests
if [[ "$PENDING_OUTPUT" == *"No pending"* ]] || [[ -z "$PENDING_OUTPUT" ]]; then
    log_info "No pending device pairing requests found."
    log_info "If you're seeing 'pairing required' in the UI, try refreshing the page"
    log_info "and then run this script again."
    exit 0
fi

echo ""
echo "Pending devices:"
echo "$PENDING_OUTPUT"
echo ""

# Extract request IDs (UUIDs in the format xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
# The table output contains UUIDs as request IDs in the first column
REQUEST_IDS=$(echo "$PENDING_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')

if [[ -z "$REQUEST_IDS" ]]; then
    log_warning "No pending request IDs found in output."
    log_info "If you're still seeing 'pairing required', the request may have expired."
    log_info "Refresh the browser to create a new request, then run this script again."
    exit 0
fi

# Approve each pending request
APPROVED_COUNT=0
for REQUEST_ID in $REQUEST_IDS; do
    log_info "Approving device: $REQUEST_ID"
    
    APPROVE_OUTPUT=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        "docker exec openclaw-gateway openclaw devices approve '$REQUEST_ID'" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        log_success "Approved: $REQUEST_ID"
        ((APPROVED_COUNT++))
    else
        log_warning "Failed to approve $REQUEST_ID: $APPROVE_OUTPUT"
    fi
done

echo ""
if [[ $APPROVED_COUNT -gt 0 ]]; then
    log_success "Approved $APPROVED_COUNT device(s)."
    log_info "Refresh your browser to connect."
else
    log_warning "No devices were approved. Check the output above."
fi
