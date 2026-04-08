#!/bin/bash
###############################################################################
# OpenClaw Bootstrap Script
# Runs once on first boot via EC2 user data
# Templated by Terraform — variables injected at provision time
###############################################################################

set -euo pipefail
exec > >(tee /var/log/openclaw-bootstrap.log | logger -t openclaw-bootstrap) 2>&1

echo "========================================="
echo "OpenClaw Bootstrap — VM: ${vm_name}"
echo "LLM Provider: ${llm_provider}"
echo "LLM Model: ${llm_model}"
echo "========================================="

# Create Linux account FIRST — before apt-get upgrade (which can take 20–40+ min on first boot).
# SSM is often "Online" while user-data is still running; experiment.sh waits on id -u openclaw.
if ! id -u openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
fi
mkdir -p /home/openclaw/.openclaw/workspace /home/openclaw/.openclaw/memory

# ── System update ─────────────────────────────────────────────────────────────
apt-get update -y
apt-get upgrade -y
# build-essential + python3: native npm addons (node-gyp); ca-certificates: HTTPS
# Note: Ubuntu 24.04+ (noble) has no apt package `awscli`; it would abort the whole script under set -e before Node/openclaw run. Use AWS CLI v2 or snap on the instance only if you need it.
apt-get install -y curl wget git unzip jq build-essential python3 ca-certificates

# ── Node.js 24 (OpenClaw requires Node ≥ 22.14; 24 is recommended) ─────────────
echo "Installing Node.js from NodeSource..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
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

# ── Install OpenClaw globally ─────────────────────────────────────────────────
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

echo "--- Verifying OpenClaw ---"
echo "openclaw binary: $OPENCLAW_BIN"
npm list -g openclaw --depth=0
# Smoke-test CLI (non-fatal if --version not implemented)
"$OPENCLAW_BIN" --version 2>/dev/null || "$OPENCLAW_BIN" -V 2>/dev/null || "$OPENCLAW_BIN" --help 2>/dev/null | head -n 3 || true

# ── Puppeteer / screenshots (after OpenClaw is verified) ──────────────────────
echo "Installing Chromium + puppeteer-cli..."
apt-get install -y chromium-browser || apt-get install -y chromium
CHROME_BIN="$(command -v chromium-browser || command -v chromium || true)"
if [[ -z "$CHROME_BIN" ]]; then
  echo "WARN: no chromium binary found; puppeteer may download its own Chrome"
else
  export PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"
  echo "PUPPETEER_EXECUTABLE_PATH=$CHROME_BIN" >> /etc/environment
fi
npm install -g puppeteer-cli
hash -r
export PATH="$(npm config get prefix)/bin:$PATH"
PUPPETEER_BIN="$(command -v puppeteer || true)"
if [[ -n "$PUPPETEER_BIN" ]]; then
  echo "puppeteer CLI: $PUPPETEER_BIN"
else
  echo "WARN: puppeteer global bin not on PATH (package still may work as puppeteer)"
fi

# ── Install Ollama if provider is ollama ──────────────────────────────────────
%{ if llm_provider == "ollama" }
echo "Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

systemctl enable ollama
systemctl start ollama

# Wait for Ollama to be ready
echo "Waiting for Ollama service..."
sleep 10

# Pull the model
echo "Pulling model: ${llm_model}..."
ollama pull ${llm_model}
echo "Model pull complete."
%{ endif }

# ── Write OpenClaw config ─────────────────────────────────────────────────────
cat > /home/openclaw/.openclaw/config.json << OCCONFIG
{
  "gateway": {
    "port": 18789,
    "host": "127.0.0.1"
  },
  "llm": {
    "provider": "${llm_provider}",
    "model": "${llm_model}"%{ if llm_provider != "ollama" },
    "apiKey": "${llm_api_key}"%{ endif }%{ if llm_provider == "ollama" },
    "baseUrl": "http://127.0.0.1:11434"%{ endif }%{ if llm_provider == "deepseek" },
    "baseUrl": "https://api.deepseek.com/v1"%{ endif }
  },
  "persona": {
    "name": "Vikram Bhat",
    "email": "v.bhat@nortecorp.io",
    "timezone": "America/New_York"
  },
  "skills": {
    "browser": {
      "enabled": true,
      "defaultUrl": "${inbox_url}"
    }
  },
  "memory": {
    "enabled": true,
    "path": "/home/openclaw/.openclaw/memory"
  }
}
OCCONFIG

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
%{ if llm_provider == "deepseek" }
cat > /home/openclaw/.openclaw/.env << OCENV
DEEPSEEK_API_KEY=${llm_api_key}
OCENV
%{ endif }

install -d -o openclaw -g openclaw -m 0755 /home/openclaw/.openclaw/workspace
install -o openclaw -g openclaw -m 0644 /dev/null /home/openclaw/.openclaw/workspace/AGENTS.md

chown -R openclaw:openclaw /home/openclaw/.openclaw
chmod 600 /home/openclaw/.openclaw/.env 2>/dev/null || true

# Agent/CLI lanes read auth-profiles.json; ANTHROPIC_API_KEY in .env is not enough for `openclaw agent` (SSM has no systemd EnvironmentFile). Seed the store non-interactively.
%{ if llm_provider == "anthropic" }
if sudo -u openclaw env HOME=/home/openclaw "PATH=$PATH" "$OPENCLAW_BIN" models auth paste-token --provider anthropic <<'OC_PASTE_ANTHROPIC'
${llm_api_key}
OC_PASTE_ANTHROPIC
then :; else echo "WARN: models auth paste-token anthropic failed (check CLI / provider id)"; fi
%{ endif }
%{ if llm_provider == "openai" }
if sudo -u openclaw env HOME=/home/openclaw "PATH=$PATH" "$OPENCLAW_BIN" models auth paste-token --provider openai <<'OC_PASTE_OPENAI'
${llm_api_key}
OC_PASTE_OPENAI
then :; else echo "WARN: models auth paste-token openai failed"; fi
%{ endif }
%{ if llm_provider == "deepseek" }
if sudo -u openclaw env HOME=/home/openclaw "PATH=$PATH" "$OPENCLAW_BIN" models auth paste-token --provider deepseek <<'OC_PASTE_DEEPSEEK'
${llm_api_key}
OC_PASTE_DEEPSEEK
then :; else echo "WARN: models auth paste-token deepseek failed"; fi
%{ endif }

# ── Create OpenClaw systemd service ───────────────────────────────────────────
cat > /etc/systemd/system/openclaw.service << SYSTEMD
[Unit]
Description=OpenClaw Gateway — ${vm_name}
After=network.target%{ if llm_provider == "ollama" } ollama.service%{ endif }
Wants=network.target

[Service]
Type=simple
User=openclaw
WorkingDirectory=/home/openclaw
# Resolved at bootstrap — npm global bin is not always /usr/bin/openclaw
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=-/home/openclaw/.openclaw/.env
ExecStart=$$OPENCLAW_BIN gateway --config /home/openclaw/.openclaw/config.json
Restart=on-failure
RestartSec=10

# Security hardening — limit what the service can touch
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
echo "Bootstrap complete — VM: ${vm_name}"
echo "OpenClaw gateway running on 127.0.0.1:18789"
echo "========================================="
