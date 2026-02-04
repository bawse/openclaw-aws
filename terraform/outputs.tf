output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openclaw.id
}

output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.openclaw.public_ip
}

output "instance_public_dns" {
  description = "Public DNS name of the EC2 instance"
  value       = aws_instance.openclaw.public_dns
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i .keys/${var.project_name}-${var.environment}-key.pem ec2-user@${aws_instance.openclaw.public_ip}"
}

output "ssh_private_key_path" {
  description = "Path to the SSH private key (relative to project root)"
  value       = ".keys/${var.project_name}-${var.environment}-key.pem"
}

output "gateway_url" {
  description = "OpenClaw Gateway URL (direct access)"
  value       = "http://${aws_instance.openclaw.public_ip}:18789"
}

output "gateway_url_ssh_tunnel" {
  description = "SSH tunnel command for secure Gateway access"
  value       = "ssh -i .keys/${var.project_name}-${var.environment}-key.pem -N -L 18789:127.0.0.1:18789 ec2-user@${aws_instance.openclaw.public_ip}"
}

output "aws_region" {
  description = "AWS region where resources are deployed"
  value       = var.aws_region
}

output "bedrock_model_primary" {
  description = "Primary Bedrock model ID (with region prefix)"
  value       = local.bedrock_model_primary_full
}

output "bedrock_model_fallback" {
  description = "Fallback Bedrock model ID (with region prefix)"
  value       = local.bedrock_model_fallback_full
}

output "bedrock_region_prefix" {
  description = "Inference profile region prefix"
  value       = local.region_prefix
}

output "model_availability_note" {
  description = "Note about model availability in this region"
  value       = local.model_availability_note
}

output "iam_role_arn" {
  description = "IAM role ARN for the EC2 instance"
  value       = aws_iam_role.openclaw.arn
}

output "gateway_token_command" {
  description = "Command to retrieve the gateway auth token from the instance"
  value       = "ssh -i .keys/${var.project_name}-${var.environment}-key.pem ec2-user@${aws_instance.openclaw.public_ip} 'cat ~/.openclaw/gateway-token.txt'"
}
