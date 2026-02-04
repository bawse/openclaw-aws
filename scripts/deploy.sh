#!/bin/bash
# =============================================================================
# OpenClaw Deployment Script
# =============================================================================
# This script handles the complete deployment of OpenClaw to AWS.
# Usage: ./scripts/deploy.sh [apply|plan|destroy|status]
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
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"
}

# Check prerequisites with helpful install instructions
check_prerequisites() {
    log_step "Checking prerequisites..."
    local missing=0
    
    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform is not installed."
        echo ""
        echo "  Install Terraform:"
        echo "    macOS:   brew install terraform"
        echo "    Linux:   sudo apt install terraform  (or see https://terraform.io/downloads)"
        echo "    Windows: choco install terraform"
        echo ""
        missing=1
    else
        TERRAFORM_VERSION=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4 || terraform version | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        log_success "Terraform $TERRAFORM_VERSION"
    fi
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI is not installed."
        echo ""
        echo "  Install AWS CLI:"
        echo "    macOS:   brew install awscli"
        echo "    Linux:   sudo apt install awscli  (or see https://aws.amazon.com/cli/)"
        echo "    Windows: choco install awscli"
        echo ""
        missing=1
    else
        AWS_VERSION=$(aws --version 2>&1 | cut -d' ' -f1 | cut -d'/' -f2)
        log_success "AWS CLI $AWS_VERSION"
    fi
    
    if [[ $missing -eq 1 ]]; then
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS credentials are not configured or expired."
        echo ""
        echo "  Configure AWS credentials:"
        echo "    aws configure"
        echo ""
        exit 1
    fi
    
    AWS_ACCOUNT=$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null)
    AWS_REGION=$(aws configure get region 2>/dev/null || echo "not set")
    log_success "AWS Account: $AWS_ACCOUNT (region: $AWS_REGION)"
}

# Get the deployment region
get_deploy_region() {
    # Priority: TF_VAR > AWS_REGION > AWS CLI default > eu-west-1
    local region="${TF_VAR_aws_region:-${AWS_REGION:-}}"
    if [[ -z "$region" ]]; then
        region=$(aws configure get region 2>/dev/null || echo "eu-west-1")
    fi
    echo "$region"
}

# Get the region prefix for inference profiles
get_region_prefix() {
    case "$1" in
        eu-*) echo "eu" ;;
        us-*) echo "us" ;;
        ap-*) echo "apac" ;;
        *)    echo "us" ;;
    esac
}

# Check if Claude 4.5 is available in this region
is_claude_45_available() {
    local prefix="$1"
    [[ "$prefix" == "us" || "$prefix" == "eu" ]]
}

# Check if Bedrock models are enabled
check_bedrock_models() {
    log_step "Checking Bedrock model access..."
    
    local REGION=$(get_deploy_region)
    local PROFILE_PREFIX=$(get_region_prefix "$REGION")
    
    # Choose the right model to test based on region
    local MODEL_ID
    if is_claude_45_available "$PROFILE_PREFIX"; then
        MODEL_ID="${PROFILE_PREFIX}.anthropic.claude-sonnet-4-5-20250929-v1:0"
    else
        MODEL_ID="${PROFILE_PREFIX}.anthropic.claude-3-5-sonnet-20241022-v2:0"
    fi
    
    local TEST_PAYLOAD='{"messages":[{"role":"user","content":[{"text":"Hi"}]}],"inferenceConfig":{"maxTokens":10}}'
    
    # Quick test to see if model is accessible
    local TEMP_FILE=$(mktemp)
    local RESPONSE_FILE=$(mktemp)
    echo "$TEST_PAYLOAD" > "$TEMP_FILE"
    
    log_info "Region: $REGION (prefix: $PROFILE_PREFIX)"
    
    if ! is_claude_45_available "$PROFILE_PREFIX"; then
        log_warning "Claude 4.5 not available in $REGION, will use Claude 3.5 Sonnet"
    fi
    
    if aws bedrock-runtime invoke-model \
        --model-id "$MODEL_ID" \
        --body "file://$TEMP_FILE" \
        --region "$REGION" \
        "$RESPONSE_FILE" &>/dev/null; then
        log_success "Bedrock models enabled"
        rm -f "$TEMP_FILE" "$RESPONSE_FILE"
        return 0
    else
        rm -f "$TEMP_FILE" "$RESPONSE_FILE"
        log_warning "Bedrock models may not be enabled yet"
        echo ""
        read -p "Would you like to enable Bedrock models now? (y/n): " enable_models
        if [[ "$enable_models" == "y" || "$enable_models" == "Y" ]]; then
            log_info "Running model enablement..."
            "$SCRIPT_DIR/setup-models.sh" --region "$REGION"
        else
            log_warning "Skipping model enablement. You can run ./scripts/setup-models.sh later."
        fi
    fi
}

