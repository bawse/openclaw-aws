#!/bin/bash
# =============================================================================
# View OpenClaw Logs on EC2 Instance
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

# Get connection details
INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null)
KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)

# Key path is relative to project root
cd "$PROJECT_ROOT"
RESOLVED_KEY_PATH="$PROJECT_ROOT/$KEY_PATH"

if [[ ! -f "$RESOLVED_KEY_PATH" ]]; then
    echo "Error: SSH key not found at $RESOLVED_KEY_PATH"
    exit 1
fi

echo "Fetching OpenClaw logs..."
echo ""

# Check which log type to show
LOG_TYPE="${1:-gateway}"

case "$LOG_TYPE" in
    gateway)
        ssh -i "$RESOLVED_KEY_PATH" "ec2-user@$INSTANCE_IP" \
            "cd ~/openclaw && docker-compose logs -f --tail=100 openclaw-gateway"
        ;;
    setup)
        ssh -i "$RESOLVED_KEY_PATH" "ec2-user@$INSTANCE_IP" \
            "sudo cat /var/log/user-data.log"
        ;;
    service)
        ssh -i "$RESOLVED_KEY_PATH" "ec2-user@$INSTANCE_IP" \
            "sudo journalctl -u openclaw.service -f"
        ;;
    *)
        echo "Usage: $0 [gateway|setup|service]"
        echo ""
        echo "  gateway  - OpenClaw Gateway container logs (default)"
        echo "  setup    - EC2 user-data setup logs"
        echo "  service  - systemd service logs"
        exit 1
        ;;
esac
