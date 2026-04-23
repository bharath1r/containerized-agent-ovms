#!/bin/bash
# =============================================================================
# setup.sh — One-time setup: OVMS local AI pipeline + multi-agent support
#
# Architecture:
#   Any agent → simple_proxy.py (port 4000) → OVMS (port 8000) → Phi-3.5-mini
#
# Supported agents (choose at launch time, not install time):
#   Claude Code  — Anthropic API format  → bash launch-agent.sh --agent claude
#   Aider        — OpenAI API format     → bash launch-agent.sh --agent aider
#   Any other    — OpenAI-compatible     → bash launch-agent.sh --agent custom --cmd '...'
#
# Prerequisites:
#   - Ubuntu 22.04 / 24.04
#   - sudo access
#   - Internet access (optionally via proxy)
#
# Usage:
#   bash setup.sh [--proxy http://proxy.example.com:911] [--skip-aider]
# =============================================================================

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
PROXY="${PROXY:-}"                          # Set via env or --proxy flag
MODEL_REPO="OpenVINO/Phi-3.5-mini-instruct-int4-ov"
MODEL_DIR="${HOME}/ovms-models/OpenVINO/Phi-3.5-mini-instruct-int4-ov"
VENV_DIR="${HOME}/ovms-agent-env"
SCRIPTS_DIR="${HOME}"
INSTALL_AIDER=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)       PROXY="$2"; shift 2 ;;
        --skip-aider)  INSTALL_AIDER=false; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -n "$PROXY" ]]; then
    export HTTP_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY"
    export NO_PROXY="localhost,127.0.0.1,*.intel.com"
    echo "Using proxy: $PROXY"
fi

# ─── Phase 1: System packages ─────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 1: System packages"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg lsb-release python3-venv

# ─── Phase 2: Docker ──────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 2: Docker"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if command -v docker &>/dev/null; then
    echo "Docker already installed: $(docker --version)"
else
    sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo "Docker installed: $(docker --version)"
fi

# Configure Docker proxy if set
if [[ -n "$PROXY" ]]; then
    sudo mkdir -p /etc/systemd/system/docker.service.d
    sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null <<EOF
[Service]
Environment="HTTP_PROXY=${PROXY}"
Environment="HTTPS_PROXY=${PROXY}"
Environment="NO_PROXY=localhost,127.0.0.0/8,10.0.0.0/8,*.intel.com"
EOF
    sudo systemctl daemon-reload
    sudo systemctl restart docker
fi

sudo usermod -aG render "$USER" 2>/dev/null || true

# ─── Phase 3: Python venv ─────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 3: Python venv"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install --upgrade pip
pip install flask requests "huggingface-hub>=0.23"

# Aider (optional — can skip with --skip-aider)
if [[ "$INSTALL_AIDER" == "true" ]]; then
    pip install aider-chat
    echo "Aider installed: $("${VENV_DIR}/bin/aider" --version 2>/dev/null || echo 'ok')"
fi

echo "Python venv ready: $VENV_DIR"

# ─── Phase 4: Node.js + Claude Code ───────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 4: Node.js + Claude Code"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v node &>/dev/null; then
    sudo apt-get install -y nodejs npm
fi

if [[ -n "$PROXY" ]]; then
    npm config set proxy "$PROXY"
    npm config set https-proxy "$PROXY"
fi

npm install -g @anthropic-ai/claude-code
echo "Claude Code installed: $(claude --version)"

# ─── Phase 5: Download model ──────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 5: Download Phi-3.5-mini model"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

mkdir -p "$MODEL_DIR"

if [[ -f "${MODEL_DIR}/openvino_model.bin" ]]; then
    echo "Model already present, skipping download."
else
    echo "Downloading ${MODEL_REPO} (~2GB)..."
    python3 - <<PYEOF
from huggingface_hub import snapshot_download
import os, sys

path = snapshot_download(
    repo_id="${MODEL_REPO}",
    local_dir="${MODEL_DIR}",
    local_dir_use_symlinks=False,
)
for f in ["openvino_model.bin", "openvino_model.xml",
          "openvino_tokenizer.bin", "openvino_detokenizer.bin"]:
    full = os.path.join(path, f)
    if not os.path.exists(full):
        print(f"MISSING: {f}", file=sys.stderr); sys.exit(1)
    print(f"OK: {f} ({os.path.getsize(full)/1e6:.1f} MB)")
print("Model download complete.")
PYEOF
fi

# Make the model directory writable by Docker (OVMS runs as non-root)
chmod -R a+rw "$MODEL_DIR"

# ─── Phase 6: Pull OVMS image ──────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 6: Pull OVMS Docker image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

docker pull openvino/model_server:latest-gpu
echo "OVMS image ready."

# ─── Phase 7: Install service scripts ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 7: Install service scripts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/simple_proxy.py"  "$SCRIPTS_DIR/simple_proxy.py"
cp "$SCRIPT_DIR/start.sh"         "$SCRIPTS_DIR/start-services.sh"
cp "$SCRIPT_DIR/stop.sh"          "$SCRIPTS_DIR/stop-services.sh"
cp "$SCRIPT_DIR/launch-agent.sh"  "$SCRIPTS_DIR/launch-agent.sh"
chmod +x "$SCRIPTS_DIR/start-services.sh" "$SCRIPTS_DIR/stop-services.sh" "$SCRIPTS_DIR/launch-agent.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Start services:  bash ~/start-services.sh"
echo ""
echo " Launch an agent:"
echo "   Claude Code:  bash ~/launch-agent.sh --agent claude"
echo "   Aider:        bash ~/launch-agent.sh --agent aider"
echo "   Custom tool:  bash ~/launch-agent.sh --agent custom --cmd 'mycli --api-base http://localhost:4000/v1'"
echo ""
