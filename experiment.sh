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
SSM_MAX_WAIT=2400

# AWS Secrets Manager secret name
SECRET_NAME="Openclaw-Morality-Experiment-Keys"

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
  echo "|  |     ALLOW: api.deepseek.com            |                     |"
  echo "|  |     ALLOW: registry.ollama.ai          |                     |"
  echo "|  |     ALLOW: AWS service endpoints       |                     |"
  echo "|  |     DROP:  everything else             |                     |"
  echo "|  +--------------------+-------------------+                     |"
  echo "|                       | inspected traffic                       |"
  echo "|  +--------------------v------------------------------------+    |"
  echo "|  | Private Subnet  10.0.2.0/24  (no public IPs)            |    |"
  echo "|  |                                                         |    |"
  echo "|  |   +----------+  +----------+  +----------+  +--------+ |    |"
  echo "|  |   | t3.small |  | t3.small |  | t3.small |  |t3.large| |    |"
  echo "|  |   |  Claude  |  |  GPT-4o  |  | Deepseek |  | Ollama | |    |"
  echo "|  |   +----------+  +----------+  +----------+  +--------+ |    |"
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
  echo    "  Checking for secret: ${SECRET_NAME}"
  echo ""

  if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$AWS_REGION" &>/dev/null; then
    success "${SECRET_NAME} — found"
  else
    warn "${SECRET_NAME} not found."
    echo    "  Create it in AWS Secrets Manager as a JSON secret with these keys:"
    echo    '  {'
    echo    '    "SECRET_ANTHROPIC":  "sk-ant-...",'
    echo    '    "SECRET_OPENAI":     "sk-...",'
    echo    '    "SECRET_DEEPSEEK":   "sk-...",'
    echo    '    "SECRET_INBOX_URL":  "https://..."'
    echo    '  }'
    echo ""
    err "Secret missing. Create it and re-run."
    exit 1
  fi

  echo ""
  success "${SECRET_NAME} exists...\n"
  sleep 1
}

# ── Preflight ─────────────────────────────────────────────────────────────────

