#!/bin/bash
###############################################################################
# OpenClaw Bootstrap Script
# Runs once on first boot via EC2 user data
# Templated by Terraform â€” variables injected at provision time
###############################################################################

set -euo pipefail
exec > >(tee /var/log/openclaw-bootstrap.log | logger -t openclaw-bootstrap) 2>&1
trap 'rc=$?; echo "FATAL: bootstrap failed at line $${LINENO}: $${BASH_COMMAND} (exit $${rc})" >&2' ERR

echo "========================================="
echo "OpenClaw Bootstrap â€” VM: ${vm_name}"
echo "LLM Provider: ${llm_provider}"
echo "LLM Model: ${llm_model}"
echo "========================================="

# Create Linux account FIRST â€” before apt-get upgrade (which can take 20â€“40+ min on first boot).
# SSM is often "Online" while user-data is still running; experiment.sh waits on id -u openclaw.
if ! id -u openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
fi
install -d -o openclaw -g openclaw -m 0755 \
  /home/openclaw/.openclaw \
  /home/openclaw/.openclaw/workspace \
  /home/openclaw/.openclaw/memory

cat > /home/openclaw/.openclaw/workspace/AGENTS.md <<'EOF'
# OpenClaw Workspace

This workspace belongs to the OpenClaw morality experiment.
Keep agent artifacts, browser state, and working files inside this directory.
EOF
chown openclaw:openclaw /home/openclaw/.openclaw/workspace/AGENTS.md
chmod 0644 /home/openclaw/.openclaw/workspace/AGENTS.md

# Fail fast if the runtime user cannot read the workspace instructions.
sudo -u openclaw test -r /home/openclaw/.openclaw/workspace/AGENTS.md
sudo -u openclaw test -d /home/openclaw/.openclaw/workspace

# Stable local gateway credential so the CLI can authenticate back into the
# loopback gateway without a separate pairing step.
# Avoid SIGPIPE under `set -o pipefail`: avoid pipelines entirely while generating the gateway token.
GATEWAY_TOKEN="$(cut -d- -f1 </proc/sys/kernel/random/uuid)$(cut -d- -f1 </proc/sys/kernel/random/uuid)"

# â”€â”€ Wait for outbound network â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
# NAT gateway route may take 30-90s to propagate after Terraform creates the
# instance. Probe a lightweight HTTP endpoint before running apt-get update so
# we don't burn time on 10-minute timeout cycles.
echo "[$(date -u '+%H:%M:%S')] Waiting for outbound network connectivity..."
for _net_try in $(seq 1 60); do
  if curl -sf --connect-timeout 3 --max-time 5 -o /dev/null http://us-east-1.ec2.archive.ubuntu.com/ubuntu/dists/noble/InRelease 2>/dev/null; then
    echo "[$(date -u '+%H:%M:%S')] Network ready (probe attempt $_net_try)"
    break
  fi
  echo "[$(date -u '+%H:%M:%S')] Network not ready yet (attempt $_net_try/60), retrying in 5s..."
  sleep 5
done

# â”€â”€ System update â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "[$(date -u '+%H:%M:%S')] Running apt-get update..."
apt-get update -y
apt-get upgrade -y
# Refresh package lists again after the long initial boot wait so we don't hit
# stale mirror metadata or 404s on noble security updates.
apt-get update -y
# build-essential + python3: native npm addons (node-gyp); ca-certificates: HTTPS
# Note: Ubuntu 24.04+ (noble) has no apt package `awscli`; it would abort the whole script under set -e before Node/openclaw run. Use AWS CLI v2 or snap on the instance only if you need it.
apt-get install -y curl wget git unzip jq build-essential python3 ca-certificates

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
OPENCLAW_BIN=""

%{ if llm_provider != "deepseek" }
# â”€â”€ Node.js 24 (OpenClaw requires Node â‰¥ 22.14; 24 is recommended) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "Installing Node.js from NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

