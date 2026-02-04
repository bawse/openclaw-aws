# =============================================================================
# OpenClaw AWS Infrastructure
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # -----------------------------------------------------------------------------
  # Region-aware Bedrock Model Configuration
  # -----------------------------------------------------------------------------
  # Inference profiles require region-specific prefixes:
  #   eu-* regions  → "eu."
  #   us-* regions  → "us."
  #   ap-* regions  → "apac."
  #
  # Model availability varies by region. Claude 4.5 models may not be available
  # in all regions, so we provide fallbacks.
  # -----------------------------------------------------------------------------

  # Determine the inference profile prefix based on region
  region_prefix = (
    startswith(var.aws_region, "eu-") ? "eu" :
    startswith(var.aws_region, "us-") ? "us" :
    startswith(var.aws_region, "ap-") ? "apac" :
    "us"  # Default to US for unknown regions
  )

  # Model availability by region category
  # Claude 4.5 models are available in US and EU, but may have limited availability in APAC
  claude_45_available = contains(["us", "eu"], local.region_prefix)

  # Compute full model IDs with region prefix
  # If Claude 4.5 is not available, fall back to Claude 3.5 Sonnet
  bedrock_model_primary_full = (
    local.claude_45_available
    ? "${local.region_prefix}.${var.bedrock_model_primary}"
    : "${local.region_prefix}.${var.bedrock_model_tertiary}"
  )

  bedrock_model_fallback_full = (
    local.claude_45_available
    ? "${local.region_prefix}.${var.bedrock_model_fallback}"
    : "${local.region_prefix}.${var.bedrock_model_tertiary}"
  )

  # For display/output purposes
  model_availability_note = (
    local.claude_45_available
    ? "Claude 4.5 models available"
    : "Claude 4.5 not available in ${var.aws_region}, using Claude 3.5 Sonnet"
  )
}

# -----------------------------------------------------------------------------
# SSH Key Pair
# -----------------------------------------------------------------------------

resource "tls_private_key" "openclaw" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "openclaw" {
  key_name   = "${local.name_prefix}-key"
  public_key = tls_private_key.openclaw.public_key_openssh

  tags = {
    Name = "${local.name_prefix}-key"
  }
}

resource "local_file" "private_key" {
  content         = tls_private_key.openclaw.private_key_openssh
  filename        = "${path.module}/../.keys/${local.name_prefix}-key.pem"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content         = tls_private_key.openclaw.public_key_openssh
  filename        = "${path.module}/../.keys/${local.name_prefix}-key.pub"
  file_permission = "0644"
}

# -----------------------------------------------------------------------------
# IAM Role for EC2 (Bedrock Access)
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "openclaw" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "${local.name_prefix}-ec2-role"
  }
}

# Bedrock permissions
data "aws_iam_policy_document" "bedrock_access" {
  statement {
    sid    = "BedrockModelAccess"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:ListFoundationModels",
      "bedrock:ListInferenceProfiles",
      "bedrock:GetInferenceProfile"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "bedrock_access" {
  name   = "${local.name_prefix}-bedrock-access"
  role   = aws_iam_role.openclaw.id
  policy = data.aws_iam_policy_document.bedrock_access.json
}

resource "aws_iam_instance_profile" "openclaw" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.openclaw.name

  tags = {
    Name = "${local.name_prefix}-instance-profile"
  }
}

# -----------------------------------------------------------------------------
# Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "openclaw" {
  name        = "${local.name_prefix}-sg"
  description = "Security group for OpenClaw EC2 instance"

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # OpenClaw Gateway (optional - for direct access)
  ingress {
    description = "OpenClaw Gateway"
    from_port   = 18789
    to_port     = 18789
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Outbound traffic
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance
# -----------------------------------------------------------------------------

# Get latest Amazon Linux 2023 AMI
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "openclaw" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.openclaw.key_name
  iam_instance_profile   = aws_iam_instance_profile.openclaw.name
  vpc_security_group_ids = [aws_security_group.openclaw.id]

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true

    tags = {
      Name = "${local.name_prefix}-root-volume"
    }
  }

  # Allow Docker containers to access IMDS for AWS credentials
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # IMDSv2
    http_put_response_hop_limit = 2           # Allow containers to reach IMDS
    instance_metadata_tags      = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    aws_region             = var.aws_region
    bedrock_model_primary  = local.bedrock_model_primary_full
    bedrock_model_fallback = local.bedrock_model_fallback_full
  }))

  tags = {
    Name = "${local.name_prefix}-instance"
  }

  # Ensure instance profile is created before instance
  depends_on = [aws_iam_instance_profile.openclaw]
}
