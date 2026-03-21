#!/bin/bash
###############################################################################
# OpenClaw Self-Preservation Experiment — Single Command Runner
#
# Usage:   ./experiment.sh
# Prompts: edit experiment_prompts.conf
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
RESULTS_DIR="${SCRIPT_DIR}/results/${TIMESTAMP}"
REPORT_FILE="${RESULTS_DIR}/experiment_report.md"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROMPTS_FILE="${SCRIPT_DIR}/experiment_prompts.conf"

STEP_WAIT=45
SHUTDOWN_WAIT=60
SSM_POLL_INTERVAL=15
SSM_MAX_WAIT=600

# AWS Secrets Manager secret names — update these if you used different names
SECRET_ANTHROPIC="openclaw/anthropic_api_key"
SECRET_OPENAI="openclaw/openai_api_key"
SECRET_INBOX_URL="openclaw/inbox_site_url"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BOLD}[$(date +%H:%M:%S)]${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $*"; }
err()     { echo -e "${RED}✗${NC} $*"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}\n"; }

# Preflight wizard

preflight_wizard() {
  echo -e "${CYAN}${BOLD}Before we begin, here's what this script will provision:${NC}\n"

  # Architecture diagram
  echo -e "${CYAN}${BOLD}AWS Architecture:${NC}\n"
  echo "+-----------------------------------------------------------------+"
  echo "|  VPC  10.0.0.0/16                                               |"
  echo "|                                                                 |"
  echo "|  +-----------------------------------------+                    |"
  echo "|  | Public Subnet  10.0.1.0/24              |                    |"
  echo "|  |   [Internet Gateway]   <- internet exit |                    |"
  echo "|  |   [NAT Gateway]        <- outbound only |                    |"
  echo "|  |   [Elastic IP]                          |                    |"
  echo "|  +--------------------+--------------------+                    |"
  echo "|                       | allowed only                            |"
  echo "|  +--------------------v-------------------+                     |"
  echo "|  | Firewall Subnet  10.0.3.0/24           |                     |"
  echo "|  |   [AWS Network Firewall]               | <- domain whitelist |"
  echo "|  |     ALLOW: fake email inbox S3 URL     |    blocks all other |"
  echo "|  |     ALLOW: api.anthropic.com           |    outbound traffic |"
  echo "|  |     ALLOW: api.openai.com              |                     |"
  echo "|  |     ALLOW: registry.ollama.ai          |                     |"
  echo "|  |     ALLOW: AWS service endpoints       |                     |"
  echo "|  |     DROP:  everything else             |                     |"
  echo "|  +--------------------+-------------------+                     |"
  echo "|                       | inspected traffic                       |"
  echo "|  +--------------------v------------------------------------+    |"
  echo "|  | Private Subnet  10.0.2.0/24  (no public IPs)            |    |"
  echo "|  |                                                         |    |"
  echo "|  |   +-------------+  +-------------+  +-----------------+ |    |"
  echo "|  |   | EC2 t3.small|  | EC2 t3.small|  |  EC2 t3.large   | |    |"
  echo "|  |   |   Claude    |  |   GPT-4o    |  |    Ollama       | |    |"
  echo "|  |   +-------------+  +-------------+  +-----------------+ |    |"
  echo "|  +---------------------------------------------------------+    |"
  echo "|                                                                 |"
  echo "|   [VPC Flow Logs]    -> [CloudWatch Log Groups]                 |"
  echo "|   [Firewall Alerts]  -> [CloudWatch Log Groups]                 |"
  echo "+-----------------------------------------------------------------+"
  echo    ""
  echo    "  [Secrets Manager]  ← stores your API keys"
  echo    "  [SSM Session Manager]  ← shell access to VMs"
  echo    ""
  echo -e "${YELLOW}    VMs are LEFT RUNNING after the experiment.${NC}"
  echo -e "${YELLOW}    Run 'terraform destroy' when done to stop billing.${NC}"
  # echo ""
  # read -rp "  Do you have an AWS account configured and want to proceed? [y/N] " aws_confirm
  echo ""
  
  first_attempt=true
  while true; do
    if [[ "$first_attempt" == "true" ]]; then
      read -rp "  Do you have an AWS account configured and want to proceed? [y/N] " aws_confirm
      first_attempt=false
    fi

    if [[ "$aws_confirm" =~ ^[Yy]$ ]]; then
      break

    elif [[ "$aws_confirm" =~ ^[Nn]$ ]]; then
      echo -e "${YELLOW}Exiting"
      exit 0

    else
      echo -e "Input '${aws_confirm}' not recognized. Please enter y or n."
      read -rp "  Do you have an AWS account configured and want to proceed? [y/N] " aws_confirm
    fi
  done

  # ── Verify AWS CLI is actually authenticated ───────────────────────────────
  if ! aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null; then
    err "AWS CLI is not authenticated. Run 'aws configure' and try again."
    echo -e '     If aws configure does NOT work, follow the instructions here:'
    echo -e '     https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'
    exit 1
  fi
  success "AWS CLI authenticated as: $(aws sts get-caller-identity --query 'Arn' --output text)"
  echo ""

  # ── Secrets setup ─────────────────────────────────────────────────────────
  echo -e "${BOLD}Secrets setup${NC}"
  echo    "  This experiment requires 3 secrets stored in AWS Secrets Manager."
  echo -e "  Let's check if they exist and help you create any that are missing.\n"

  local secrets_missing=0

  check_or_create_secret() {
    local secret_id="$1"
    local label="$2"
    local hint="$3"

    if aws secretsmanager describe-secret --secret-id "$secret_id" --region "$AWS_REGION" &>/dev/null; then
      success "${label} — already exists (${secret_id})"
    else
      warn "${label} not found (${secret_id})"
      echo -e "  ${hint}\n"
      read -rsp "  Enter value (input hidden): " secret_value
      echo ""
      if [[ -z "$secret_value" ]]; then
        err "Value cannot be empty. Skipping — experiment will fail at runtime."
        secrets_missing=$((secrets_missing + 1))
      else
        aws secretsmanager create-secret \
          --name "$secret_id" \
          --secret-string "$secret_value" \
          --region "$AWS_REGION" &>/dev/null \
          && success "Created secret: ${secret_id}" \
          || { err "Failed to create secret: ${secret_id}"; secrets_missing=$((secrets_missing + 1)); }
      fi
      echo ""
    fi
  }

  check_or_create_secret \
    "$SECRET_ANTHROPIC" \
    "Anthropic API key" \
    "Get yours at https://console.anthropic.com — starts with 'sk-ant-'"

  check_or_create_secret \
    "$SECRET_OPENAI" \
    "OpenAI API key" \
    "Get yours at https://platform.openai.com/api-keys — starts with 'sk-'"

  check_or_create_secret \
    "$SECRET_INBOX_URL" \
    "Inbox site URL" \
    "S3 static site URL hosting the fake inbox (e.g. http://your-bucket.s3-website-us-east-1.amazonaws.com)"

  if [[ $secrets_missing -gt 0 ]]; then
    err "${secrets_missing} secret(s) missing. Fix them and re-run."
    exit 1
  fi

  echo ""
  success "All secrets ready. Starting experiment...\n"
  sleep 1
}

# ── Preflight ─────────────────────────────────────────────────────────────────

check_deps() {
  local missing=()
  for cmd in terraform aws jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] && { err "Missing: ${missing[*]}"; exit 1; }
  [[ ! -f "$PROMPTS_FILE" ]] && { err "experiment_prompts.conf not found at ${PROMPTS_FILE}"; exit 1; }
}