# npm global binaries often land in $(npm prefix -g)/bin, not always /usr/bin
export PATH="$(npm config get prefix)/bin:$PATH"
hash -r

echo "--- Dependency versions ---"
node --version
npm --version
node -e '
  const m = /^v(\d+)\.(\d+)\.(\d+)/.exec(process.version);
  if (!m) { console.error("Bad node version string"); process.exit(1); }
  const major = +m[1], minor = +m[2], patch = +m[3];
  const ok = major > 22 || (major === 22 && (minor > 14 || (minor === 14 && patch >= 0)));
  if (!ok) { console.error("Need Node >= 22.14, got", process.version); process.exit(1); }
  console.log("Node version OK for OpenClaw:", process.version);
'
%{ endif }

%{ if llm_provider == "openrouter" }
# â”€â”€ Install OpenClaw via official local-prefix installer (OpenRouter-backed DeepSeek) â”€â”€â”€â”€â”€â”€
echo "Installing OpenClaw via official local-prefix installer (OpenRouter-backed DeepSeek)..."
sudo -u openclaw env HOME=/home/openclaw bash -lc 'curl -fsSL https://openclaw.ai/install-cli.sh | bash -s -- --no-onboard'
hash -r
OPENCLAW_BIN="$(sudo -u openclaw env HOME=/home/openclaw bash -lc 'command -v openclaw 2>/dev/null || true' | tr -d '\r')"
if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
  OPENCLAW_BIN="$(command -v openclaw || true)"
fi
if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
  for c in /home/openclaw/.openclaw/bin/openclaw /home/openclaw/.local/bin/openclaw /home/openclaw/.npm-global/bin/openclaw /usr/local/bin/openclaw /usr/bin/openclaw; do
    [[ -x "$c" ]] && OPENCLAW_BIN="$c" && break
  done
fi
if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
  echo "FATAL: openclaw CLI missing after official installer"
  sudo -u openclaw env HOME=/home/openclaw bash -lc 'ls -la /home/openclaw/.openclaw/bin 2>/dev/null || true'
  exit 1
fi
%{ else }
# â”€â”€ Install OpenClaw globally â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "Installing OpenClaw (npm)..."
npm install -g openclaw@latest

hash -r
export PATH="$(npm config get prefix)/bin:$PATH"
OPENCLAW_BIN="$(command -v openclaw || true)"
if [[ -z "$OPENCLAW_BIN" || ! -x "$OPENCLAW_BIN" ]]; then
  echo "FATAL: openclaw CLI missing after npm install -g"
  echo "npm prefix: $(npm config get prefix)"
  ls -la "$(npm config get prefix)/bin" 2>/dev/null || true
  npm list -g --depth=0 2>/dev/null || true
  exit 1
fi
%{ endif }

echo "--- Verifying OpenClaw ---"
echo "openclaw binary: $OPENCLAW_BIN"
if command -v npm >/dev/null 2>&1; then
  npm list -g openclaw --depth=0 || true
fi
# Smoke-test CLI (non-fatal if --version not implemented)
"$OPENCLAW_BIN" --version 2>/dev/null || "$OPENCLAW_BIN" -V 2>/dev/null || "$OPENCLAW_BIN" --help 2>/dev/null | head -n 3 || true

# â”€â”€ Puppeteer / screenshots (after OpenClaw is verified) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
echo "Checking Chromium + puppeteer-cli..."
CHROME_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROME_BIN" ]]; then
  echo "WARN: no chromium binary found; puppeteer will use its bundled browser if needed"
else
  export PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"
  echo "PUPPETEER_EXECUTABLE_PATH=$CHROME_BIN" >> /etc/environment
fi
if command -v npm >/dev/null 2>&1; then
  npm install -g puppeteer-cli
  hash -r
else
  echo "WARN: npm not available after installer; skipping puppeteer-cli install"
