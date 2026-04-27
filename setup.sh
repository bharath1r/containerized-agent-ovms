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
#   bash setup.sh [--proxy http://proxy.example.com:911] [--model OpenVINO/Phi-3.5-mini-instruct-int4-ov] [--hf-token hf_xxx] [--npu] [--skip-aider] [--skip-model] [--skip-docker-pull]
#
#   --npu   Switches the default model to OpenVINO/Phi-3-mini-4k-instruct-int4-cw-ov
#           (channel-wise INT4 — required for NPU; group-size-128 models crash on NPU init).
# =============================================================================

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
PROXY="${PROXY:-}"                          # Set via env or --proxy flag
MODEL_REPO="${MODEL_REPO:-OpenVINO/Phi-3.5-mini-instruct-int4-ov}"
HF_TOKEN="${HF_TOKEN:-}"                    # HuggingFace token for gated models
# MODEL_NAME and MODEL_DIR are derived after arg parsing (see below)
VENV_DIR="${HOME}/ovms-agent-env"
SCRIPTS_DIR="${HOME}"
INSTALL_AIDER=true
SKIP_MODEL=false
SKIP_DOCKER_PULL=false
NPU_MODE=false
MODEL_EXPLICITLY_SET=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)            PROXY="$2"; shift 2 ;;
        --model)            MODEL_REPO="$2"; MODEL_EXPLICITLY_SET=true; shift 2 ;;
        --hf-token)         HF_TOKEN="$2"; shift 2 ;;
        --npu)              NPU_MODE=true; shift ;;
        --skip-aider)       INSTALL_AIDER=false; shift ;;
        --skip-model)       SKIP_MODEL=true; shift ;;
        --skip-docker-pull) SKIP_DOCKER_PULL=true; shift ;;
        *) echo "Unknown arg: $1"; echo "Usage: bash setup.sh [--proxy URL] [--model HF_REPO] [--hf-token TOKEN] [--npu] [--skip-aider] [--skip-model] [--skip-docker-pull]"; exit 1 ;;
    esac
done

# ── NPU model selection ────────────────────────────────────────────────────────
# NPU requires channel-wise INT4 quantization (-cw-ov suffix).
# Group-size-128 models (the standard HF exports) crash on NPU init.
if [[ "$NPU_MODE" == "true" ]]; then
    if [[ "$MODEL_EXPLICITLY_SET" == "false" ]]; then
        # Switch default to the NPU-compatible channel-wise model
        MODEL_REPO="OpenVINO/Phi-3-mini-4k-instruct-int4-cw-ov"
        echo "[--npu] Using NPU-compatible model: ${MODEL_REPO}"
    elif [[ "$MODEL_REPO" != *"-cw-ov"* ]]; then
        echo ""
        echo "WARNING: --npu was specified but the model '${MODEL_REPO}' does not appear"
        echo "         to be a channel-wise INT4 model (expected name to contain '-cw-ov')."
        echo "         Standard group-size-128 models WILL CRASH on NPU init."
        echo "         Recommended NPU model: OpenVINO/Phi-3-mini-4k-instruct-int4-cw-ov"
        echo "         To use it: bash setup.sh --npu"
        echo "         Continuing with '${MODEL_REPO}' — you have been warned."
        echo ""
    fi
fi

# Derive MODEL_NAME (OVMS serving name) and MODEL_DIR from the repo ID
# Override MODEL_NAME via env: OVMS_MODEL=my-name bash setup.sh
# e.g. OpenVINO/Phi-3.5-mini-instruct-int4-ov  →  folder = Phi-3.5-mini-instruct-int4-ov
MODEL_FOLDER="${MODEL_REPO##*/}"
MODEL_NAME="${OVMS_MODEL:-${MODEL_FOLDER}}"
MODEL_DIR="${HOME}/ovms-models/${MODEL_REPO}"

if [[ -n "$PROXY" ]]; then
    export HTTP_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY"
    export NO_PROXY="localhost,127.0.0.1,*.intel.com"
    # Explicit curl args so the right proxy is used even if the system env is wrong
    CURL_PROXY_ARGS=(--proxy "$PROXY")
    echo "Using proxy: $PROXY"
else
    # Override any stale/broken system proxy env for curl
    CURL_PROXY_ARGS=(--noproxy '*')
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
    curl -fsSL "${CURL_PROXY_ARGS[@]}" https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
    echo "Docker installed: $(docker --version)"
fi

# Always ensure the current user is in the docker group
sudo usermod -aG docker "$USER" 2>/dev/null || true
# Use sudo docker if the group hasn't taken effect in this session yet
if docker info &>/dev/null 2>&1; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
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

# Use a user-local npm prefix so npm install -g never needs sudo
NPM_GLOBAL="${HOME}/.npm-global"
mkdir -p "$NPM_GLOBAL"
npm config set prefix "$NPM_GLOBAL"