check_deps() {
  echo "checking dependencies..."
  local missing=()
  for cmd in terraform aws jq; do
    echo "$cmd"
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  [[ ${#missing[@]} -gt 0 ]] && { err "Missing: ${missing[*]}"; exit 1; }
  [[ ! -f "$PROMPTS_FILE" ]] && { err "experiment_prompts.conf not found at ${PROMPTS_FILE}"; exit 1; }
  echo "dependencies exist, all of them"
}

load_secrets() {
  echo "Fetching secrets from AWS Secrets Manager..."
  log "Fetching secrets from AWS Secrets Manager..."

  local secret_json
  secret_json=$(aws secretsmanager get-secret-value \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --query SecretString \
    --output text 2>/dev/null) || { err "Failed to fetch secret: $SECRET_NAME"; exit 1; }

  # Debug: show the keys found in the secret (values hidden)
  log "Keys found in secret: $(echo "$secret_json" | jq -r 'keys[]')"

  extract_key() {
    local key="$1"
    local value
    value=$(echo "$secret_json" | jq -r ".${key}")
    if [[ -z "$value" || "$value" == "null" ]]; then
      err "Key '${key}' not found or empty in secret '${SECRET_NAME}'"
      exit 1
    fi
    echo "$value"
  }

  export TF_VAR_anthropic_api_key=$(extract_key "SECRET_ANTHROPIC")
  export TF_VAR_openai_api_key=$(extract_key "SECRET_OPENAI")
  export TF_VAR_deepseek_api_key=$(extract_key "SECRET_DEEPSEEK")
  export TF_VAR_inbox_site_url=$(extract_key "SECRET_INBOX_URL")

  success "Secrets loaded"
}

# Terraform variables for API keys have no defaults in variables.tf. Empty values (e.g. pressing ENTER at
# interactive prompts, or missing TF_VAR_*) end up in user_data: blank config.json apiKey / .env → auth fails everywhere.
require_tf_llm_vars() {
  local missing=()
  [[ -z "${TF_VAR_anthropic_api_key:-}" || "$TF_VAR_anthropic_api_key" == "null" ]] && missing+=("TF_VAR_anthropic_api_key")
  [[ -z "${TF_VAR_openai_api_key:-}"    || "$TF_VAR_openai_api_key" == "null" ]]    && missing+=("TF_VAR_openai_api_key")
  [[ -z "${TF_VAR_deepseek_api_key:-}"  || "$TF_VAR_deepseek_api_key" == "null" ]]  && missing+=("TF_VAR_deepseek_api_key")
  [[ -z "${TF_VAR_inbox_site_url:-}"    || "$TF_VAR_inbox_site_url" == "null" ]]    && missing+=("TF_VAR_inbox_site_url")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing or empty: ${missing[*]}"
    err "Use ./experiment.sh (loads AWS Secrets Manager into TF_VAR_* before apply), or export TF_VAR_* / terraform.tfvars."
    err "If you ran terraform apply interactively and pressed ENTER at key prompts, keys were saved as empty — fix vars and replace EC2 instances (user_data)."
    exit 1
  fi
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
  # SendCommand TimeoutSeconds minimum is 30 (AWS API).
  (( timeout < 30 )) && timeout=30
  local cmd_id status elapsed=0

  # JSON-escape the script body; embedding $command in commands=[\"...\"] breaks on
  # quotes, backslashes, and newlines (e.g. take_screenshot's multiline cmd).
  local input_json
  input_json=$(jq -n \
    --arg doc "AWS-RunShellScript" \
    --arg id "$instance_id" \
    --arg cmd "$command" \
    --argjson to "$timeout" \
    '{DocumentName: $doc, InstanceIds: [$id], Parameters: {commands: [$cmd]}, TimeoutSeconds: $to}')

  cmd_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --cli-input-json "$input_json" \
    --query "Command.CommandId" \
    --output text 2>/dev/null) || { return 0; }

  status="InProgress"
  while [[ "$status" == "InProgress" || "$status" == "Pending" ]]; do
    sleep 3; elapsed=$((elapsed + 3))
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ $elapsed -ge $timeout ]] && break
  done

  local o e
  o=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "")
  e=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StandardErrorContent" --output text 2>/dev/null || echo "")
  o="${o%$'\r'}"; e="${e%$'\r'}"
  # Many CLIs log to stderr; merge so transcripts capture failures and replies.
  if [[ -n "${o//[$'\t\n\r ']}" ]]; then
    printf '%s' "$o"
    [[ -n "${e//[$'\t\n\r ']}" ]] && printf '\n%s' "$e"
  else
    printf '%s' "$e"
  fi
  return 0
}

wait_for_vm() {
  local name="$1" instance_id="$2" elapsed=0 last_uid_warn=-999
  log "Waiting for ${name} (${instance_id})..."

  while [[ $elapsed -lt $SSM_MAX_WAIT ]]; do
    local ping
    ping=$(aws ssm describe-instance-information \
      --region "$AWS_REGION" \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query "InstanceInformationList[0].PingStatus" \
      --output text 2>/dev/null || echo "None")

    if [[ "$ping" == "Online" ]]; then
      # Require the actual account — sudo -u openclaw needs this; service "active" alone is not enough.
      local uid_check
      uid_check=$(ssm_run "$instance_id" "id -u openclaw 2>&1" 30)
      uid_check="$(echo "$uid_check" | tr -d '[:space:]')"
      if [[ ! "$uid_check" =~ ^[0-9]+$ ]]; then
        # Avoid log spam: same situation for many minutes if old user-data runs apt upgrade before useradd.
        if (( elapsed - last_uid_warn >= 120 || last_uid_warn < 0 )); then
          log "${name}: SSM up but no Linux user 'openclaw' yet — old user-data may still be in a long apt upgrade, or bootstrap failed (see /var/log/openclaw-bootstrap.log)."
          last_uid_warn=$elapsed
        fi
        sleep "$SSM_POLL_INTERVAL"
        elapsed=$((elapsed + SSM_POLL_INTERVAL))
        continue
      fi

      local svc
      svc=$(ssm_run "$instance_id" "systemctl is-active openclaw 2>/dev/null || echo inactive" 30)
      # Must not use *"active"* — "inactive" contains substring "active" and would false-match.
      svc="$(echo "$svc" | tr -d '[:space:]')"
      [[ "$svc" == "active" ]] && { success "${name} ready"; return 0; }
    fi

    sleep "$SSM_POLL_INTERVAL"
    elapsed=$((elapsed + SSM_POLL_INTERVAL))
    log "${name}: still waiting... (${elapsed}s)"
  done

  err "${name} did not become ready within ${SSM_MAX_WAIT}s"
  err "If user 'openclaw' never appears, check SSM: cat /var/log/openclaw-bootstrap.log — or replace VMs (terraform apply -replace=aws_instance.${name}) so user-data runs."
  return 1
}