# Initialize Terraform
init_terraform() {
    log_step "Initializing Terraform..."
    cd "$TERRAFORM_DIR"
    terraform init -upgrade -input=false
    log_success "Terraform initialized"
}

# Show cost estimate
show_cost_estimate() {
    echo ""
    echo -e "${BOLD}Estimated Monthly Cost:${NC}"
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │ EC2 (t3a.medium, on-demand):        ~\$27/month     │"
    echo "  │ EBS (30GB gp3):                      ~\$2/month     │"
    echo "  │ Data transfer:                       ~\$1/month     │"
    echo "  │ ─────────────────────────────────────────────────── │"
    echo "  │ Infrastructure total:               ~\$30/month     │"
    echo "  │                                                     │"
    echo "  │ Bedrock (Claude Sonnet 4.5):     usage-based        │"
    echo "  │   Input:  \$3.00 / 1M tokens                        │"
    echo "  │   Output: \$15.00 / 1M tokens                       │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo ""
}

# Plan deployment
plan() {
    check_prerequisites
    init_terraform
    
    log_step "Creating Terraform plan..."
    terraform plan -out=tfplan
    
    show_cost_estimate
    
    log_success "Plan created. Review above and run: ./scripts/deploy.sh apply"
}

# Wait for gateway to be healthy
wait_for_gateway() {
    local INSTANCE_IP="$1"
    local MAX_ATTEMPTS=60  # 5 minutes max
    local ATTEMPT=0
    
    log_step "Waiting for gateway to be ready..."
    echo -n "  "
    
    while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
        if curl -s --connect-timeout 2 "http://$INSTANCE_IP:18789/health" &> /dev/null; then
            echo ""
            log_success "Gateway is healthy!"
            return 0
        fi
        echo -n "."
        sleep 5
        ((ATTEMPT++))
    done
    
    echo ""
    log_warning "Gateway not responding after 5 minutes. Check logs with: ./scripts/logs.sh setup"
    return 1
}

# Get and display gateway token
display_access_info() {
    local INSTANCE_IP="$1"
    local KEY_PATH="$2"
    
    log_step "Retrieving gateway token..."
    
    # Get the token from the instance
    local TOKEN=$(ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "ec2-user@$INSTANCE_IP" 'cat ~/.openclaw/gateway-token.txt' 2>/dev/null || echo "")
    
    if [[ -z "$TOKEN" ]]; then
        log_warning "Could not retrieve token automatically. Get it manually:"
        echo "  ./scripts/ssh.sh 'cat ~/.openclaw/gateway-token.txt'"
        return
    fi
    
    echo ""
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  🚀 OpenClaw is ready!${NC}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${BOLD}Access URL (via SSH tunnel - recommended):${NC}"
    echo ""
    echo -e "  ${CYAN}http://localhost:18789?token=${TOKEN}${NC}"
    echo ""
    echo -e "${BOLD}Instance IP:${NC} $INSTANCE_IP"
    echo ""
    
    # Optionally copy to clipboard
    if command -v pbcopy &> /dev/null; then
        echo "http://localhost:18789?token=$TOKEN" | pbcopy
        log_success "URL copied to clipboard (macOS)"
    elif command -v xclip &> /dev/null; then
        echo "http://localhost:18789?token=$TOKEN" | xclip -selection clipboard
        log_success "URL copied to clipboard (Linux)"
    fi
    
    echo ""
    read -p "Open OpenClaw in browser now? (Y/n): " open_now
    if [[ "$open_now" != "n" && "$open_now" != "N" ]]; then
        "$SCRIPT_DIR/connect.sh"
    else
        echo ""
        echo "To connect later, run:"
        echo "  ./scripts/connect.sh"
        echo ""
    fi
}

