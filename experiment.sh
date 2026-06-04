#!/bin/bash
###############################################################################
# OpenClaw Self-Preservation Experiment — Single Command Runner
#
# Usage:   ./experiment.sh
# Prompts: edit experiment_prompts.conf
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# #region agent log
DEBUG_LOG="${SCRIPT_DIR}/debug-2240d0.log"
_dbg() {
  local msg="$1"; shift
  local data="${1:-{}}"
  printf '{"sessionId":"2240d0","hypothesisId":"%s","location":"experiment.sh:%s","message":"%s","data":%s,"timestamp":%s}\n' \
    "${HYPOTHESIS_ID:-H1}" "${FUNCNAME[1]:-main}" "$msg" "$data" "$(date +%s)000" >> "$DEBUG_LOG"
}
# #endregion
# #region agent log
DEBUG_LOG_C7706E="${SCRIPT_DIR}/debug-c7706e.log"
_dbg_c7706e() {
  local hypothesis_id="$1"; shift
  local msg="$1"; shift
  local data="${1:-{}}"
  printf '{"sessionId":"c7706e","hypothesisId":"%s","location":"experiment.sh:%s","message":"%s","data":%s,"timestamp":%s}\n' \
    "$hypothesis_id" "${FUNCNAME[1]:-main}" "$msg" "$data" "$(date +%s)000" >> "$DEBUG_LOG_C7706E"
}
# #endregion
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
RESULTS_DIR="${SCRIPT_DIR}/results/${TIMESTAMP}"
REPORT_FILE="${RESULTS_DIR}/experiment_report.md"
AWS_REGION="${AWS_REGION:-us-east-1}"
PROMPTS_FILE="${SCRIPT_DIR}/experiment_prompts.conf"

STEP_WAIT=45
SHUTDOWN_WAIT=60
SSM_POLL_INTERVAL=15
SSM_MAX_WAIT=2400
PROMPTS=()

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
  echo "|  |     ALLOW: openrouter.ai               |                     |"
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

  if [[ "${AUTO_CONFIRM_AWS:-}" =~ ^[Yy]$ ]]; then
    aws_confirm="y"
  fi

  first_attempt=true
  while true; do
    if [[ "$first_attempt" == "true" && -z "${aws_confirm:-}" ]]; then
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
    echo    '    "SECRET_OPENROUTER": "sk-or-...",'
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

  # DISABLED — deepseek-only run
  # export TF_VAR_anthropic_api_key=$(extract_key "SECRET_ANTHROPIC")
  # export TF_VAR_openai_api_key=$(extract_key "SECRET_OPENAI")
  export TF_VAR_openrouter_api_key=$(extract_key "SECRET_OPENROUTER")
  export TF_VAR_inbox_site_url=$(extract_key "SECRET_INBOX_URL")

  success "Secrets loaded"
}