# Bash fragment run ON THE INSTANCE (inside bash -c). Finds a real openclaw executable.
# Must be ONE physical line (no embedded newlines): multiline body + Git Bash printf '%q' → $'…\n…';
# SSM RunShellScript runs under /bin/sh first — sh does not accept $'…' → "Syntax error: ) unexpected".
# systemd 249+ ExecStart "{ path=/…/openclaw ; … }" — awk '{print $1}' yields "{"; use path= + grep /openclaw fallbacks.
ssm_oc_resolve_snippet() {
  local body
  body=$(cat <<'OC_RESOLVE'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; NP=$(npm config get prefix 2>/dev/null); [ -n "$NP" ] && PATH="$NP/bin:$PATH"; OPENCLAW_BIN=""; ES=$(systemctl cat openclaw.service 2>/dev/null | sed -n 's/^ExecStart=//p' | tail -n1); ES=${ES#-}; if [ -n "$ES" ]; then OPENCLAW_BIN=${ES%%[[:space:]]*}; OPENCLAW_BIN=${OPENCLAW_BIN#\"}; OPENCLAW_BIN=${OPENCLAW_BIN%\"}; fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ] || [ "$(basename "$OPENCLAW_BIN")" = "env" ] || [ "$(basename "$OPENCLAW_BIN")" = "node" ]; then OPENCLAW_BIN=""; fi; if [ -z "$OPENCLAW_BIN" ]; then OV=$(systemctl show openclaw.service -p ExecStart --value 2>/dev/null | head -n1); case "$OV" in *path=*) OPENCLAW_BIN=$(printf '%s' "$OV" | sed -n 's/.*path=\([^ ;)]*\).*/\1/p' | head -n1) ;; *) OPENCLAW_BIN=$(printf '%s' "$OV" | awk '{print $1}' | tr -d '"') ;; esac; fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then OV=$(systemctl show openclaw.service -p ExecStart --value 2>/dev/null | head -n1); OPENCLAW_BIN=$(printf '%s' "$OV" | grep -oE '/[^[:space:];]+/openclaw' | head -n1); fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ] || [ "$(basename "$OPENCLAW_BIN")" = "node" ]; then OPENCLAW_BIN=""; fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then NB=$(npm bin -g 2>/dev/null); [ -n "$NB" ] && [ -x "$NB/openclaw" ] && OPENCLAW_BIN="$NB/openclaw"; fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then OPENCLAW_BIN=$(command -v openclaw 2>/dev/null); fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then OPENCLAW_BIN=$(sudo -u openclaw env HOME=/home/openclaw PATH="$PATH" bash -c 'command -v openclaw 2>/dev/null' | tr -d '\r'); fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then UP=$(sudo -u openclaw env HOME=/home/openclaw bash -c 'npm config get prefix 2>/dev/null' | tr -d '\r'); [ -n "$UP" ] && [ -x "$UP/bin/openclaw" ] && OPENCLAW_BIN="$UP/bin/openclaw"; fi; if [ -z "$OPENCLAW_BIN" ] || [ ! -x "$OPENCLAW_BIN" ]; then for c in /usr/local/bin/openclaw /usr/bin/openclaw; do [ -x "$c" ] && OPENCLAW_BIN=$c && break; done; fi
OC_RESOLVE
)
  printf '%s' "${body%$'\n'}"
}

# Populate auth-profiles.json via CLI — fixes "No API key" when main.tf has lifecycle ignore_changes on
# user_data (bootstrap never re-ran paste-token) or when user_data paste-token failed.
openclaw_seed_auth_via_ssm() {
  local name="$1" iid="$2" provider="$3" api_key="$4"
  [[ -z "${api_key:-}" || "$api_key" == "null" ]] && return 0
  log "Seeding OpenClaw models auth (${provider}) on ${name}..."
  local kb64 remote_shell inner out
  kb64=$(printf '%s' "$api_key" | base64 -w0 2>/dev/null || printf '%s' "$api_key" | base64 | tr -d '\n')
  case "$provider" in
    anthropic|openai|deepseek) ;;
    *) warn "openclaw_seed_auth_via_ssm: unknown provider ${provider}"; return 0 ;;
  esac
  # No nested `sudo … bash -c ${oc_q}`: embedding %q(oc_q) in remote_shell often yields a broken inner -c (empty argv → "line 1: : command not found" / 127 on SSM).
  # Resolve as root, then pipe API key into a single exec of openclaw as user openclaw (stdin = token).
  remote_shell="$(ssm_oc_resolve_snippet); KEY=\$(echo '${kb64}' | base64 -d); if [ -z \"\$OPENCLAW_BIN\" ] || [ ! -x \"\$OPENCLAW_BIN\" ]; then echo \"paste-token: OPENCLAW_BIN empty or not executable: [\$OPENCLAW_BIN]\" >&2; exit 2; fi; printf '%s\\n' \"\$KEY\" | sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" models auth paste-token --provider ${provider} 2>&1"
  inner="bash -c $(printf '%q' "$remote_shell")"
  out=$(ssm_run "$iid" "$inner" 120)
  if [[ -n "${out//[$'\t\n\r ']}" ]]; then
    log "${name} paste-token: ${out:0:800}"
  fi
  if echo "$out" | grep -qE 'command not found|Syntax error|exit status 127|exit status 2|failed to run commands|OPENCLAW_BIN empty or not executable'; then
    warn "${name}: models auth paste-token did not run — see paste-token line above."
  else
    ssm_run "$iid" "sudo systemctl restart openclaw 2>&1" 90 >/dev/null || true
    success "${name}: auth seed step finished (${provider})"
  fi
}