# Add it to PATH for this session and permanently via .bashrc
export PATH="${NPM_GLOBAL}/bin:${PATH}"
if ! grep -q 'NPM_GLOBAL' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="${HOME}/.npm-global/bin:${PATH}"' >> ~/.bashrc
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
echo " Phase 5: Download model: ${MODEL_REPO}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$SKIP_MODEL" == "true" ]]; then
    echo "Skipping model download (--skip-model)"
else
    mkdir -p "$MODEL_DIR"

    if [[ -f "${MODEL_DIR}/openvino_model.bin" ]]; then
        echo "Model already present, skipping download."
    else
        echo "Downloading ${MODEL_REPO} (~2-8GB depending on model)..."
        HF_TOKEN="${HF_TOKEN}" python3 - <<PYEOF
from huggingface_hub import snapshot_download
from huggingface_hub.errors import RepositoryNotFoundError, GatedRepoError
import os, sys

tok = os.environ.get("HF_TOKEN") or None
try:
    path = snapshot_download(
        repo_id="${MODEL_REPO}",
        local_dir="${MODEL_DIR}",
        token=tok,
    )
except (RepositoryNotFoundError, Exception) as e:
    msg = str(e)
    if "401" in msg or "gated" in msg.lower() or "authentication" in msg.lower():
        print("\nERROR: This model is gated — authentication required.", file=sys.stderr)
        print("  Step 1: Log in to HuggingFace and ACCEPT the license:", file=sys.stderr)
        print("          https://huggingface.co/${MODEL_REPO}", file=sys.stderr)
        print("          (click 'Agree and access repository' on that page)", file=sys.stderr)
        print("  Step 2: Get a token (read access):  https://huggingface.co/settings/tokens", file=sys.stderr)
        print("  Step 3: Re-run:", file=sys.stderr)
        print("          bash setup.sh --model ${MODEL_REPO} --hf-token hf_YOUR_TOKEN", file=sys.stderr)
        print("  Note: A valid token alone is NOT enough — you must accept the license first.", file=sys.stderr)
    else:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
for f in ["openvino_model.bin", "openvino_model.xml",
          "openvino_tokenizer.bin", "openvino_detokenizer.bin"]:
    full = os.path.join(path, f)
    if not os.path.exists(full):
        # Community repos may use slightly different names — warn but continue
        print(f"WARNING: expected file not found: {f} (may use a different name — check {path})", file=sys.stderr)
    else:
        print(f"OK: {f} ({os.path.getsize(full)/1e6:.1f} MB)")
print("Model download complete.")
PYEOF
    fi

    # Make model files readable/writable by Docker — only touch files we own
    # (OVMS may later write root-owned cache files; skip those)
    find "$MODEL_DIR" -user "$(id -u)" \( -type f -o -type d \) -exec chmod a+rw {} + 2>/dev/null || true
fi

# ─── Phase 6: Pull OVMS image ──────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 6: Pull OVMS Docker image"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$SKIP_DOCKER_PULL" == "true" ]]; then
    echo "Skipping Docker pull (--skip-docker-pull)"
else
    $DOCKER_CMD pull openvino/model_server:latest-gpu
    echo "OVMS image ready."
fi

# ─── Phase 7: Install service scripts ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Phase 7: Install service scripts"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/simple_proxy.py"   "$SCRIPTS_DIR/simple_proxy.py"
cp "$SCRIPT_DIR/start.sh"          "$SCRIPTS_DIR/start.sh"
cp "$SCRIPT_DIR/stop.sh"           "$SCRIPTS_DIR/stop.sh"
cp "$SCRIPT_DIR/launch-agent.sh"   "$SCRIPTS_DIR/launch-agent.sh"
cp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPTS_DIR/docker-compose.yml"
cp "$SCRIPT_DIR/Dockerfile.proxy"  "$SCRIPTS_DIR/Dockerfile.proxy"
cp "$SCRIPT_DIR/uninstall.sh"      "$SCRIPTS_DIR/uninstall.sh"
chmod +x "$SCRIPTS_DIR/start.sh" "$SCRIPTS_DIR/stop.sh" "$SCRIPTS_DIR/launch-agent.sh" "$SCRIPTS_DIR/uninstall.sh"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Setup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Option A — Script mode (per-session):"
echo "   bash start.sh [--gpu | --cpu | --npu]"
echo "   bash launch-agent.sh --agent claude"
echo "   bash launch-agent.sh --agent aider"
echo ""
echo " Option B — Compose mode (persistent stack):"
echo "   GPU:  TARGET_DEVICE=GPU docker compose up -d"
echo "   NPU:  TARGET_DEVICE=NPU DEVICE_NODE=/dev/accel OVMS_EXTRA_ARGS='--max_prompt_len 2048' docker compose up -d"
echo "   CPU:  TARGET_DEVICE=CPU OVMS_EXTRA_ARGS='' docker compose up -d"
echo "   Open WebUI: http://localhost:3000"
echo "   docker compose down"
echo ""