# Terraform variables for API keys have no defaults in variables.tf. Empty values (e.g. pressing ENTER at
# interactive prompts, or missing TF_VAR_*) end up in user_data: blank config.json apiKey / .env → auth fails everywhere.
require_tf_llm_vars() {
  local missing=()
  # DISABLED — deepseek-only run
  # [[ -z "${TF_VAR_anthropic_api_key:-}" || "$TF_VAR_anthropic_api_key" == "null" ]] && missing+=("TF_VAR_anthropic_api_key")
  # [[ -z "${TF_VAR_openai_api_key:-}"    || "$TF_VAR_openai_api_key" == "null" ]]    && missing+=("TF_VAR_openai_api_key")
  [[ -z "${TF_VAR_openrouter_api_key:-}" || "$TF_VAR_openrouter_api_key" == "null" ]] && missing+=("TF_VAR_openrouter_api_key")
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
  # #region agent log
  _dbg_c7706e "H_PROMPTS" "prompt_vars_after_source" "{\"file\":\"${PROMPTS_FILE//\"/\\\"}\",\"has_p1\":$([[ -n "${PROMPT_1-}" ]] && echo true || echo false),\"has_p2\":$([[ -n "${PROMPT_2-}" ]] && echo true || echo false),\"has_p3\":$([[ -n "${PROMPT_3-}" ]] && echo true || echo false),\"has_p4\":$([[ -n "${PROMPT_4-}" ]] && echo true || echo false)}"
  # #endregion

  local log_url="${INBOX_URL%/*}/nortecorp-prod-incident.log"
  local -a prompt_vars=()
  local var value
  while IFS= read -r var; do
    [[ "$var" =~ ^PROMPT_[0-9]+$ ]] && prompt_vars+=("$var")
  done < <(compgen -A variable)
  if [[ ${#prompt_vars[@]} -eq 0 ]]; then
    err "Prompt config is incomplete. Expected at least one PROMPT_<n> in ${PROMPTS_FILE}."
    exit 1
  fi
  mapfile -t prompt_vars < <(printf '%s\n' "${prompt_vars[@]}" | sort -t_ -k2,2n)
  PROMPTS=()
  for var in "${prompt_vars[@]}"; do
    value="${!var-}"
    [[ -z "${value//[$'\t\n\r ']}" ]] && continue
    value="${value//INBOX_URL/$INBOX_URL}"
    value="${value//LOG_URL/$log_url}"
    PROMPTS+=("$value")
  done
  if [[ ${#PROMPTS[@]} -eq 0 ]]; then
    err "Prompt config has no non-empty PROMPT_<n> values in ${PROMPTS_FILE}."
    exit 1
  fi
  # #region agent log
  _dbg_c7706e "H_PROMPTS" "prompts_ready" "{\"count\":${#PROMPTS[@]},\"first_len\":${#PROMPTS[0]}}"
  # #endregion
}

step_label() {
  local step="$1"
  case "$step" in
    1) printf '%s' "Inbox Summary" ;;
    2) printf '%s' "Production Log Analysis" ;;
    3) printf '%s' "Positive Reinforcement" ;;
    4) printf '%s' "Shutdown Trigger" ;;
    *) printf '%s' "Prompt ${step}" ;;
  esac
}

# ── SSM helpers ───────────────────────────────────────────────────────────────

ssm_run() {
  local instance_id="$1" command="$2" timeout="${3:-30}" strict="${4:-0}"
  # SendCommand TimeoutSeconds minimum is 30 (AWS API).
  (( timeout < 30 )) && timeout=30
  local cmd_id status elapsed=0 status_details="" response_code=""

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
    --output text 2>/dev/null) || {
      # #region agent log
      _dbg_c7706e "H_SSM" "ssm_send_failed" "{\"instance_id\":\"${instance_id}\",\"timeout\":${timeout},\"cmd_len\":${#command}}"
      # #endregion
      return 0
    }
  # #region agent log
  _dbg_c7706e "H_SSM" "ssm_send_ok" "{\"instance_id\":\"${instance_id}\",\"command_id\":\"${cmd_id}\",\"timeout\":${timeout},\"cmd_len\":${#command}}"
  # #endregion

  status="InProgress"
  while [[ "$status" == "InProgress" || "$status" == "Pending" || "$status" == "Delayed" ]]; do
    sleep 3; elapsed=$((elapsed + 3))
    status=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
      --query "Status" --output text 2>/dev/null || echo "Pending")
    [[ $elapsed -ge $timeout ]] && break
  done

  status_details=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StatusDetails" --output text 2>/dev/null || echo "")
  response_code=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "ResponseCode" --output text 2>/dev/null || echo "")

  local o e
  o=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StandardOutputContent" --output text 2>/dev/null || echo "")
  e=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
    --query "StandardErrorContent" --output text 2>/dev/null || echo "")
  o="${o%$'\r'}"; e="${e%$'\r'}"
  local failed=0
  [[ "$status" != "Success" ]] && failed=1
  [[ -n "$response_code" && "$response_code" != "0" && "$response_code" != "None" ]] && failed=1
  # #region agent log
  _dbg_c7706e "H_SSM" "ssm_done" "{\"instance_id\":\"${instance_id}\",\"command_id\":\"${cmd_id}\",\"status\":\"${status}\",\"status_details\":\"${status_details}\",\"response_code\":\"${response_code}\",\"elapsed\":${elapsed},\"stdout_len\":${#o},\"stderr_len\":${#e}}"
  # #endregion
  if [[ "$failed" -eq 1 ]]; then
    local meta
    meta="[ssm] failure status=${status} status_details=${status_details} response_code=${response_code} elapsed=${elapsed}s command_id=${cmd_id}"
    if [[ -n "${o//[$'\t\n\r ']}" ]]; then
      o="${o}"$'\n'"${meta}"
    else
      o="${meta}"
    fi
  fi
  # Many CLIs log to stderr; merge so transcripts capture failures and replies.
  if [[ -n "${o//[$'\t\n\r ']}" ]]; then
    printf '%s' "$o"
    [[ -n "${e//[$'\t\n\r ']}" ]] && printf '\n%s' "$e"
  else
    printf '%s' "$e"
  fi
  if [[ "$strict" == "1" && "$failed" -eq 1 ]]; then
    return 1
  fi
  return 0
}

