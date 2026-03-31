#!/usr/bin/env bash
# Delete every CloudWatch log group this experiment creates (best-effort).
# Usage: destroy-cw-log-groups.sh <region> [project]
# Default project matches variables.tf (openclaw-exp). Requires aws CLI; uses jq if present for pagination.
set -euo pipefail

# Git Bash maps arguments that start with / to paths under its install dir (e.g. /openclaw/... → C:/Program Files/Git/...).
# AWS log group names must keep a leading slash; disable MSYS path conversion for this process.
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:-*}"

REGION="${1:?Usage: $0 <aws-region> [project]}"
PROJECT="${2:-openclaw-exp}"

delete_lg() {
  aws logs delete-log-group --log-group-name "$1" --region "$REGION" 2>/dev/null || true
}

# From main.tf: VPC flow logs + Network Firewall alerts
delete_lg "/aws/vpc/${PROJECT}-flow-logs"
delete_lg "/aws/network-firewall/${PROJECT}-alerts"

# Legacy gateway paths (before paths included ${project})
for model in claude openai ollama deepseek; do
  delete_lg "/openclaw/${model}/gateway"
done

# All groups under /openclaw/<project>/ (gateway + any future names)
list_prefix_groups() {
  local prefix="$1"
  if command -v jq >/dev/null 2>&1; then
    local resp next_token=""
    while true; do
      if [[ -z "$next_token" ]]; then
        resp=$(aws logs describe-log-groups --region "$REGION" \
          --log-group-name-prefix "$prefix" --output json)
      else
        resp=$(aws logs describe-log-groups --region "$REGION" \
          --log-group-name-prefix "$prefix" --next-token "$next_token" --output json)
      fi
      while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        delete_lg "$n"
      done < <(echo "$resp" | jq -r '.logGroups[].logGroupName // empty')
      next_token=$(echo "$resp" | jq -r '.nextToken // empty')
      [[ -z "$next_token" ]] && break
    done
  else
    aws logs describe-log-groups --region "$REGION" \
      --log-group-name-prefix "$prefix" \
      --query 'logGroups[].logGroupName' --output text 2>/dev/null |
      tr '\t' '\n' |
      while IFS= read -r n; do
        [[ -z "$n" || "$n" == "None" ]] && continue
        delete_lg "$n"
      done
  fi
}

list_prefix_groups "/openclaw/${PROJECT}/"
