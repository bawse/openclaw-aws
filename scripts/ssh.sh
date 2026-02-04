#!/bin/bash
# =============================================================================
# SSH to OpenClaw EC2 Instance
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

cd "$TERRAFORM_DIR"

# Check if Terraform state exists
if [[ ! -f "terraform.tfstate" ]]; then
    echo "Error: No Terraform state found. Run ./scripts/deploy.sh apply first."
    exit 1
fi

# Get SSH command from Terraform output
SSH_CMD=$(terraform output -raw ssh_command 2>/dev/null)

if [[ -z "$SSH_CMD" ]]; then
    echo "Error: Could not get SSH command from Terraform outputs."
    exit 1
fi

echo "Connecting to OpenClaw instance..."
echo "Command: $SSH_CMD"
echo ""

# Execute from project root so relative paths work
cd "$PROJECT_ROOT"
exec $SSH_CMD
