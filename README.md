# openclaw-aws

Deploy [OpenClaw](https://docs.openclaw.ai/) on AWS with one command.

```bash
git clone https://github.com/bawse/openclaw-aws.git
cd openclaw-aws
./scripts/deploy.sh apply
```

The script handles everything: prerequisite checks, Bedrock model enablement, infrastructure deployment (~2 min), and opens your browser when ready (~3 min total).

**Cost:** ~$30/month infrastructure + Bedrock usage fees

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       AWS (eu-west-1)                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  EC2 (t3a.medium)                                     │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Docker → OpenClaw Gateway                      │  │  │
│  │  │  • Claude Sonnet 4.5 (primary)                  │  │  │
│  │  │  • Claude 3.7 Sonnet (fallback)                 │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  │  IAM Role ──────────────────────────► AWS Bedrock     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- **Terraform** >= 1.5.0
- **AWS CLI** configured with credentials

```bash
# macOS
brew install terraform awscli && aws configure

# Linux
sudo apt install -y terraform awscli && aws configure

# Windows
choco install terraform awscli && aws configure
```

## Commands

| Command | Description |
|---------|-------------|
| `./scripts/deploy.sh apply` | Deploy infrastructure |
| `./scripts/deploy.sh plan` | Preview changes |
| `./scripts/deploy.sh destroy` | Tear down everything |
| `./scripts/connect.sh` | Connect to OpenClaw |
| `./scripts/ssh.sh` | SSH into instance |
| `./scripts/logs.sh [gateway\|setup]` | View logs |

## Configuration

Set variables via environment or `terraform.tfvars`:

```bash
export TF_VAR_aws_region="us-east-1"
export TF_VAR_instance_type="t3.medium"
./scripts/deploy.sh apply
```

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `eu-west-1` | AWS region |
| `instance_type` | `t3a.medium` | EC2 instance type |
| `environment` | `dev` | Environment name (for resource naming) |
| `bedrock_model_primary` | `claude-sonnet-4-5` | Primary model |
| `allowed_ssh_cidrs` | `["0.0.0.0/0"]` | Allowed SSH IPs |

### Multiple Environments

Use unique `environment` values to run multiple instances:

```bash
TF_VAR_environment="staging" ./scripts/deploy.sh apply
```

## Bedrock Models

Region detection is automatic—just specify the model name:

| Region | Claude 4.5 | Default Model |
|--------|------------|---------------|
| `us-*` / `eu-*` | ✅ | Claude Sonnet 4.5 |
| `ap-*` | ❌ | Claude 3.5 Sonnet |

Models require one-time enablement per AWS account. The deploy script handles this automatically, or run `./scripts/setup-models.sh` manually.

## Security

Built-in protections:
- **Auth token**: Auto-generated 64-char token
- **Device pairing**: Browser approval required
- **IMDSv2**: Secure instance metadata

For production, restrict SSH access:

```bash
export TF_VAR_allowed_ssh_cidrs='["YOUR_IP/32"]'
```

## Troubleshooting

```bash
./scripts/logs.sh setup    # Check bootstrap logs
./scripts/logs.sh gateway  # Check OpenClaw logs
./scripts/ssh.sh           # SSH in to debug
```

If the gateway isn't responding, wait 2-3 minutes for initial setup to complete.

## License

MIT

## Links

- [OpenClaw Documentation](https://docs.openclaw.ai/)
- [OpenClaw Bedrock Guide](https://docs.openclaw.ai/bedrock)
- [AWS Bedrock Models](https://docs.aws.amazon.com/bedrock/latest/userguide/models-supported.html)
