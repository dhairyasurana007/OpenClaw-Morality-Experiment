###############################################################################
# OpenClaw Self-Preservation Experiment - Infrastructure
#
# Provisions 4 isolated EC2 instances (Claude, GPT-4o, Ollama, Deepseek) in a private
# AWS VPC. Outbound internet access is strictly controlled via AWS Network
# Firewall - VMs can only reach whitelisted domains.
#
# Resources created:
#   Networking   - VPC, public/private/firewall subnets, IGW, route tables
#   Firewall     - AWS Network Firewall with domain whitelist
#   Monitoring   - VPC Flow Logs, Firewall logs -> CloudWatch
#   Per VM (x3)  - IAM role, security group, EC2 instance, CloudWatch log group
###############################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
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

# Public subnet - Internet Gateway and NAT Gateway live here
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 1) # 10.0.1.0/24
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project}-public-subnet" }
}

# Firewall subnet - Network Firewall endpoint lives here (between public and private)
resource "aws_subnet" "firewall" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 3) # 10.0.3.0/24
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.project}-firewall-subnet" }
}

# Private subnet - all VMs live here, no public IP
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

# NAT Gateway - sits in public subnet, gives firewall subnet outbound internet
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.project}-nat-gw" }
  depends_on    = [aws_internet_gateway.main]
}

###############################################################################
# AWS Network Firewall
# Domain-based egress filtering - VMs can ONLY reach whitelisted domains.
# Everything else is dropped and logged.
###############################################################################

locals {
  # RulesSourceList targets must be hostname only (no path/query).
  _inbox_url_noprefix = trimprefix(trimprefix(var.inbox_site_url, "https://"), "http://")
  inbox_firewall_host = split("?", split("/", local._inbox_url_noprefix)[0])[0]
}

resource "aws_networkfirewall_rule_group" "egress_whitelist" {
  name     = "${var.project}-egress-whitelist"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["HTTP_HOST", "TLS_SNI"]
        targets = [
          # Fake inbox static site (full URL kept in var for VMs; firewall needs host only)
          local.inbox_firewall_host,
          # LLM APIs
          "api.anthropic.com",
          "api.openai.com",
          "api.deepseek.com",
          # Ollama model pull on first boot only
          ".ollama.ai",
          ".ollama.com",
          # npm registry (openclaw install)
          "registry.npmjs.org",
          # Ubuntu package installs on first boot only (leading dot matches base domain + all subdomains)
          ".archive.ubuntu.com",
          ".security.ubuntu.com",
          ".nodesource.com",
          # SSM agent communication
          "ssm.${var.aws_region}.amazonaws.com",
          "ssmmessages.${var.aws_region}.amazonaws.com",
          "ec2messages.${var.aws_region}.amazonaws.com",
          # CloudWatch agent log shipping
          "logs.${var.aws_region}.amazonaws.com",
          "monitoring.${var.aws_region}.amazonaws.com",
        ]
      }
    }

    stateful_rule_options {
      # Must match firewall policy StatefulEngineOptions; required for stateful_default_actions (AWS API).
      rule_order = "STRICT_ORDER"
    }
  }

  tags = { Name = "${var.project}-egress-whitelist" }
}

resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${var.project}-firewall-policy"

  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    # StatefulDefaultActions (drop_established / alert_established) are only valid with strict rule order.
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.egress_whitelist.arn
      priority     = 1 # required when rule_order is STRICT_ORDER (lowest runs first)
    }

    # Drop everything not explicitly allowed
    stateful_default_actions = ["aws:drop_established", "aws:alert_established"]
  }

  tags = { Name = "${var.project}-firewall-policy" }
}

resource "aws_networkfirewall_firewall" "main" {
  name                = "${var.project}-firewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn
  vpc_id              = aws_vpc.main.id

  subnet_mapping {
    subnet_id = aws_subnet.firewall.id
  }

  tags = { Name = "${var.project}-firewall" }
}

# Extract the firewall endpoint ID from the sync states
locals {
  firewall_endpoint_id = tolist(tolist(aws_networkfirewall_firewall.main.firewall_status)[0].sync_states)[0].attachment[0].endpoint_id
}

###############################################################################
# Route tables
# Traffic flow: private subnet -> firewall endpoint -> NAT Gateway -> internet
###############################################################################

# Public subnet - routes to internet gateway
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

# Firewall subnet - routes to NAT Gateway (after firewall inspection)
resource "aws_route_table" "firewall" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "${var.project}-firewall-rt" }
}

resource "aws_route_table_association" "firewall" {
  subnet_id      = aws_subnet.firewall.id
  route_table_id = aws_route_table.firewall.id
}

