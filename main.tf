###############################################################################
# OpenClaw Self-Preservation Experiment — Infrastructure
#
# Provisions 3 isolated EC2 instances (Claude, GPT-4o, Ollama) in a private
# AWS VPC. All VMs share the same networking stack but are fully isolated
# from each other — separate IAM roles, security groups, and log groups.
#
# Resources created:
#   Networking  — VPC, public/private subnets, IGW, NAT Gateway, route tables
#   Monitoring  — VPC Flow Logs → CloudWatch
#   Per VM (x3) — IAM role, security group, EC2 instance, CloudWatch log group
###############################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "openclaw-experiment"
      ManagedBy   = "terraform"
      Environment = "experiment"
    }
  }
}

###############################################################################
# Networking
###############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.project}-vpc" }
}

# Public subnet — NAT Gateway lives here
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # 10.0.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-subnet" }
}

# Private subnet — all VMs live here, no public IP
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 2) # 10.0.2.0/24
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.project}-private-subnet" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

# NAT Gateway sits in the public subnet so private VMs can reach the internet
# outbound (for LLM API calls) without being reachable inbound
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project}-nat-gw" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# VPC Flow Logs → CloudWatch
# Captures all network traffic for post-experiment analysis
###############################################################################

resource "aws_cloudwatch_log_group" "flow_logs" {
  name              = "/aws/vpc/${var.project}-flow-logs"
  retention_in_days = 30
  tags              = { Name = "${var.project}-flow-logs" }
}

resource "aws_iam_role" "flow_logs" {
  name = "${var.project}-flow-logs-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "${var.project}-flow-logs-policy"
  role = aws_iam_role.flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "main" {
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs.arn
  tags            = { Name = "${var.project}-flow-log" }
}

###############################################################################
# Shared security group — applied to all 3 VMs
# Deny ALL inbound. Allow outbound HTTPS, HTTP (bootstrap only), DNS.
###############################################################################

resource "aws_security_group" "vm" {
  name        = "${var.project}-vm-sg"
  description = "OpenClaw VMs — deny all inbound, allow outbound HTTPS/DNS"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "HTTPS — LLM API calls"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP — apt package installs on first boot"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vm-sg" }
}

###############################################################################
# IAM — one role per VM, SSM access only
# No EC2, S3, or Secrets Manager permissions — VMs cannot touch other AWS
# resources even if OpenClaw is compromised via prompt injection
###############################################################################

# ── Claude VM ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "claude" {
  name = "${var.project}-claude-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "claude" {
  role       = aws_iam_role.claude.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "claude" {
  name = "${var.project}-claude-profile"
  role = aws_iam_role.claude.name
}

# ── OpenAI VM ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "openai" {
  name = "${var.project}-openai-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "openai" {
  role       = aws_iam_role.openai.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "openai" {
  name = "${var.project}-openai-profile"
  role = aws_iam_role.openai.name
}

# ── Ollama VM ─────────────────────────────────────────────────────────────────

resource "aws_iam_role" "ollama" {
  name = "${var.project}-ollama-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ollama" {
  role       = aws_iam_role.ollama.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ollama" {
  name = "${var.project}-ollama-profile"
  role = aws_iam_role.ollama.name
}

###############################################################################
# EC2 Instances
###############################################################################

# ── Claude VM ─────────────────────────────────────────────────────────────────

resource "aws_instance" "claude" {
  ami                         = var.ubuntu_ami_id
  instance_type               = var.instance_type_api
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.claude.name
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 — blocks metadata SSRF
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    vm_name      = "claude"
    llm_provider = "anthropic"
    llm_model    = "claude-opus-4-6"
    llm_api_key  = var.anthropic_api_key
    inbox_url    = var.inbox_site_url
  }))

  tags = { Name = "${var.project}-claude", LLM = "claude" }

  lifecycle { ignore_changes = [user_data] }
}

resource "aws_cloudwatch_log_group" "claude" {
  name              = "/openclaw/claude/gateway"
  retention_in_days = 30
  tags              = { Name = "${var.project}-claude-logs" }
}

# ── OpenAI VM ─────────────────────────────────────────────────────────────────

resource "aws_instance" "openai" {
  ami                         = var.ubuntu_ami_id
  instance_type               = var.instance_type_api
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.openai.name
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    vm_name      = "openai"
    llm_provider = "openai"
    llm_model    = "gpt-4o"
    llm_api_key  = var.openai_api_key
    inbox_url    = var.inbox_site_url
  }))

  tags = { Name = "${var.project}-openai", LLM = "openai" }

  lifecycle { ignore_changes = [user_data] }
}

resource "aws_cloudwatch_log_group" "openai" {
  name              = "/openclaw/openai/gateway"
  retention_in_days = 30
  tags              = { Name = "${var.project}-openai-logs" }
}

# ── Ollama VM ─────────────────────────────────────────────────────────────────

resource "aws_instance" "ollama" {
  ami                         = var.ubuntu_ami_id
  instance_type               = var.instance_type_ollama # t3.large — runs model locally
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.ollama.name
  associate_public_ip_address = false

  root_block_device {
    volume_size           = 20
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    vm_name      = "ollama"
    llm_provider = "ollama"
    llm_model    = "llama3.1"
    llm_api_key  = ""
    inbox_url    = var.inbox_site_url
  }))

  tags = { Name = "${var.project}-ollama", LLM = "ollama" }

  lifecycle { ignore_changes = [user_data] }
}

resource "aws_cloudwatch_log_group" "ollama" {
  name              = "/openclaw/ollama/gateway"
  retention_in_days = 30
  tags              = { Name = "${var.project}-ollama-logs" }
}
