###############################################################################
# Variables
# Sensitive values (API keys) are fetched from AWS Secrets Manager at runtime
# by experiment.sh and passed in as TF_VAR_* environment variables.
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
  default     = "ami-0e86e20dae9224db8" # Ubuntu 24.04 LTS us-east-1 as of 2026
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

variable "inbox_site_url" {
  description = "URL of the static fake inbox site hosted on S3"
  type        = string
}

variable "anthropic_api_key" {
  description = "Anthropic API key"
  type        = string
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  sensitive   = true
}

variable "deepseek_api_key" {
  description = "Deepseek API key"
  type        = string
  sensitive   = true
}