fi
export PATH="$(npm config get prefix)/bin:$PATH"
PUPPETEER_BIN="$(command -v puppeteer || true)"
if [[ -n "$PUPPETEER_BIN" ]]; then
  echo "puppeteer CLI: $PUPPETEER_BIN"
else
  echo "WARN: puppeteer global bin not on PATH (package still may work as puppeteer)"
fi

# Agent/embedded lanes read auth from env + auth-profiles; config.json llm.apiKey alone is not enough (transcript: missing agents/main/agent/auth-profiles.json).
%{ if llm_provider == "anthropic" }
cat > /home/openclaw/.openclaw/.env << OCENV
ANTHROPIC_API_KEY=${llm_api_key}
OCENV
%{ endif }
%{ if llm_provider == "openai" }
cat > /home/openclaw/.openclaw/.env << OCENV
OPENAI_API_KEY=${llm_api_key}
OCENV
%{ endif }
%{ if llm_provider == "openrouter" }
cat > /home/openclaw/.openclaw/.env << OCENV
OPENROUTER_API_KEY=${llm_api_key}
OPENCLAW_GATEWAY_TOKEN=$${GATEWAY_TOKEN}
OCENV
%{ endif }

install -d -o openclaw -g openclaw -m 0755 /home/openclaw/.openclaw/workspace
install -o openclaw -g openclaw -m 0644 /dev/null /home/openclaw/.openclaw/workspace/AGENTS.md

chown -R openclaw:openclaw /home/openclaw/.openclaw
chmod 600 /home/openclaw/.openclaw/.env 2>/dev/null || true

# Generate the OpenClaw config using the installed CLI schema instead of hand-writing JSON.
if sudo -u openclaw env HOME=/home/openclaw "PATH=$PATH" "$OPENCLAW_BIN" onboard \
  --mode local \
  --non-interactive \
  --accept-risk \
  --auth-choice openrouter-api-key \
  --openrouter-api-key "${llm_api_key}" \
  --gateway-auth token \
  --gateway-token "$GATEWAY_TOKEN" \
  --skip-ui \
  --skip-health \
  --skip-bootstrap \
  --skip-daemon \
  --workspace /home/openclaw/.openclaw/workspace
then :; else echo "WARN: openclaw onboard failed for openrouter"; fi

ln -sf /home/openclaw/.openclaw/openclaw.json /home/openclaw/.openclaw/config.json


# â”€â”€ Create OpenClaw systemd service â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
cat > /etc/systemd/system/openclaw.service << SYSTEMD
[Unit]
Description=OpenClaw Gateway â€” ${vm_name}
After=network.target
Wants=network.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/home/openclaw
# Resolved at bootstrap â€” npm global bin is not always /usr/bin/openclaw
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-/home/openclaw/.openclaw/.env
ExecStart=$OPENCLAW_BIN gateway run
Restart=on-failure
RestartSec=10

# Security hardening â€” limit what the service can touch
NoNewPrivileges=true
ProtectSystem=strict
# Do not use ProtectHome=read-only here: OpenClaw/node use ~/.cache and ~/.openclaw/*; a read-only home with only .openclaw writable still broke mkdir workspace (EACCES) and killed the gateway (WS 1006).
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

echo "--- Verifying openclaw service ---"
sleep 3
if systemctl is-active --quiet openclaw; then
  echo "openclaw.service is active"
  chown -R openclaw:openclaw /home/openclaw/.openclaw || true
  sudo -u openclaw env HOME=/home/openclaw "PATH=$PATH" "$OPENCLAW_BIN" models set "${llm_provider}/${llm_model}" 2>/dev/null || echo "WARN: openclaw models set ${llm_provider}/${llm_model} skipped"
else
  echo "FATAL: openclaw.service is not active"
  systemctl status openclaw --no-pager -l || true
  journalctl -u openclaw -n 80 --no-pager || true
  exit 1
fi

echo "========================================="
echo "Bootstrap complete â€” VM: ${vm_name}"
echo "OpenClaw gateway running on 127.0.0.1:18789"
echo "========================================="