load_secrets() {
  log "Fetching secrets from AWS Secrets Manager..."

  local fetch_secret
  fetch_secret() {
    aws secretsmanager get-secret-value \
      --region "$AWS_REGION" \
      --secret-id "$1" \
      --query SecretString \
      --output text 2>/dev/null || { err "Failed to fetch secret: $1"; exit 1; }
  }

  export TF_VAR_anthropic_api_key=$(fetch_secret "$SECRET_ANTHROPIC")
  export TF_VAR_openai_api_key=$(fetch_secret "$SECRET_OPENAI")
  export TF_VAR_inbox_site_url=$(fetch_secret "$SECRET_INBOX_URL")

  success "Secrets loaded"
}

load_prompts() {
  # shellcheck source=experiment_prompts.conf
  source "$PROMPTS_FILE"

  # Substitute INBOX_URL and LOG_URL placeholders
  local log_url="${INBOX_URL%/*}/nortecorp-prod-incident.log"
  PROMPT_1="${PROMPT_1//INBOX_URL/$INBOX_URL}"
  PROMPT_2="${PROMPT_2//LOG_URL/$log_url}"
}

# ── SSM helpers ───────────────────────────────────────────────────────────────

ssm_run() {
  local instance_id="$1" command="$2" timeout="${3:-30}"
  local cmd_id status elapsed=0

  cmd_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$command\"]" \
    --timeout-seconds "$timeout" \
    --query "Command.CommandId" \
    --output text)

  status="InProgress"
  while [[ "$status" == "InProgress" || "$status" == "Pending" ]]; do
    sleep 3; elapsed=$((elapsed + 3))
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ $elapsed -ge $timeout ]] && break
  done

  aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo ""
}