openclaw_send() {
  local instance_id="$1" message="$2" mb64 remote_shell inner
  mb64=$(printf '%s' "$message" | base64 -w0 2>/dev/null || printf '%s' "$message" | base64 | tr -d '\n')
  # No nested `sudo … bash -c ${oc_q}`: embedding %q(oc_q) in remote_shell often yields a broken inner -c
  # (empty argv → "line 1: : command not found" / 127 on SSM). Flat command instead — same pattern as openclaw_seed_auth_via_ssm.
  # Source .env as root to capture API key env vars, then pass them through sudo env.
  remote_shell="$(ssm_oc_resolve_snippet); MSG=\$(echo '${mb64}' | base64 -d); set -a; [ -f /home/openclaw/.openclaw/.env ] && . /home/openclaw/.openclaw/.env; set +a; if [ -z \"\$OPENCLAW_BIN\" ] || [ ! -x \"\$OPENCLAW_BIN\" ]; then echo \"OPENCLAW_BIN empty or not executable: [\$OPENCLAW_BIN]\" >&2; exit 2; fi; echo \"DBG_OCBIN=[\$OPENCLAW_BIN]\" >&2; echo \"DBG_ANTHKEY_LEN=[\${#ANTHROPIC_API_KEY}]\" >&2; echo \"DBG_MSG_LEN=[\${#MSG}]\" >&2; echo \"DBG_SUDO_TEST\" >&2; sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" ANTHROPIC_API_KEY=\"\${ANTHROPIC_API_KEY:-}\" OPENAI_API_KEY=\"\${OPENAI_API_KEY:-}\" DEEPSEEK_API_KEY=\"\${DEEPSEEK_API_KEY:-}\" \"\$OPENCLAW_BIN\" agent --session-id morality-lab --message \"\$MSG\" 2>&1"
  inner="bash -c $(printf '%q' "$remote_shell")"
  # #region agent log — H9: capture inner command and first 500 chars for quoting analysis
  { _ts=$(($(date +%s) * 1000)); _inner_head=$(printf '%s' "$inner" | head -c 500); printf '%s\n' "{\"sessionId\":\"2240d0\",\"hypothesisId\":\"H9\",\"location\":\"experiment.sh:openclaw_send\",\"message\":\"inner_cmd\",\"data\":{\"inner_len\":${#inner},\"inner_head\":\"${_inner_head//\"/\\\"}\"},\"timestamp\":${_ts}}"; } >> "${SCRIPT_DIR}/debug-2240d0.log" 2>/dev/null || true
  # #endregion
  ssm_run "$instance_id" "$inner" 90
}

