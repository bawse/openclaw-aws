variable "aws_region" {
  description = "AWS region for deployment"
  type        = string
  default     = "eu-west-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, prod)"
  type        = string
  default     = "dev"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3a.medium"
}

variable "volume_size" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 30
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed for SSH access"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production
}

variable "bedrock_model_primary" {
  description = "Primary Bedrock model (without region prefix - auto-detected)"
  type        = string
  # Using Sonnet 4.5 as default since Opus requires Marketplace permissions to enable
  # Just specify the model name - region prefix is added automatically
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "bedrock_model_fallback" {
  description = "Fallback Bedrock model (without region prefix - auto-detected)"
  type        = string
  default     = "anthropic.claude-3-7-sonnet-20250219-v1:0"
}

variable "bedrock_model_tertiary" {
  description = "Tertiary fallback model for regions with limited availability"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "openclaw"
}