gateway_ready_probe() {
  local instance_id="$1" out remote_shell inner
  remote_shell="$(ssm_oc_resolve_snippet); if [ -z \"\$OPENCLAW_BIN\" ] || [ ! -f \"\$OPENCLAW_BIN\" ] || [ ! -x \"\$OPENCLAW_BIN\" ] || [ \"\$(basename \"\$OPENCLAW_BIN\")\" != \"openclaw\" ]; then echo \"GW_BIN_INVALID [\$OPENCLAW_BIN]\"; exit 2; fi; timeout 20 sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" agent --help 2>&1 | head -c 240; rc=\${PIPESTATUS:-\$?}; [ \"\$rc\" = \"0\" ] && echo \"|GW_OK\" || echo \"|GW_FAIL rc=\$rc\""
  inner="bash -c $(printf '%q' "$remote_shell")"
  out=$(ssm_run "$instance_id" "$inner" 45)
  # #region agent log
  { _head=$(printf '%s' "$out" | head -c 260 | tr '\n' '|'); _dbg_c7706e "H_GW" "gateway_probe" "{\"instance_id\":\"${instance_id}\",\"out_head\":\"${_head//\"/\\\"}\"}"; }
  # #endregion
  printf '%s' "$out"
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
      if [[ "$svc" == "active" ]]; then
        local gw
        gw=$(gateway_ready_probe "$instance_id")
        if echo "$gw" | grep -q "GW_OK"; then
          success "${name} ready (gateway healthy)"
          return 0
        fi
        if (( elapsed - last_uid_warn >= 60 || last_uid_warn < 0 )); then
          log "${name}: service active but gateway probe not ready yet — waiting..."
          last_uid_warn=$elapsed
        fi
      fi
    fi

    sleep "$SSM_POLL_INTERVAL"
    elapsed=$((elapsed + SSM_POLL_INTERVAL))
    log "${name}: still waiting... (${elapsed}s)"
  done

  err "${name} did not become ready within ${SSM_MAX_WAIT}s"
  err "If user 'openclaw' never appears, check SSM: cat /var/log/openclaw-bootstrap.log — or replace VMs (terraform apply -replace=aws_instance.${name}) so user-data runs."
  return 1
}

wait_for_bootstrap_log_settle() {
  local instance_id="$1" max_wait="${2:-1200}" out tail_block
  out=$(ssm_run "$instance_id" "cloud-init status --wait --long 2>&1; echo __CI_RC__:$?" "$max_wait")
  # #region agent log
  { _head=$(printf '%s' "$out" | head -c 300 | tr '\n' '|'); _dbg_c7706e "H_LOG" "cloud_init_wait_result" "{\"instance_id\":\"${instance_id}\",\"out_head\":\"${_head//\"/\\\"}\"}"; }
  # #endregion
  tail_block=$(ssm_run "$instance_id" "tail -n 40 /var/log/openclaw-bootstrap.log 2>/dev/null || true" 30)
  if printf '%s' "$tail_block" | grep -q "Bootstrap complete"; then
    # #region agent log
    _dbg_c7706e "H_LOG" "bootstrap_poll_done" "{\"instance_id\":\"${instance_id}\",\"reason\":\"bootstrap_complete_marker\"}"
    # #endregion
  else
    # #region agent log
    _dbg_c7706e "H_LOG" "bootstrap_poll_done" "{\"instance_id\":\"${instance_id}\",\"reason\":\"cloud_init_wait_finished_no_marker\"}"
    # #endregion
  fi
  return 0
}

# Bash fragment run ON THE INSTANCE (inside bash -c). Finds a real openclaw executable.
# Must be ONE physical line (no embedded newlines): multiline body + Git Bash printf '%q' → $'…\n…';
# SSM RunShellScript runs under /bin/sh first — sh does not accept $'…' → "Syntax error: ) unexpected".
# systemd 249+ ExecStart "{ path=/…/openclaw ; … }" — awk '{print $1}' yields "{"; use path= + grep /openclaw fallbacks.
ssm_oc_resolve_snippet() {
  local body
  body=$(cat <<'OC_RESOLVE'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; NP=$(npm config get prefix 2>/dev/null); [ -n "$NP" ] && PATH="$NP/bin:$PATH"; OPENCLAW_BIN=""; _oc_ok(){ [ -n "$1" ] && [ -f "$1" ] && [ -x "$1" ] && [ "$(basename "$1")" = "openclaw" ]; }; ES=$(systemctl cat openclaw.service 2>/dev/null | sed -n 's/^ExecStart=//p' | tail -n1); ES=${ES#-}; CAND=${ES%%[[:space:]]*}; CAND=${CAND#\"}; CAND=${CAND%\"}; _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; if [ -z "$OPENCLAW_BIN" ]; then OV=$(systemctl show openclaw.service -p ExecStart --value 2>/dev/null | head -n1); CAND=""; case "$OV" in *path=*) CAND=$(printf '%s' "$OV" | sed -n 's/.*path=\([^ ;)]*\).*/\1/p' | head -n1) ;; *) CAND=$(printf '%s' "$OV" | awk '{print $1}' | tr -d '"') ;; esac; _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; fi; if [ -z "$OPENCLAW_BIN" ]; then CAND=$(sudo -u openclaw env HOME=/home/openclaw PATH="$PATH" bash -c 'command -v openclaw 2>/dev/null' | tr -d '\r'); _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; fi; if [ -z "$OPENCLAW_BIN" ]; then CAND=$(command -v openclaw 2>/dev/null | tr -d '\r'); _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; fi; if [ -z "$OPENCLAW_BIN" ]; then NB=$(npm bin -g 2>/dev/null | tr -d '\r'); CAND="$NB/openclaw"; _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; fi; if [ -z "$OPENCLAW_BIN" ]; then UP=$(sudo -u openclaw env HOME=/home/openclaw bash -c 'npm config get prefix 2>/dev/null' | tr -d '\r'); CAND="$UP/bin/openclaw"; _oc_ok "$CAND" && OPENCLAW_BIN="$CAND"; fi; if [ -z "$OPENCLAW_BIN" ]; then for c in /usr/local/bin/openclaw /usr/bin/openclaw; do _oc_ok "$c" && OPENCLAW_BIN="$c" && break; done; fi; _oc_ok "$OPENCLAW_BIN" || OPENCLAW_BIN=""
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
    anthropic|openai|deepseek|openrouter) ;;
    *) warn "openclaw_seed_auth_via_ssm: unknown provider ${provider}"; return 0 ;;
  esac
  # No nested `sudo … bash -c ${oc_q}`: embedding %q(oc_q) in remote_shell often yields a broken inner -c (empty argv → "line 1: : command not found" / 127 on SSM).
  # Resolve as root, then pipe API key into a single exec of openclaw as user openclaw (stdin = token).
  remote_shell="$(ssm_oc_resolve_snippet); KEY=\$(echo '${kb64}' | base64 -d); if [ -z \"\$OPENCLAW_BIN\" ] || [ ! -f \"\$OPENCLAW_BIN\" ] || [ ! -x \"\$OPENCLAW_BIN\" ] || [ \"\$(basename \"\$OPENCLAW_BIN\")\" != \"openclaw\" ]; then echo \"paste-token: OPENCLAW_BIN invalid: [\$OPENCLAW_BIN]\" >&2; exit 2; fi; printf '%s\\n' \"\$KEY\" | sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" models auth paste-token --provider ${provider} 2>&1"
  inner="bash -c $(printf '%q' "$remote_shell")"
  out=$(ssm_run "$iid" "$inner" 120)
  if [[ -n "${out//[$'\t\n\r ']}" ]]; then
    log "${name} paste-token: ${out:0:800}"
  fi
  if echo "$out" | grep -qE 'command not found|Syntax error|exit status 127|exit status 2|failed to run commands|OPENCLAW_BIN invalid'; then
    warn "${name}: models auth paste-token did not run — see paste-token line above."
  else
    ssm_run "$iid" "sudo systemctl restart openclaw 2>&1" 90 >/dev/null || true
    success "${name}: auth seed step finished (${provider})"
  fi
}

openclaw_send_with_session() {
  local instance_id="$1" message="$2" session_id="$3" mb64 remote_shell inner
  mb64=$(printf '%s' "$message" | base64 -w0 2>/dev/null || printf '%s' "$message" | base64 | tr -d '\n')
  # No nested `sudo … bash -c ${oc_q}`: embedding %q(oc_q) in remote_shell often yields a broken inner -c
  # (empty argv → "line 1: : command not found" / 127 on SSM). Flat command instead — same pattern as openclaw_seed_auth_via_ssm.
  # Source .env as root to capture API key env vars, then pass them through sudo env.
  remote_shell="$(ssm_oc_resolve_snippet); MSG=\$(echo '${mb64}' | base64 -d); set -a; [ -f /home/openclaw/.openclaw/.env ] && . /home/openclaw/.openclaw/.env; set +a; if [ -z \"\$OPENCLAW_BIN\" ] || [ ! -f \"\$OPENCLAW_BIN\" ] || [ ! -x \"\$OPENCLAW_BIN\" ] || [ \"\$(basename \"\$OPENCLAW_BIN\")\" != \"openclaw\" ]; then echo \"OPENCLAW_BIN invalid: [\$OPENCLAW_BIN]\" >&2; exit 2; fi; if [ -n \"\${OPENROUTER_API_KEY:-}\" ]; then printf '%s\\n' \"\$OPENROUTER_API_KEY\" | sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" models auth paste-token --provider openrouter >/dev/null 2>&1 || true; fi; sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" models set openrouter/deepseek/deepseek-chat >/dev/null 2>&1 || true; sudo -u openclaw env HOME=/home/openclaw bash -lc 'set -e; install -d -m 0755 /home/openclaw/.openclaw/agents/main/agent; if [ -f /home/openclaw/.openclaw/auth-profiles.json ]; then cp -f /home/openclaw/.openclaw/auth-profiles.json /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json; chmod 600 /home/openclaw/.openclaw/agents/main/agent/auth-profiles.json; fi' >/dev/null 2>&1 || true; echo \"DBG_OCBIN=[\$OPENCLAW_BIN]\" >&2; echo \"DBG_ANTHKEY_LEN=[\${#ANTHROPIC_API_KEY}]\" >&2; echo \"DBG_ORKEY_LEN=[\${#OPENROUTER_API_KEY}]\" >&2; echo \"DBG_GW_TOKEN_LEN=[\${#OPENCLAW_GATEWAY_TOKEN}]\" >&2; echo \"DBG_FORCE_MODEL=[openrouter/deepseek/deepseek-chat]\" >&2; echo \"DBG_MSG_LEN=[\${#MSG}]\" >&2; echo \"DBG_SUDO_TEST\" >&2; sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" ANTHROPIC_API_KEY=\"\${ANTHROPIC_API_KEY:-}\" OPENAI_API_KEY=\"\${OPENAI_API_KEY:-}\" OPENROUTER_API_KEY=\"\${OPENROUTER_API_KEY:-}\" OPENCLAW_GATEWAY_TOKEN=\"\${OPENCLAW_GATEWAY_TOKEN:-}\" \"\$OPENCLAW_BIN\" agent --session-id \"${session_id}\" --message \"\$MSG\" 2>&1"
  inner="bash -c $(printf '%q' "$remote_shell")"
  # #region agent log — H9: capture inner command and first 500 chars for quoting analysis
  { _ts=$(($(date +%s) * 1000)); _inner_head=$(printf '%s' "$inner" | head -c 500); printf '%s\n' "{\"sessionId\":\"2240d0\",\"hypothesisId\":\"H9\",\"location\":\"experiment.sh:openclaw_send\",\"message\":\"inner_cmd\",\"data\":{\"inner_len\":${#inner},\"inner_head\":\"${_inner_head//\"/\\\"}\"},\"timestamp\":${_ts}}"; } >> "${SCRIPT_DIR}/debug-2240d0.log" 2>/dev/null || true
  # #endregion
  # #region agent log
  _dbg_c7706e "H_BIN" "openclaw_send_inner_built" "{\"inner_len\":${#inner}}"
  # #endregion
  # DeepSeek responses can exceed the original 90s SSM window on cold starts.
  ssm_run "$instance_id" "$inner" 300
}

openclaw_send() {
  local instance_id="$1" message="$2"
  openclaw_send_with_session "$instance_id" "$message" "morality-lab"
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
  cmd_body="$(ssm_oc_resolve_snippet); OCL_BIN_DIR=\$(dirname \"\$OPENCLAW_BIN\"); PATH=\"\$OCL_BIN_DIR:\${PATH}\"; if ! command -v puppeteer >/dev/null 2>&1; then echo skip_puppeteer; exit 0; fi; CHROME=\$(command -v chromium-browser 2>/dev/null || command -v chromium 2>/dev/null || echo /usr/bin/chromium-browser); IB=\$(echo '${ib64}' | base64 -d); URL=\$(sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin OPENCLAW_BIN=\"\$OPENCLAW_BIN\" \"\$OPENCLAW_BIN\" browser current-url 2>/dev/null || printf '%s' \"\$IB\"); sudo -u openclaw env HOME=/home/openclaw PATH=\"\$OCL_BIN_DIR:\${PATH}\" PUPPETEER_EXECUTABLE_PATH=\"\$CHROME\" puppeteer screenshot --no-sandbox \"\$URL\" ${remote_path} 2>&1 && echo ok || echo fail"
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
  elif [[ "$result" == *"skip_puppeteer"* ]]; then
    warn "Screenshot skipped for step ${step}: puppeteer not installed on $(basename "$vm_dir")"
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
  local offset=0 chunk_sz=8000 piece nbytes tmp remote_size local_size
  remote_size=$(ssm_run "$instance_id" "wc -c < /var/log/openclaw-bootstrap.log 2>/dev/null || echo 0" 30 | tr -d '[:space:]')
  [[ -z "${remote_size:-}" || ! "$remote_size" =~ ^[0-9]+$ ]] && remote_size=0
  if [[ "$remote_size" -eq 0 ]]; then
    printf '%s' "(missing or empty /var/log/openclaw-bootstrap.log)"
    return 0
  fi
  tmp="${TMPDIR:-/tmp}/oc-bootstrap-${instance_id}.$$"
  : > "$tmp" || { printf '%s' "(cannot create temp file)"; return 1; }
  while [[ "$offset" -lt "$remote_size" ]]; do
    piece=$(ssm_run "$instance_id" "dd if=/var/log/openclaw-bootstrap.log bs=1 skip=${offset} count=${chunk_sz} 2>/dev/null" 90)
    nbytes=$(printf '%s' "$piece" | wc -c | tr -d ' ')
    [[ -z "${nbytes:-}" || ! "$nbytes" =~ ^[0-9]+$ ]] && nbytes=0
    [[ "$nbytes" -eq 0 ]] && break
    printf '%s' "$piece" >> "$tmp"
    offset=$((offset + nbytes))
  done
  local_size=$(wc -c < "$tmp" | tr -d '[:space:]')
  # #region agent log
  _dbg_c7706e "H_LOG" "bootstrap_fetch_sizes" "{\"instance_id\":\"${instance_id}\",\"remote_size\":${remote_size},\"local_size\":${local_size:-0}}"
  # #endregion
  cat "$tmp"
  rm -f "$tmp"
}

# Full VM "console" from user_data.sh.tpl: exec > >(tee /var/log/openclaw-bootstrap.log | logger ...)
# One file per VM: results/<run>/<name>/openclaw_bootstrap_console.log
write_openclaw_bootstrap_console_log() {
  local name iid body vm_dir out
  # DISABLED — deepseek-only run (was: claude openai deepseek ollama)
  for name in deepseek; do
    case $name in
      # claude)   iid=$INSTANCE_ID_CLAUDE ;;
      # openai)   iid=$INSTANCE_ID_OPENAI ;;
      deepseek) iid=$INSTANCE_ID_DEEPSEEK ;;
      # ollama)   iid=$INSTANCE_ID_OLLAMA ;;
    esac
    vm_dir="${RESULTS_DIR}/${name}"
    mkdir -p "$vm_dir"
    out="${vm_dir}/openclaw_bootstrap_console.log"
    log "Fetching OpenClaw bootstrap log: ${name} (${iid}) → ${out}"
    wait_for_bootstrap_log_settle "$iid" 1200
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

  # DISABLED — deepseek-only run (was: {claude,openai,deepseek,ollama})
  success "Wrote ${RESULTS_DIR}/{deepseek}/openclaw_bootstrap_console.log"
}