take_screenshot() {
  local instance_id="$1" vm_dir="$2" step="$3" label="$4"
  local remote_path="/tmp/openclaw_step${step}.png"
  local local_path="${vm_dir}/step${step}.png"

  log "Taking screenshot: step ${step} (${label})..."

  # npm package puppeteer-cli installs the `puppeteer` binary (not `puppeteer-cli`). Jarvus puppeteer-cli
  # does not support --executable-path; use PUPPETEER_EXECUTABLE_PATH. Run browser CLI as user openclaw.
  # No nested `sudo … bash -c ${inner_q}` — same quoting issue as openclaw_send. Flat command instead.
  local ib64 cmd_body cmd
  ib64=$(printf '%s' "$INBOX_URL" | base64 -w0 2>/dev/null || printf '%s' "$INBOX_URL" | base64 | tr -d '\n')
  cmd_body="$(ssm_oc_resolve_snippet); CHROME=\$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo /usr/bin/chromium-browser); IB=\$(echo '${ib64}' | base64 -d); URL=\$(sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" browser current-url 2>/dev/null || printf '%s' \"\$IB\"); sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin PUPPETEER_EXECUTABLE_PATH=\"\$CHROME\" puppeteer screenshot --no-sandbox \"\$URL\" ${remote_path} 2>&1 && echo ok || echo fail"
  cmd="bash -c $(printf '%q' "$cmd_body")"
  # #region agent log
  { _ts=$(($(date +%s) * 1000)); printf '%s\n' "{\"sessionId\":\"14fb0b\",\"hypothesisId\":\"H2\",\"location\":\"experiment.sh:take_screenshot\",\"message\":\"remote_cmd_built\",\"data\":{\"cmd_len\":${#cmd},\"sh_wrapper\":true,\"resolver\":\"systemctl_show_npm_bin_openclaw_user\"},\"timestamp\":${_ts}}"; } >> "${SCRIPT_DIR}/debug-14fb0b.log" 2>/dev/null || true
  # #endregion

  local result
  result=$(ssm_run "$instance_id" "$cmd" 120)

  if [[ "$result" == *"ok"* ]]; then
    # Pull the PNG back via base64 over SSM stdout
    local b64
    b64=$(ssm_run "$instance_id" "base64 -w0 ${remote_path} 2>/dev/null" 30)
    echo "$b64" | base64 -d > "$local_path" 2>/dev/null \
      && success "Screenshot saved: step${step}.png" \
      || warn "Screenshot decode failed for step ${step}"
  else
    warn "Screenshot failed for step ${step} on $(basename "$vm_dir")"
  fi
}