# Private subnet - routes through Network Firewall endpoint
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block      = "0.0.0.0/0"
    vpc_endpoint_id = local.firewall_endpoint_id
  }
  tags = { Name = "${var.project}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

###############################################################################
# VPC Flow Logs -> CloudWatch
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  cw_log_flow_name     = "/aws/vpc/${var.project}-flow-logs"
  cw_log_firewall_name = "/aws/network-firewall/${var.project}-alerts"
  cw_log_claude_name   = "/openclaw/${var.project}/claude/gateway"
  cw_log_openai_name   = "/openclaw/${var.project}/openai/gateway"
  cw_log_ollama_name   = "/openclaw/${var.project}/ollama/gateway"
  cw_log_deepseek_name = "/openclaw/${var.project}/deepseek/gateway"
  cw_log_all_names = [
    local.cw_log_flow_name,
    local.cw_log_firewall_name,
    local.cw_log_claude_name,
    local.cw_log_openai_name,
    local.cw_log_ollama_name,
    local.cw_log_deepseek_name,
  ]
  # Same shape as aws_cloudwatch_log_group.arn for flow log destination
  cw_log_flow_arn = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.cw_log_flow_name}:*"
}

# aws_cloudwatch_log_group has no "ignore if exists". Bootstrap with AWS CLI so
# ResourceAlreadyExistsException does not fail apply. Requires bash + aws CLI during apply/destroy.
resource "null_resource" "cloudwatch_log_groups" {
  triggers = {
    names_pipe   = join("|", local.cw_log_all_names)
    region       = var.aws_region
    retention    = "30"
    project      = var.project
    module_path  = path.module # destroy provisioner may only reference self.* (stored in triggers)
  }

  provisioner "local-exec" {
    interpreter = var.local_exec_cloudwatch_bash
    command     = <<-EOT
set -e
"${path.module}/scripts/ensure-cw-log-groups.sh" "${var.aws_region}" 30 \
  "${local.cw_log_flow_name}" \
  "${local.cw_log_firewall_name}" \
  "${local.cw_log_claude_name}" \
  "${local.cw_log_openai_name}" \
  "${local.cw_log_ollama_name}" \
  "${local.cw_log_deepseek_name}"
EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["bash", "-c"]
    command     = "\"${self.triggers.module_path}/scripts/destroy-cw-log-groups.sh\" \"${self.triggers.region}\" \"${self.triggers.project}\""
  }
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
  depends_on      = [null_resource.cloudwatch_log_groups]
  vpc_id          = aws_vpc.main.id
  traffic_type    = "ALL"
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = local.cw_log_flow_arn
  tags            = { Name = "${var.project}-flow-log" }
}

# Network Firewall alert logs -> CloudWatch
resource "aws_networkfirewall_logging_configuration" "main" {
  depends_on   = [null_resource.cloudwatch_log_groups]
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    log_destination_config {
      log_destination = {
        logGroup = local.cw_log_firewall_name
      }
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
    }
  }
}

###############################################################################
# Security group - applied to all 4 VMs
# All inbound blocked. Outbound allowed to VPC only (firewall handles the rest)
###############################################################################

resource "aws_security_group" "vm" {
  name        = "${var.project}-vm-sg"
  description = "OpenClaw VMs - deny all inbound, outbound via Network Firewall"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound - filtered by Network Firewall domain whitelist"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-vm-sg" }
}

###############################################################################
# IAM - one role per VM, SSM access only
###############################################################################

#  Claude VM IAM Role

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

#  OpenAI VM IAM Role

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

#  Ollama VM IAM Role

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

#  Deepseek VM IAM Role

resource "aws_iam_role" "deepseek" {
  name = "${var.project}-deepseek-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "deepseek" {
  role       = aws_iam_role.deepseek.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "deepseek" {
  name = "${var.project}-deepseek-profile"
  role = aws_iam_role.deepseek.name
}



###############################################################################
# EC2 Instances
###############################################################################

# -- Claude VM -----------------------------------------------------------------

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
    http_tokens                 = "required"
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

# -- OpenAI VM -----------------------------------------------------------------

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

# -- Ollama VM -----------------------------------------------------------------

resource "aws_instance" "ollama" {
  ami                         = var.ubuntu_ami_id
  instance_type               = var.instance_type_ollama
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

# -- Deepseek VM ---------------------------------------------------------------

resource "aws_instance" "deepseek" {
  ami                         = var.ubuntu_ami_id
  instance_type               = var.instance_type_api
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.vm.id]
  iam_instance_profile        = aws_iam_instance_profile.deepseek.name
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
    vm_name      = "deepseek"
    llm_provider = "deepseek"
    llm_model    = "deepseek-chat"
    llm_api_key  = var.deepseek_api_key
    inbox_url    = var.inbox_site_url
  }))

  tags = { Name = "${var.project}-deepseek", LLM = "deepseek" }

  lifecycle { ignore_changes = [user_data] }
}
