#!/bin/bash
# =============================================================================
# Update OpenClaw to Latest Version
# =============================================================================
# This script updates OpenClaw to the latest version by restarting the container.
# The container installs openclaw@latest on startup.
#
# Usage: ./scripts/update.sh [--auto-enable|--auto-disable|--status]
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

# Get connection details
get_connection() {
    cd "$TERRAFORM_DIR"
    if [[ ! -f "terraform.tfstate" ]]; then
        log_error "No Terraform state found. Run ./scripts/deploy.sh apply first."
        exit 1
    fi
    INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null)
    KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null)
    RESOLVED_KEY_PATH="$PROJECT_ROOT/$KEY_PATH"
}

# Get current version
get_version() {
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        'docker exec openclaw-gateway openclaw --version 2>/dev/null || echo "unknown"'
}

# Manual update
do_update() {
    get_connection
    
    log_step "Checking current version..."
    CURRENT_VERSION=$(get_version)
    log_info "Current version: $CURRENT_VERSION"
    
    log_step "Restarting OpenClaw to fetch latest version..."
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        'sudo systemctl restart openclaw'
    
    log_info "Waiting for container to become healthy (~2-3 min)..."
    
    for i in {1..36}; do
        STATUS=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
            'docker ps --format "{{.Status}}" -f name=openclaw-gateway' 2>/dev/null)
        
        if [[ "$STATUS" == *"healthy"* ]]; then
            echo ""
            NEW_VERSION=$(get_version)
            
            if [[ "$NEW_VERSION" != "$CURRENT_VERSION" ]]; then
                log_success "Updated: $CURRENT_VERSION → $NEW_VERSION"
            else
                log_success "Already on latest version: $NEW_VERSION"
            fi
            return 0
        fi
        echo -n "."
        sleep 5
    done
    
    echo ""
    log_warning "Container still starting. Check logs with: ./scripts/logs.sh gateway"
}

# Enable auto-updates via cron
enable_auto_update() {
    get_connection
    
    log_step "Enabling auto-updates..."
    
    # Create update script on instance
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" 'cat > ~/update-openclaw.sh << '\''SCRIPT'\''
#!/bin/bash
# Auto-update OpenClaw
LOG="/var/log/openclaw-update.log"
echo "$(date): Starting update..." >> $LOG

# Get current version
OLD_VER=$(docker exec openclaw-gateway openclaw --version 2>/dev/null || echo "unknown")

# Restart to get latest
sudo systemctl restart openclaw

# Wait for healthy
for i in {1..36}; do
    STATUS=$(docker ps --format "{{.Status}}" -f name=openclaw-gateway 2>/dev/null)
    if [[ "$STATUS" == *"healthy"* ]]; then
        NEW_VER=$(docker exec openclaw-gateway openclaw --version 2>/dev/null || echo "unknown")
        if [[ "$NEW_VER" != "$OLD_VER" ]]; then
            echo "$(date): Updated $OLD_VER → $NEW_VER" >> $LOG
        else
            echo "$(date): Already latest: $NEW_VER" >> $LOG
        fi
        exit 0
    fi
    sleep 5
done
echo "$(date): Update timeout" >> $LOG
SCRIPT
chmod +x ~/update-openclaw.sh'

    # Add cron job (every 6 hours)
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        '(crontab -l 2>/dev/null | grep -v update-openclaw; echo "0 */6 * * * /home/ec2-user/update-openclaw.sh") | crontab -'
    
    log_success "Auto-updates enabled (every 6 hours)"
    log_info "Update log: /var/log/openclaw-update.log"
    log_info "To disable: ./scripts/update.sh --auto-disable"
}

# Disable auto-updates
disable_auto_update() {
    get_connection
    
    log_step "Disabling auto-updates..."
    
    ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        'crontab -l 2>/dev/null | grep -v update-openclaw | crontab - 2>/dev/null || true'
    
    log_success "Auto-updates disabled"
}

# Check status
check_status() {
    get_connection
    
    log_step "Update status"
    
    CURRENT_VERSION=$(get_version)
    echo "  Current version: $CURRENT_VERSION"
    
    # Check if auto-update is enabled
    AUTO_UPDATE=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
        'crontab -l 2>/dev/null | grep -c update-openclaw || echo 0')
    
    if [[ "$AUTO_UPDATE" -gt 0 ]]; then
        echo "  Auto-update: enabled (every 6 hours)"
        
        # Show last update
        LAST_UPDATE=$(ssh -i "$RESOLVED_KEY_PATH" -o StrictHostKeyChecking=no "ec2-user@$INSTANCE_IP" \
            'tail -1 /var/log/openclaw-update.log 2>/dev/null || echo "No updates yet"')
        echo "  Last update: $LAST_UPDATE"
    else
        echo "  Auto-update: disabled"
    fi
}

# Main
case "${1:-}" in
    --auto-enable)
        enable_auto_update
        ;;
    --auto-disable)
        disable_auto_update
        ;;
    --status)
        check_status
        ;;
    --help|-h)
        echo "OpenClaw Update Script"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Commands:"
        echo "  (no args)       Update to latest version now"
        echo "  --auto-enable   Enable automatic updates (every 6 hours)"
        echo "  --auto-disable  Disable automatic updates"
        echo "  --status        Show current version and auto-update status"
        echo ""
        ;;
    *)
        do_update
        ;;
esac
