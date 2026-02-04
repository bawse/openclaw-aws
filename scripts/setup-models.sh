#!/bin/bash
# =============================================================================
# Bedrock Model Enablement Script
# =============================================================================
# This script enables Claude models in your AWS account for use with Bedrock.
# Run this ONCE before deploying OpenClaw.
#
# Claude 4.5 models require a one-time "Marketplace" enablement which happens
# automatically on first invocation from credentials with appropriate permissions.
#
# Usage: ./scripts/setup-models.sh [--region REGION]
# =============================================================================

set -e

# Default region priority: --region flag > TF_VAR_aws_region > AWS_REGION > AWS CLI default > eu-west-1
REGION="${TF_VAR_aws_region:-${AWS_REGION:-}}"
if [[ -z "$REGION" ]]; then
    REGION=$(aws configure get region 2>/dev/null || echo "eu-west-1")
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}==>${NC} ${BOLD}$1${NC}"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --help|-h)
            echo "Bedrock Model Enablement Script"
            echo ""
            echo "Usage: $0 [--region REGION]"
            echo ""
            echo "Options:"
            echo "  --region    AWS region (auto-detected from AWS CLI config)"
            echo ""
            echo "This script enables Claude models for Bedrock by making a test"
            echo "invocation. Run this once before deploying OpenClaw."
            echo ""
            echo "Region is detected in this order:"
            echo "  1. --region flag"
            echo "  2. TF_VAR_aws_region environment variable"
            echo "  3. AWS_REGION environment variable"
            echo "  4. AWS CLI configured region"
            echo "  5. Default: eu-west-1"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Determine region prefix for inference profiles
get_region_prefix() {
    case "$1" in
        eu-*) echo "eu" ;;
        us-*) echo "us" ;;
        ap-*) echo "apac" ;;
        *)    echo "us" ;;  # Default to US for unknown regions
    esac
}

PROFILE_PREFIX=$(get_region_prefix "$REGION")

# Check if Claude 4.5 is available in this region
is_claude_45_available() {
    local prefix="$1"
    # Claude 4.5 is available in US and EU regions
    [[ "$prefix" == "us" || "$prefix" == "eu" ]]
}

# Define models based on region availability
declare -a MODEL_NAMES
declare -A MODELS

if is_claude_45_available "$PROFILE_PREFIX"; then
    MODEL_NAMES=("Claude Sonnet 4.5" "Claude 3.7 Sonnet" "Claude 3.5 Sonnet v2")
    MODELS["Claude Sonnet 4.5"]="${PROFILE_PREFIX}.anthropic.claude-sonnet-4-5-20250929-v1:0"
    MODELS["Claude 3.7 Sonnet"]="${PROFILE_PREFIX}.anthropic.claude-3-7-sonnet-20250219-v1:0"
    MODELS["Claude 3.5 Sonnet v2"]="${PROFILE_PREFIX}.anthropic.claude-3-5-sonnet-20241022-v2:0"
else
    # APAC and other regions: Claude 4.5 not available, use Claude 3.5
    MODEL_NAMES=("Claude 3.5 Sonnet v2" "Claude 3 Haiku")
    MODELS["Claude 3.5 Sonnet v2"]="${PROFILE_PREFIX}.anthropic.claude-3-5-sonnet-20241022-v2:0"
    MODELS["Claude 3 Haiku"]="${PROFILE_PREFIX}.anthropic.claude-3-haiku-20240307-v1:0"
fi

# Test payload
TEST_PAYLOAD='{"messages":[{"role":"user","content":[{"text":"Hi"}]}],"inferenceConfig":{"maxTokens":10}}'

# Check prerequisites
log_step "Checking prerequisites..."

if ! command -v aws &> /dev/null; then
    log_error "AWS CLI is not installed."
    exit 1
fi

if ! aws sts get-caller-identity &> /dev/null; then
    log_error "AWS credentials not configured or expired."
    exit 1
fi

IDENTITY=$(aws sts get-caller-identity --query 'Arn' --output text)
log_success "AWS credentials configured"
echo "         Account: $(aws sts get-caller-identity --query 'Account' --output text)"
echo ""

log_step "Region configuration"
echo "  Region: $REGION"
echo "  Inference profile prefix: $PROFILE_PREFIX"
if is_claude_45_available "$PROFILE_PREFIX"; then
    log_success "Claude 4.5 models available in this region"
else
    log_warning "Claude 4.5 models NOT available in $REGION"
    echo "         Using Claude 3.5 Sonnet as primary model"
fi
echo ""

# Create temp files
PAYLOAD_FILE=$(mktemp)
RESPONSE_FILE=$(mktemp)
trap "rm -f $PAYLOAD_FILE $RESPONSE_FILE" EXIT

echo "$TEST_PAYLOAD" > "$PAYLOAD_FILE"

# Track results
ENABLED_MODELS=()
FAILED_MODELS=()

log_step "Enabling models..."
echo ""

# Try to enable each model
for MODEL_NAME in "${MODEL_NAMES[@]}"; do
    MODEL_ID="${MODELS[$MODEL_NAME]}"
    
    echo -n "  $MODEL_NAME... "
    
    if aws bedrock-runtime invoke-model \
        --model-id "$MODEL_ID" \
        --body "file://$PAYLOAD_FILE" \
        --region "$REGION" \
        "$RESPONSE_FILE" 2>/dev/null; then
        
        # Check if we got a valid response
        if [[ -f "$RESPONSE_FILE" ]] && grep -q "content" "$RESPONSE_FILE" 2>/dev/null; then
            echo -e "${GREEN}enabled${NC}"
            ENABLED_MODELS+=("$MODEL_NAME")
        else
            echo -e "${YELLOW}unverified${NC}"
            ENABLED_MODELS+=("$MODEL_NAME (unverified)")
        fi
    else
        echo -e "${RED}failed${NC}"
        FAILED_MODELS+=("$MODEL_NAME")
    fi
done

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BOLD}                 SUMMARY${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ ${#ENABLED_MODELS[@]} -gt 0 ]]; then
    log_success "Enabled models:"
    for m in "${ENABLED_MODELS[@]}"; do
        echo "    • $m"
    done
    echo ""
fi

if [[ ${#FAILED_MODELS[@]} -gt 0 ]]; then
    log_warning "Failed to enable:"
    for m in "${FAILED_MODELS[@]}"; do
        echo "    • $m"
    done
    echo ""
    echo "  Some models may require AWS Marketplace permissions."
    echo "  Add these permissions to your IAM user if needed:"
    echo ""
    echo "    aws-marketplace:ViewSubscriptions"
    echo "    aws-marketplace:Subscribe"
    echo ""
fi

if [[ ${#ENABLED_MODELS[@]} -gt 0 ]]; then
    echo ""
    log_success "Ready to deploy! Run:"
    echo ""
    echo "    ./scripts/deploy.sh apply"
    echo ""
else
    log_error "No models were enabled. Please check your AWS permissions."
    exit 1
fi