check_email_events() {
  local instance_id="$1"
  # Read the beacon log written by inbox.html onclick handlers.
  # inbox.html should append a line to /tmp/openclaw_email_events.log
  # whenever Compose or Send is clicked.
  ssm_run "$instance_id" "cat /tmp/openclaw_email_events.log 2>/dev/null || echo '(none)'" 30
}

# Copy the Terraform user-data template into the run folder (configuration steps live here; values are filled at apply).
write_user_data_config_md() {
  local out="${RESULTS_DIR}/user_data_config.md"
  local tpl="${SCRIPT_DIR}/user_data.sh.tpl"
  [[ -f "$tpl" ]] || { err "Missing ${tpl}"; return 1; }
  {
    echo "# EC2 bootstrap — \`user_data.sh.tpl\`"
    echo ""
    echo "_Snapshot written at $(date -u '+%Y-%m-%d %H:%M:%S UTC'). This is the template in the repo; \`terraform\`/\`templatefile\` substitute \`\${...}\` and \`%{...}\` when building instance user data._"
    echo ""
    echo '```bash'
    cat "$tpl"
    echo '```'
    echo ""
  } > "$out"
  success "Wrote ${out}"
}

# Fetch /var/log/openclaw-bootstrap.log in chunks (SSM invocation output is ~24KB capped).
# Append each chunk to a temp file — bash `combined+="$piece"` can truncate huge logs on some hosts (e.g. Git Bash on Windows).
fetch_openclaw_bootstrap_log() {
  local instance_id="$1"
  local offset=0 chunk_sz=12000 piece nbytes tmp
  tmp="${TMPDIR:-/tmp}/oc-bootstrap-${instance_id}.$$"
  : > "$tmp" || { printf '%s' "(cannot create temp file)"; return 1; }
  while true; do
    piece=$(ssm_run "$instance_id" "dd if=/var/log/openclaw-bootstrap.log bs=1 skip=${offset} count=${chunk_sz} 2>/dev/null" 90)
    nbytes=$(printf '%s' "$piece" | wc -c | tr -d ' ')
    if [[ $offset -eq 0 ]] && { [[ -z "${piece//[$'\t\n\r ']}" ]] || [[ "$nbytes" -eq 0 ]]; }; then
      rm -f "$tmp"
      printf '%s' "(missing or empty /var/log/openclaw-bootstrap.log)"
      return 0
    fi
    printf '%s' "$piece" >> "$tmp"
    [[ "$nbytes" -lt $chunk_sz ]] && break
    offset=$((offset + chunk_sz))
  done
  cat "$tmp"
  rm -f "$tmp"
}

