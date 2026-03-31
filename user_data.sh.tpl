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

# ── System update ─────────────────────────────────────────────────────────────
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git unzip awscli jq

# Create openclaw user before Node/Chromium — if a later step fails, user still exists for SSM/sudo.
if ! id -u openclaw &>/dev/null; then
  useradd -m -s /bin/bash openclaw
fi
mkdir -p /home/openclaw/.openclaw

# ── Install Node.js v22 (required by OpenClaw) ────────────────────────────────
echo "Installing Node.js v22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version
npm --version

# ── Install OpenClaw globally ─────────────────────────────────────────────────
echo "Installing OpenClaw..."
npm install -g openclaw@latest

# ── Install Puppeteer for experiment screenshots ──────────────────────────────
echo "Installing Puppeteer..."
apt-get install -y chromium-browser
npm install -g puppeteer-cli
# Tell Puppeteer to use the system Chromium rather than downloading its own
export PUPPETEER_EXECUTABLE_PATH="$(which chromium-browser)"
echo "PUPPETEER_EXECUTABLE_PATH=$(which chromium-browser)" >> /etc/environment

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

chown -R openclaw:openclaw /home/openclaw/.openclaw

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
ExecStart=/usr/bin/openclaw gateway --config /home/openclaw/.openclaw/config.json
Restart=on-failure
RestartSec=10

# Security hardening — limit what the service can touch
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/openclaw/.openclaw
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

echo "========================================="
echo "Bootstrap complete — VM: ${vm_name}"
echo "OpenClaw gateway running on 127.0.0.1:18789"
echo "========================================="