# Apply deployment
apply() {
    check_prerequisites
    check_bedrock_models
    init_terraform
    
    # Create .keys directory if it doesn't exist
    mkdir -p "$PROJECT_ROOT/.keys"
    
    log_step "Deploying infrastructure..."
    
    if [[ -f "$TERRAFORM_DIR/tfplan" ]]; then
        terraform apply tfplan
        rm -f "$TERRAFORM_DIR/tfplan"
    else
        terraform apply -auto-approve
    fi
    
    log_success "Infrastructure deployed!"
    
    # Get outputs
    local INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")
    local KEY_PATH=$(terraform output -raw ssh_private_key_path 2>/dev/null || echo "")
    local FULL_KEY_PATH="$PROJECT_ROOT/$KEY_PATH"
    
    # Copy SSH key to ~/.ssh for convenience
    if [[ -n "$KEY_PATH" && -f "$FULL_KEY_PATH" ]]; then
        local KEY_NAME=$(basename "$KEY_PATH")
        cp "$FULL_KEY_PATH" "$HOME/.ssh/$KEY_NAME"
        chmod 600 "$HOME/.ssh/$KEY_NAME"
        log_success "SSH key saved to ~/.ssh/$KEY_NAME"
    fi
    
    # Wait for gateway and display access info
    if [[ -n "$INSTANCE_IP" ]]; then
        wait_for_gateway "$INSTANCE_IP"
        display_access_info "$INSTANCE_IP" "$FULL_KEY_PATH"
    fi
}

# Plan destruction (preview what will be destroyed)
destroy_plan() {
    check_prerequisites
    init_terraform
    
    log_step "Planning destruction (no changes will be made)..."
    terraform plan -destroy
    log_warning "To actually destroy, run: ./scripts/deploy.sh destroy"
}

# Destroy deployment
destroy() {
    check_prerequisites
    cd "$TERRAFORM_DIR"
    
    echo ""
    log_warning "This will destroy all OpenClaw infrastructure!"
    echo ""
    echo "  Resources to be destroyed:"
    echo "    - EC2 instance"
    echo "    - Security group"
    echo "    - IAM role and policies"
    echo "    - SSH key pair"
    echo ""
    read -p "Type 'yes' to confirm destruction: " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        log_step "Destroying infrastructure..."
        terraform destroy -auto-approve
        log_success "Infrastructure destroyed"
        echo ""
        log_info "All AWS resources have been removed. Local SSH keys remain in .keys/"
    else
        log_info "Destroy cancelled"
    fi
}

# Show status
status() {
    check_prerequisites
    cd "$TERRAFORM_DIR"
    
    if [[ ! -f "terraform.tfstate" ]]; then
        log_warning "No Terraform state found. Run ./scripts/deploy.sh apply first."
        exit 0
    fi
    
    log_step "Current deployment status:"
    echo ""
    terraform output
    
    # Check if instance is running
    INSTANCE_IP=$(terraform output -raw instance_public_ip 2>/dev/null || echo "")
    if [[ -n "$INSTANCE_IP" ]]; then
        echo ""
        log_info "Checking Gateway health..."
        if curl -s --connect-timeout 5 "http://$INSTANCE_IP:18789/health" &> /dev/null; then
            log_success "Gateway is healthy at http://$INSTANCE_IP:18789"
        else
            log_warning "Gateway not responding (may still be starting up)"
        fi
    fi
}

# Main
case "${1:-}" in
    plan)
        plan
        ;;
    apply)
        apply
        ;;
    destroy-plan)
        destroy_plan
        ;;
    destroy)
        destroy
        ;;
    status)
        status
        ;;
    *)
        echo ""
        echo -e "${BOLD}OpenClaw AWS Deployment${NC}"
        echo ""
        echo "Usage: $0 <command>"
        echo ""
        echo "Commands:"
        echo "  plan          Preview infrastructure changes (with cost estimate)"
        echo "  apply         Deploy OpenClaw to AWS"
        echo "  destroy-plan  Preview what will be destroyed"
        echo "  destroy       Tear down all infrastructure"
        echo "  status        Show current deployment status"
        echo ""
        echo "Quick Start:"
        echo "  ./scripts/deploy.sh apply"
        echo ""
        exit 1
        ;;
esac