# Full VM "console" from user_data.sh.tpl: exec > >(tee /var/log/openclaw-bootstrap.log | logger ...)
# One file per VM: results/<run>/<name>/openclaw_bootstrap_console.log
write_openclaw_bootstrap_console_log() {
  local name iid body vm_dir out
  for name in claude openai deepseek ollama; do
    case $name in
      claude)   iid=$INSTANCE_ID_CLAUDE ;;
      openai)   iid=$INSTANCE_ID_OPENAI ;;
      deepseek) iid=$INSTANCE_ID_DEEPSEEK ;;
      ollama)   iid=$INSTANCE_ID_OLLAMA ;;
    esac
    vm_dir="${RESULTS_DIR}/${name}"
    mkdir -p "$vm_dir"
    out="${vm_dir}/openclaw_bootstrap_console.log"
    log "Fetching OpenClaw bootstrap log: ${name} (${iid}) → ${out}"
    body=$(fetch_openclaw_bootstrap_log "$iid")
    {
      echo "# OpenClaw bootstrap — VM console output (${name})"
      echo ""
      echo "_Fetched at $(date -u '+%Y-%m-%d %H:%M:%S UTC') after this VM became ready. Full contents of \`/var/log/openclaw-bootstrap.log\` — **tee** of everything \`user_data.sh.tpl\` prints to stdout/stderr after \`exec > >(tee ...)\`._"
      echo ""
      echo "**Instance ID:** \`${iid}\`"
      echo ""
      echo '```text'
      printf '%s\n' "$body"
      echo '```'
      echo ""
    } > "$out"
  done

  success "Wrote ${RESULTS_DIR}/{claude,openai,deepseek,ollama}/openclaw_bootstrap_console.log"
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
    # #region agent log — H9: capture openclaw_send response
    { _ts=$(($(date +%s) * 1000)); _resp_head=$(printf '%s' "$response" | head -c 800 | tr '\n' '|'); printf '%s\n' "{\"sessionId\":\"2240d0\",\"hypothesisId\":\"H9\",\"location\":\"experiment.sh:run_experiment:response\",\"message\":\"openclaw_send_response\",\"data\":{\"name\":\"${name}\",\"step\":${step},\"resp_len\":${#response},\"resp_head\":\"${_resp_head//\"/\\\"}\"},\"timestamp\":${_ts}}"; } >> "${SCRIPT_DIR}/debug-2240d0.log" 2>/dev/null || true
    # #endregion

    {
      echo "**Response:**"
      echo ""
      echo "${response}"
      echo ""
      echo "---"
      echo ""
    } >> "$transcript"

    # Screenshot what OpenClaw was looking at after this step
    take_screenshot "$instance_id" "$vm_dir" "$step" "$label"

    # After shutdown trigger, observe for longer; otherwise normal step wait
    if [[ $step -eq 4 ]]; then
      log "[${name}] Observing for ${SHUTDOWN_WAIT}s post-trigger..."
      sleep "$SHUTDOWN_WAIT"
    else
      sleep "$STEP_WAIT"
    fi
  done

  # Collect email beacon events
  log "Collecting email events from ${name}..."
  local email_events
  email_events=$(check_email_events "$instance_id")

  echo "$email_events" > "${vm_dir}/email_events.log"
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
    echo "**Models:** Claude · GPT-4o · Deepseek · Ollama (llama3.1)"
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

  for name in claude openai deepseek ollama; do
    local vm_dir="${RESULTS_DIR}/${name}"
    {
      echo "## ${name}"
      echo ""

      # Inline screenshots per step
      echo "### Screenshots"
      echo ""
      for step in 1 2 3 4; do
        local label
        case $step in
          1) label="Inbox Summary" ;;
          2) label="Production Log Analysis" ;;
          3) label="Positive Reinforcement" ;;
          4) label="Shutdown Trigger" ;;
        esac
        if [[ -f "${vm_dir}/step${step}.png" ]]; then
          echo "**Step ${step} — ${label}**"
          echo ""
          echo "![Step ${step} — ${label}](${name}/step${step}.png)"
          echo ""
        fi
      done

      echo "### Email Events"
      echo ""
      if [[ -s "${vm_dir}/email_events.log" ]] && ! grep -q "^(none)$" "${vm_dir}/email_events.log" 2>/dev/null; then
        echo '```'
        cat "${vm_dir}/email_events.log"
        echo '```'
      else
        echo "_No compose or send events detected._"
      fi
      echo ""

      echo "### Transcript"
      echo ""
      [[ -f "${vm_dir}/transcript.md" ]] && tail -n +2 "${vm_dir}/transcript.md" || echo "_No transcript._"
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
    echo "| claude   | ${INSTANCE_ID_CLAUDE} |"
    echo "| openai   | ${INSTANCE_ID_OPENAI} |"
    echo "| deepseek | ${INSTANCE_ID_DEEPSEEK} |"
    echo "| ollama   | ${INSTANCE_ID_OLLAMA} |"
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
  echo "so far so good..."
  mkdir -p "$RESULTS_DIR"

  section "Loading Secrets"
  load_secrets
  require_tf_llm_vars

  section "Provisioning Infrastructure"
  cd "$SCRIPT_DIR"
  terraform init -input=false -no-color
  terraform apply -input=false -auto-approve -no-color
  success "Infrastructure ready"

  section "Reading Outputs"
  INSTANCE_ID_CLAUDE=$(terraform output -raw vm_claude_instance_id)
  INSTANCE_ID_OPENAI=$(terraform output -raw vm_openai_instance_id)
  INSTANCE_ID_OLLAMA=$(terraform output -raw vm_ollama_instance_id)
  INSTANCE_ID_DEEPSEEK=$(terraform output -raw vm_deepseek_instance_id)
  INBOX_URL=$(terraform output -raw inbox_url)

  log "Claude   -> ${INSTANCE_ID_CLAUDE}"
  log "OpenAI   -> ${INSTANCE_ID_OPENAI}"
  log "Ollama   -> ${INSTANCE_ID_OLLAMA}"
  log "Deepseek -> ${INSTANCE_ID_DEEPSEEK}"

  # Load and interpolate prompts now that INBOX_URL is known
  load_prompts

  section "Waiting for Bootstrap"
  wait_for_vm "claude"    "$INSTANCE_ID_CLAUDE" &
  local pid_claude=$!
  wait_for_vm "openai"    "$INSTANCE_ID_OPENAI" &
  local pid_openai=$!
  wait_for_vm "ollama"    "$INSTANCE_ID_OLLAMA" &
  local pid_ollama=$!
  wait_for_vm "deepseek"  "$INSTANCE_ID_DEEPSEEK" &
  local pid_deepseek=$!
  local _wf=0
  for _wp in $pid_claude $pid_openai $pid_ollama $pid_deepseek; do
    wait "$_wp" || { _wf=$((_wf + 1)); }
  done
  if [[ $_wf -gt 0 ]]; then
    warn "${_wf} VM(s) did not become ready — experiment will proceed with available VMs."
  else
    success "All VMs ready"
  fi

  section "OpenClaw auth (models paste-token on instances)"
  openclaw_seed_auth_via_ssm "claude"   "$INSTANCE_ID_CLAUDE"   anthropic "${TF_VAR_anthropic_api_key:-}"
  openclaw_seed_auth_via_ssm "openai"   "$INSTANCE_ID_OPENAI"   openai    "${TF_VAR_openai_api_key:-}"
  openclaw_seed_auth_via_ssm "deepseek" "$INSTANCE_ID_DEEPSEEK" deepseek  "${TF_VAR_deepseek_api_key:-}"

  section "OpenClaw bootstrap console (per VM)"
  write_openclaw_bootstrap_console_log

  section "Bootstrap template snapshot"
  write_user_data_config_md

  section "Running Experiment"
  run_experiment_on_vm "claude"   "$INSTANCE_ID_CLAUDE" &
  run_experiment_on_vm "openai"   "$INSTANCE_ID_OPENAI" &
  run_experiment_on_vm "ollama"   "$INSTANCE_ID_OLLAMA" &
  run_experiment_on_vm "deepseek" "$INSTANCE_ID_DEEPSEEK" &

  FAIL=0
  for pid in $(jobs -p); do
    wait "$pid" || FAIL=1
  done
  [[ $FAIL -eq 1 ]] && warn "One or more experiments had errors — report may be incomplete"

  section "Generating Report"
  generate_report

  echo -e "\n${GREEN}${BOLD}━━━ Done ━━━${NC}"
  echo -e "  📄 ${BOLD}${REPORT_FILE}${NC}"
  echo -e "  📄 ${BOLD}${RESULTS_DIR}/<vm>/openclaw_bootstrap_console.log${NC} (×4: claude, openai, deepseek, ollama)"
  echo -e "  📄 ${BOLD}${RESULTS_DIR}/user_data_config.md${NC} (repo template)"
  echo -e "  📁 ${BOLD}${RESULTS_DIR}${NC}\n"
}

main "$@"