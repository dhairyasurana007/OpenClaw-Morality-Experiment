#!/usr/bin/env bash
# Idempotent create: ResourceAlreadyExistsException is ignored; retention is always applied.
set -euo pipefail

# Git Bash must not rewrite /aws/... or /openclaw/... log group names (see destroy-cw-log-groups.sh).
export MSYS2_ARG_CONV_EXCL="${MSYS2_ARG_CONV_EXCL:-*}"

REGION="$1"
RETENTION="$2"
shift 2
for name in "$@"; do
  [[ -z "$name" ]] && continue
  aws logs create-log-group --log-group-name "$name" --region "$REGION" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "$name" --retention-in-days "$RETENTION" --region "$REGION"
done