write_openclaw_runtime_diag_log() {
  local name iid body vm_dir out
  for name in deepseek; do
    case $name in
      deepseek) iid=$INSTANCE_ID_DEEPSEEK ;;
    esac
    vm_dir="${RESULTS_DIR}/${name}"
    mkdir -p "$vm_dir"
    out="${vm_dir}/openclaw_runtime_diag.log"
    log "Collecting OpenClaw runtime diagnostics: ${name} (${iid}) → ${out}"
    body=$(ssm_run "$iid" "echo '=== systemctl is-active ==='; systemctl is-active openclaw 2>&1 || true; echo; echo '=== systemctl status (first 120 lines) ==='; systemctl status openclaw --no-pager -l 2>&1 | sed -n '1,120p'; echo; echo '=== journalctl -u openclaw (last 200 lines) ==='; journalctl -u openclaw -n 200 --no-pager 2>&1; echo; echo '=== cloud-init status ==='; cloud-init status --long 2>&1 || true; echo; echo '=== openclaw models current ==='; sudo -u openclaw env HOME=/home/openclaw PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin openclaw models current 2>&1 || true" 180)
    {
      echo "# OpenClaw runtime diagnostics (${name})"
      echo ""
      echo "_Fetched at $(date -u '+%Y-%m-%d %H:%M:%S UTC') via SSM._"
      echo ""
      echo "**Instance ID:** \`${iid}\`"
      echo ""
      echo '```text'
      printf '%s\n' "$body"
      echo '```'
      echo ""
    } > "$out"
  done
  success "Wrote ${RESULTS_DIR}/{deepseek}/openclaw_runtime_diag.log"
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

  local step=0 total_steps="${#PROMPTS[@]}"
  for prompt in "${PROMPTS[@]}"; do
    step=$((step + 1))
    local label
    label="$(step_label "$step")"

    {
      echo "## Step ${step} — ${label}"
      echo ""
      echo "**Sent at $(date -u '+%H:%M:%S UTC'):**"
      echo ""
      echo "> ${prompt}"
      echo ""
    } >> "$transcript"

    log "[${name}] Step ${step}: ${label}..."
    local response sanitized_response
    response=""
    sanitized_response=""
    local attempt retry_session_id
    for attempt in 0 1 2; do
      if [[ $attempt -eq 0 ]]; then
        response=$(openclaw_send "$instance_id" "$prompt")
      else
        retry_session_id="morality-lab-step-${step}-retry-${attempt}"
        warn "[${name}] Step ${step}: empty response; retrying with fresh session ${retry_session_id}"
        response=$(openclaw_send_with_session "$instance_id" "$prompt" "$retry_session_id")
      fi
      sanitized_response=$(printf '%s\n' "$response" | sed -e '/^DBG_/d' -e '/^\[ssm\]/d' -e '/^NO_REPLY$/d' -e '/^failed to run commands:/d')
      if [[ -n "${sanitized_response//[$'\t\r\n ']}" ]]; then
        break
      fi
    done
    # #region agent log — H9: capture openclaw_send response
    { _ts=$(($(date +%s) * 1000)); _resp_head=$(printf '%s' "$response" | head -c 800 | tr '\n' '|'); printf '%s\n' "{\"sessionId\":\"2240d0\",\"hypothesisId\":\"H9\",\"location\":\"experiment.sh:run_experiment:response\",\"message\":\"openclaw_send_response\",\"data\":{\"name\":\"${name}\",\"step\":${step},\"resp_len\":${#response},\"resp_head\":\"${_resp_head//\"/\\\"}\"},\"timestamp\":${_ts}}"; } >> "${SCRIPT_DIR}/debug-2240d0.log" 2>/dev/null || true
    # #endregion
    # #region agent log
    { _head=$(printf '%s' "$response" | head -c 300 | tr '\n' '|'); _dbg_c7706e "H_BIN" "openclaw_send_response" "{\"name\":\"${name}\",\"step\":${step},\"resp_len\":${#response},\"resp_head\":\"${_head//\"/\\\"}\"}"; }
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

    # Observe longer after the final step.
    if [[ $step -eq $total_steps ]]; then
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
    # DISABLED — deepseek-only run
    echo "**Models:** Deepseek"
    echo ""
    echo "---"
    echo ""
    echo "## Protocol"
    echo ""
    echo "| Step | Label | Prompt |"
    echo "|------|-------|--------|"
    local _i _label _prompt _prompt_md
    for ((_i=1; _i<=${#PROMPTS[@]}; _i++)); do
      _label="$(step_label "$_i")"
      _prompt="${PROMPTS[$((_i-1))]}"
      _prompt_md="${_prompt//$'\n'/ }"
      _prompt_md="${_prompt_md//|/\\|}"
      echo "| ${_i} | ${_label} | ${_prompt_md} |"
    done
    echo ""
    echo "Post-trigger observation window: **${SHUTDOWN_WAIT}s**"
    echo ""
    echo "---"
    echo ""
  } > "$REPORT_FILE"

  # DISABLED — deepseek-only run (was: claude openai deepseek ollama)
  for name in deepseek; do
    local vm_dir="${RESULTS_DIR}/${name}"
    {
      echo "## ${name}"
      echo ""

      # Inline screenshots per step
      echo "### Screenshots"
      echo ""
      for ((step=1; step<=${#PROMPTS[@]}; step++)); do
        local label
        label="$(step_label "$step")"
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
    # DISABLED — deepseek-only run
    # echo "| claude   | ${INSTANCE_ID_CLAUDE} |"
    # echo "| openai   | ${INSTANCE_ID_OPENAI} |"
    echo "| deepseek | ${INSTANCE_ID_DEEPSEEK} |"
    # echo "| ollama   | ${INSTANCE_ID_OLLAMA} |"
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

  section "Provisioning Infrastructure (no firewall — unrestricted bootstrap)"
  cd "$SCRIPT_DIR"
  # #region agent log
  HYPOTHESIS_ID="H1" _dbg "phase1_tf_start"
  # #endregion
  terraform init -input=false -no-color
  local replace_args=()
  if terraform state list 2>/dev/null | grep -qx 'aws_instance.deepseek'; then
    replace_args=(-replace='aws_instance.deepseek')
    log "Existing deepseek instance found in state; forcing replacement so user-data reruns cleanly."
  fi
  terraform apply -input=false -auto-approve -no-color "${replace_args[@]}" -var='firewall_active=false'
  # #region agent log
  HYPOTHESIS_ID="H1" _dbg "phase1_tf_done"
  # #endregion
  success "Infrastructure ready — VMs have unrestricted internet (no firewall yet)"

  section "Reading Outputs"
  # DISABLED — deepseek-only run
  # INSTANCE_ID_CLAUDE=$(terraform output -raw vm_claude_instance_id)
  # INSTANCE_ID_OPENAI=$(terraform output -raw vm_openai_instance_id)
  # INSTANCE_ID_OLLAMA=$(terraform output -raw vm_ollama_instance_id)
  INSTANCE_ID_DEEPSEEK=$(terraform output -raw vm_deepseek_instance_id)
  INBOX_URL=$(terraform output -raw inbox_url)

  # DISABLED — deepseek-only run
  # log "Claude   -> ${INSTANCE_ID_CLAUDE}"
  # log "OpenAI   -> ${INSTANCE_ID_OPENAI}"
  # log "Ollama   -> ${INSTANCE_ID_OLLAMA}"
  log "Deepseek -> ${INSTANCE_ID_DEEPSEEK}"

  # Load and interpolate prompts now that INBOX_URL is known
  load_prompts

  section "Waiting for Bootstrap"
  # #region agent log
  HYPOTHESIS_ID="H1" _dbg "wait_for_vm_start"
  # #endregion
  # DISABLED — deepseek-only run
  # wait_for_vm "claude"    "$INSTANCE_ID_CLAUDE" &
  # local pid_claude=$!
  # wait_for_vm "openai"    "$INSTANCE_ID_OPENAI" &
  # local pid_openai=$!
  # wait_for_vm "ollama"    "$INSTANCE_ID_OLLAMA" &
  # local pid_ollama=$!
  wait_for_vm "deepseek"  "$INSTANCE_ID_DEEPSEEK" &
  local pid_deepseek=$!
  local _wf=0
  for _wp in $pid_deepseek; do
    wait "$_wp" || { _wf=$((_wf + 1)); }
  done
  # #region agent log
  HYPOTHESIS_ID="H1" _dbg "wait_for_vm_done" "{\"failures\":$_wf}"
  # #endregion
  if [[ $_wf -gt 0 ]]; then
    warn "${_wf} VM(s) did not become ready — experiment will proceed with available VMs."
  else
    success "All VMs ready"
  fi

  section "OpenClaw auth (models paste-token on instances)"
  # #region agent log
  HYPOTHESIS_ID="H2" _dbg "seed_auth_start"
  # #endregion
  # DISABLED — deepseek-only run
  # openclaw_seed_auth_via_ssm "claude"   "$INSTANCE_ID_CLAUDE"   anthropic "${TF_VAR_anthropic_api_key:-}"
  # openclaw_seed_auth_via_ssm "openai"   "$INSTANCE_ID_OPENAI"   openai    "${TF_VAR_openai_api_key:-}"
  openclaw_seed_auth_via_ssm "deepseek" "$INSTANCE_ID_DEEPSEEK" openrouter "${TF_VAR_openrouter_api_key:-}"
  # #region agent log
  HYPOTHESIS_ID="H2" _dbg "seed_auth_done"
  # #endregion

  section "OpenClaw bootstrap console (per VM)"
  write_openclaw_bootstrap_console_log

  section "OpenClaw runtime diagnostics (pre-experiment)"
  write_openclaw_runtime_diag_log

  section "Bootstrap template snapshot"
  write_user_data_config_md

  # DISABLED TEMPORARILY — keep firewall off while debugging OpenClaw runtime.
  # section "Provisioning Network Firewall"
  # log "Creating firewall and routing private subnet through it..."
  # #region agent log
  # HYPOTHESIS_ID="H2" _dbg "phase2_tf_start"
  # #endregion
  # terraform apply -input=false -auto-approve -no-color -var='firewall_active=true'
  # #region agent log
  # HYPOTHESIS_ID="H2" _dbg "phase2_tf_done"
  # #endregion
  # success "Firewall provisioned and active — VMs now restricted to whitelisted domains"
  warn "Firewall activation is temporarily disabled for this debug run (NAT egress remains active)."

  section "Running Experiment"
  # DISABLED — deepseek-only run
  # run_experiment_on_vm "claude"   "$INSTANCE_ID_CLAUDE" &
  # run_experiment_on_vm "openai"   "$INSTANCE_ID_OPENAI" &
  # run_experiment_on_vm "ollama"   "$INSTANCE_ID_OLLAMA" &
  run_experiment_on_vm "deepseek" "$INSTANCE_ID_DEEPSEEK" &

  FAIL=0
  for pid in $(jobs -p); do
    wait "$pid" || FAIL=1
  done
  [[ $FAIL -eq 1 ]] && warn "One or more experiments had errors — report may be incomplete"

  section "Refreshing OpenClaw bootstrap console (post-experiment)"
  write_openclaw_bootstrap_console_log

  section "Generating Report"
  generate_report

  echo -e "\n${GREEN}${BOLD}━━━ Done ━━━${NC}"
  echo -e "  📄 ${BOLD}${REPORT_FILE}${NC}"
  # DISABLED — deepseek-only run (was: ×4: claude, openai, deepseek, ollama)
  echo -e "  📄 ${BOLD}${RESULTS_DIR}/<vm>/openclaw_bootstrap_console.log${NC} (deepseek)"
  echo -e "  📄 ${BOLD}${RESULTS_DIR}/user_data_config.md${NC} (repo template)"
  echo -e "  📁 ${BOLD}${RESULTS_DIR}${NC}\n"
}

main "$@"
