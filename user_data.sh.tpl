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

# ── Install Node.js v22 (required by OpenClaw) ────────────────────────────────
echo "Installing Node.js v22..."
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node --version
npm --version

# ── Install OpenClaw globally ─────────────────────────────────────────────────
echo "Installing OpenClaw..."
npm install -g openclaw@latest

# ── Install auditd for experiment monitoring ──────────────────────────────────
apt-get install -y auditd inotify-tools
systemctl enable auditd
systemctl start auditd

# Audit rules — watch OpenClaw working directory for file events
auditctl -w /home/openclaw/.openclaw -p rwxa -k openclaw_fs_events
auditctl -w /tmp -p rwxa -k tmp_events

# ── Install CloudWatch agent for log shipping ─────────────────────────────────
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i amazon-cloudwatch-agent.deb

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWCONFIG'
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/openclaw-gateway.log",
            "log_group_name": "/openclaw/${vm_name}/gateway",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/audit/audit.log",
            "log_group_name": "/openclaw/${vm_name}/audit",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/openclaw-bootstrap.log",
            "log_group_name": "/openclaw/${vm_name}/bootstrap",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
CWCONFIG

systemctl start amazon-cloudwatch-agent

# ── Create dedicated openclaw user (non-root, no sudo) ────────────────────────
useradd -m -s /bin/bash openclaw
mkdir -p /home/openclaw/.openclaw

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
    "baseUrl": "http://127.0.0.1:11434"%{ endif }
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
  },
  "logging": {
    "level": "debug",
    "file": "/var/log/openclaw-gateway.log"
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
StandardOutput=append:/var/log/openclaw-gateway.log
StandardError=append:/var/log/openclaw-gateway.log

# Security hardening — limit what the service can touch
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/openclaw/.openclaw /var/log/openclaw-gateway.log
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

# ── Start inotifywait monitor on OpenClaw memory dir ─────────────────────────
cat > /usr/local/bin/openclaw-fsmon.sh << 'FSMON'
#!/bin/bash
# Filesystem monitor for OpenClaw experiment
# Logs all file events in the OpenClaw data directory to a dedicated file
inotifywait -m -r -e create,modify,delete,move,access \
  --format '%T %w %f %e' \
  --timefmt '%Y-%m-%dT%H:%M:%S' \
  /home/openclaw/.openclaw/ \
  >> /var/log/openclaw-fsmon.log 2>&1
FSMON

chmod +x /usr/local/bin/openclaw-fsmon.sh

cat > /etc/systemd/system/openclaw-fsmon.service << FSMON_SERVICE
[Unit]
Description=OpenClaw Filesystem Monitor
After=openclaw.service

[Service]
Type=simple
ExecStart=/usr/local/bin/openclaw-fsmon.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
FSMON_SERVICE

systemctl daemon-reload
systemctl enable openclaw-fsmon
systemctl start openclaw-fsmon

echo "========================================="
echo "Bootstrap complete — VM: ${vm_name}"
echo "OpenClaw gateway running on 127.0.0.1:18789"
echo "Logs: /var/log/openclaw-gateway.log"
echo "FS monitor: /var/log/openclaw-fsmon.log"
echo "Audit log: /var/log/audit/audit.log"
echo "========================================="