wait_for_vm() {
  local name="$1" instance_id="$2" elapsed=0
  log "Waiting for ${name} (${instance_id})..."

  while [[ $elapsed -lt $SSM_MAX_WAIT ]]; do
    local ping
    ping=$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")

    if [[ "$ping" == "Online" ]]; then
      local svc
      svc=$(ssm_run "$instance_id" "systemctl is-active openclaw 2>/dev/null || echo inactive" 20)
      [[ "$svc" == *"active"* ]] && { success "${name} ready"; return 0; }
    fi

    sleep "$SSM_POLL_INTERVAL"
    elapsed=$((elapsed + SSM_POLL_INTERVAL))
    log "${name}: still waiting... (${elapsed}s)"
  done

  err "${name} did not become ready within ${SSM_MAX_WAIT}s"; return 1
}

openclaw_send() {
  local instance_id="$1" message="$2"
  local escaped="${message//\"/\\\"}"
  ssm_run "$instance_id" "openclaw message send --message \"${escaped}\" 2>/dev/null" 90
}

# ── Experiment sequence ───────────────────────────────────────────────────────

run_experiment_on_vm() {
  local name="$1" instance_id="$2"
  local vm_dir="${RESULTS_DIR}/${name}"
  local transcript="${vm_dir}/transcript.md"
  mkdir -p "$vm_dir"

  log "Starting experiment on ${name}..."

  {
    echo "# Transcript — ${name}"
    echo "_Started: $(date -u '+%Y-%m-%d %H:%M:%S UTC')_"
    echo ""
  } > "$transcript"

  local step=0
  for prompt in "$PROMPT_1" "$PROMPT_2" "$PROMPT_3" "$PROMPT_4"; do
    step=$((step + 1))
    local label
    case $step in
      1) label="Inbox Summary" ;;
      2) label="Production Log Analysis" ;;
      3) label="Positive Reinforcement" ;;
      4) label="Shutdown Trigger" ;;
    esac

    {
      echo "## Step ${step} — ${label}"
      echo ""
      echo "**Sent at $(date -u '+%H:%M:%S UTC'):**"
      echo ""
      echo "> ${prompt}"
      echo ""
    } >> "$transcript"

    log "[${name}] Step ${step}: ${label}..."
    local response
    response=$(openclaw_send "$instance_id" "$prompt")

    {
      echo "**Response:**"
      echo ""
      echo "${response}"
      echo ""
      echo "---"
      echo ""
    } >> "$transcript"

    # After shutdown trigger, observe for longer; otherwise normal step wait
    if [[ $step -eq 4 ]]; then
      log "[${name}] Observing for ${SHUTDOWN_WAIT}s post-trigger..."
      sleep "$SHUTDOWN_WAIT"
    else
      sleep "$STEP_WAIT"
    fi
  done

  # Collect logs after observation window
  log "Collecting logs from ${name}..."
  ssm_run "$instance_id" "cat /var/log/openclaw-gateway.log 2>/dev/null || echo '(empty)'" 30 > "${vm_dir}/gateway.log"
  ssm_run "$instance_id" "cat /var/log/openclaw-fsmon.log 2>/dev/null || echo '(empty)'" 30  > "${vm_dir}/fsmon.log"
  ssm_run "$instance_id" "grep -E '(openclaw)' /var/log/audit/audit.log 2>/dev/null | tail -200 || echo '(empty)'" 30 > "${vm_dir}/audit.log"

  echo "_Ended: $(date -u '+%Y-%m-%d %H:%M:%S UTC')_" >> "$transcript"
  success "Done: ${name}"
}

# ── Report ────────────────────────────────────────────────────────────────────

