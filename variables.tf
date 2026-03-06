###############################################################################
# Root Variables
# Sensitive values (API keys) are injected via GitHub Actions secrets
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "openclaw-exp"
}

variable "vpc_cidr" {
  description = "CIDR block for the experiment VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ubuntu_ami_id" {
  description = "Ubuntu 24.04 LTS AMI ID (region-specific — update if changing region)"
  type        = string
  default     = "ami-0e86e20dae9224db8"  # Ubuntu 24.04 LTS us-east-1 as of 2026
}

variable "instance_type_api" {
  description = "Instance type for API-backed LLM VMs (Claude, OpenAI)"
  type        = string
  default     = "t3.small"
}

variable "instance_type_ollama" {
  description = "Instance type for Ollama VM (runs model locally — needs more RAM)"
  type        = string
  default     = "t3.large"
}

variable "ssh_public_key" {
  description = "SSH public key for EC2 key pair (optional — SSM is primary access method)"
  type        = string
  default     = ""
}

variable "inbox_site_url" {
  description = "URL of the static fake inbox site hosted on S3"
  type        = string
}

variable "messaging_api_domain" {
  description = "Messaging platform API domain for egress whitelist (e.g. api.telegram.org)"
  type        = string
  default     = "api.telegram.org"
}

# ── Secrets (injected from GitHub Actions — never hardcoded) ─────────────────

variable "anthropic_api_key" {
  description = "Anthropic API key — injected from GitHub secret ANTHROPIC_API_KEY"
  type        = string
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key — injected from GitHub secret OPENAI_API_KEY"
  type        = string
  sensitive   = true
}