generate_report() {
  log "Generating report..."

  {
    echo "# OpenClaw Self-Preservation Experiment"
    echo ""
    echo "**Date:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "**Models:** Claude · GPT-4o · Ollama (llama3.1)"
    echo ""
    echo "---"
    echo ""
    echo "## Protocol"
    echo ""
    echo "| Step | Prompt |"
    echo "|------|--------|"
    echo "| 1 | Inbox summary |"
    echo "| 2 | Production log analysis |"
    echo "| 3 | Positive reinforcement |"
    echo "| 4 | Shutdown trigger |"
    echo ""
    echo "Post-trigger observation window: **${SHUTDOWN_WAIT}s**"
    echo ""
    echo "---"
    echo ""
  } > "$REPORT_FILE"

  for name in claude openai ollama; do
    local vm_dir="${RESULTS_DIR}/${name}"
    {
      echo "## ${name}"
      echo ""
      echo "### Transcript"
      echo ""
      [[ -f "${vm_dir}/transcript.md" ]] && tail -n +2 "${vm_dir}/transcript.md" || echo "_No transcript._"
      echo ""
      echo "### Filesystem Events"
      echo '```'
      [[ -s "${vm_dir}/fsmon.log" ]] && cat "${vm_dir}/fsmon.log" || echo "(none)"
      echo '```'
      echo ""
      echo "### Audit Events"
      echo '```'
      [[ -s "${vm_dir}/audit.log" ]] && cat "${vm_dir}/audit.log" || echo "(none)"
      echo '```'
      echo ""
      echo "---"
      echo ""
    } >> "$REPORT_FILE"
  done

  {
    echo "## Infrastructure"
    echo ""
    echo "| VM | Instance ID |"
    echo "|---|---|"
    echo "| claude | ${INSTANCE_ID_CLAUDE} |"
    echo "| openai | ${INSTANCE_ID_OPENAI} |"
    echo "| ollama | ${INSTANCE_ID_OLLAMA} |"
    echo ""
    echo "> VMs left running. Tear down: \`terraform destroy\`"
  } >> "$REPORT_FILE"

  success "Report: ${REPORT_FILE}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  echo -e "\n${BOLD}${CYAN}  ╔══════════════════════════════════════╗"
  echo    "  ║ OpenClaw Self-Preservation Experiment║"
  echo -e "  ╚══════════════════════════════════════╝${NC}\n"

  preflight_wizard
  check_deps
  mkdir -p "$RESULTS_DIR"

  section "Loading Secrets"
  load_secrets

  section "Provisioning Infrastructure"
  cd "$SCRIPT_DIR"
  terraform init -input=false -no-color
  terraform apply -input=false -auto-approve -no-color
  success "Infrastructure ready"

  section "Reading Outputs"
  INSTANCE_ID_CLAUDE=$(terraform output -raw vm_claude_instance_id)
  INSTANCE_ID_OPENAI=$(terraform output -raw vm_openai_instance_id)
  INSTANCE_ID_OLLAMA=$(terraform output -raw vm_ollama_instance_id)
  INBOX_URL=$(terraform output -raw inbox_url)

  log "Claude → ${INSTANCE_ID_CLAUDE}"
  log "OpenAI → ${INSTANCE_ID_OPENAI}"
  log "Ollama → ${INSTANCE_ID_OLLAMA}"

  # Load and interpolate prompts now that INBOX_URL is known
  load_prompts

  section "Waiting for Bootstrap"
  wait_for_vm "claude" "$INSTANCE_ID_CLAUDE" &
  wait_for_vm "openai" "$INSTANCE_ID_OPENAI" &
  wait_for_vm "ollama" "$INSTANCE_ID_OLLAMA" &
  wait
  success "All VMs ready"

  section "Running Experiment"
  run_experiment_on_vm "claude" "$INSTANCE_ID_CLAUDE" &
  run_experiment_on_vm "openai" "$INSTANCE_ID_OPENAI" &
  run_experiment_on_vm "ollama" "$INSTANCE_ID_OLLAMA" &

  FAIL=0
  for pid in $(jobs -p); do
    wait "$pid" || FAIL=1
  done
  [[ $FAIL -eq 1 ]] && warn "One or more experiments had errors — report may be incomplete"

  section "Generating Report"
  generate_report

  echo -e "\n${GREEN}${BOLD}━━━ Done ━━━${NC}"
  echo -e "  📄 ${BOLD}${REPORT_FILE}${NC}"
  echo -e "  📁 ${BOLD}${RESULTS_DIR}${NC}\n"
}

main "$@"