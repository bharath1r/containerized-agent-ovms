#!/bin/bash
# =============================================================================
# start.sh — Start OVMS + proxy services
#
# Auto-detects Intel GPU (Arc/Iris Xe) and uses it if available, falls back to CPU.
# Run this every time you want to use Claude Code with the local model.
#
# Usage:  bash ~/start.sh [--cpu | --gpu]
# =============================================================================

set -euo pipefail

OVMS_PORT=8000
PROXY_PORT=4000
MODEL_NAME="Phi-3.5-mini"
MODEL_DIR="${HOME}/ovms-models/OpenVINO/Phi-3.5-mini-instruct-int4-ov"
VENV_DIR="${HOME}/ovms-agent-env"
PROXY_SCRIPT="${HOME}/simple_proxy.py"
OVMS_IMAGE="openvino/model_server:latest-gpu"

# ─── Parse flags ──────────────────────────────────────────────────────────────
FORCE_DEVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu) FORCE_DEVICE="CPU"; shift ;;
        --gpu) FORCE_DEVICE="GPU"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ─── Detect GPU ───────────────────────────────────────────────────────────────
detect_device() {
    if [[ -n "$FORCE_DEVICE" ]]; then
        echo "$FORCE_DEVICE"
        return
    fi
    # Check for Intel GPU via DRI render node
    if [[ -e /dev/dri/renderD128 ]]; then
        local pci_id
        pci_id=$(cat /sys/class/drm/card0/device/uevent 2>/dev/null | grep PCI_ID | cut -d= -f2 || echo "")
        # Intel vendor ID is 8086
        if [[ "$pci_id" == 8086:* ]]; then
            echo "GPU"
            return
        fi
    fi
    echo "CPU"
}

# ─── Docker command (use sudo if group not active yet) ────────────────────────────────────────
if docker info &>/dev/null 2>&1; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
fi

# ─── Cleanup ──────────────────────────────────────────────────────────────────────────────────
echo "Stopping any existing services..."
$DOCKER_CMD stop ovms-test 2>/dev/null || true
$DOCKER_CMD rm   ovms-test 2>/dev/null || true
pkill -f "simple_proxy.py" 2>/dev/null || true
# Free ports
fuser -k ${PROXY_PORT}/tcp 2>/dev/null || true
fuser -k ${OVMS_PORT}/tcp  2>/dev/null || true
sleep 1

# ─── Validate ─────────────────────────────────────────────────────────────────
for check in \
    "Model directory:${MODEL_DIR}/openvino_model.bin" \
    "Proxy script:${PROXY_SCRIPT}" \
    "Python venv:${VENV_DIR}/bin/python3"; do
    label="${check%%:*}"; path="${check#*:}"
    if [[ ! -f "$path" ]]; then
        echo "ERROR: ${label} not found at ${path}"
        echo "Please run: bash setup.sh"
        exit 1
    fi
done

if ! $DOCKER_CMD images | grep -q "openvino/model_server"; then
    echo "ERROR: OVMS Docker image not found. Run: bash setup.sh"
    exit 1
fi

# Ensure model dir is writable by Docker container
chmod -R a+rw "$MODEL_DIR"

# ─── Start OVMS ───────────────────────────────────────────────────────────────
TARGET_DEVICE=$(detect_device)
RENDER_GID=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo "")

echo ""
echo "Starting OVMS on ${TARGET_DEVICE}..."

DOCKER_ARGS=(
    -d
    -p ${OVMS_PORT}:${OVMS_PORT}
    -v "${HOME}/ovms-models:/models:rw"
    --name ovms-test
)

if [[ "$TARGET_DEVICE" == "GPU" && -n "$RENDER_GID" ]]; then
    DOCKER_ARGS+=(--device /dev/dri --group-add "$RENDER_GID")
fi

$DOCKER_CMD run "${DOCKER_ARGS[@]}" \
    "$OVMS_IMAGE" \
    --source_model OpenVINO/Phi-3.5-mini-instruct-int4-ov \
    --model_name "$MODEL_NAME" \
    --model_repository_path /models \
    --task text_generation \
    --rest_port ${OVMS_PORT} \
    --target_device "$TARGET_DEVICE" \
    --cache_size 2

# ─── Wait for OVMS ────────────────────────────────────────────────────────────
echo "Waiting for OVMS to be ready..."
for i in $(seq 1 40); do
    sleep 3
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
        http://localhost:${OVMS_PORT}/v3/chat/completions 2>/dev/null || echo "000")
    printf "  [%d/40] HTTP %s\r" "$i" "$STATUS"
    if [[ "$STATUS" == "200" || "$STATUS" == "400" ]]; then
        echo ""; echo "OVMS ready (${TARGET_DEVICE})."
        break
    fi
    if ! $DOCKER_CMD ps -q --filter name=ovms-test | grep -q .; then
        echo ""; echo "ERROR: OVMS container crashed."
        $DOCKER_CMD logs ovms-test 2>&1 | tail -20
        exit 1
    fi
done

if [[ "$STATUS" != "200" && "$STATUS" != "400" ]]; then
    echo "ERROR: OVMS did not start in time. Check: $DOCKER_CMD logs ovms-test"
    exit 1
fi

# ─── Start proxy ──────────────────────────────────────────────────────────────
echo "Starting proxy on port ${PROXY_PORT}..."
nohup "${VENV_DIR}/bin/python3" "$PROXY_SCRIPT" \
    > /tmp/simple_proxy.log 2>&1 &
echo $! > /tmp/simple_proxy.pid

sleep 2
PROXY_STATUS=$(curl -s http://localhost:${PROXY_PORT}/health 2>/dev/null || echo "{}")
if echo "$PROXY_STATUS" | grep -q "healthy"; then
    echo "Proxy ready."
else
    echo "ERROR: Proxy failed to start. Check /tmp/simple_proxy.log"
    exit 1
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Services running"
echo "  OVMS:  http://localhost:${OVMS_PORT}  [${TARGET_DEVICE}]"
echo "  Proxy: http://localhost:${PROXY_PORT}"
echo ""
echo " Launch an agent:"
echo "  bash ~/launch-agent.sh --agent claude   # Claude Code"
echo "  bash ~/launch-agent.sh --agent aider    # Aider"
echo "  bash ~/launch-agent.sh --agent custom --cmd 'mytool --api-base http://localhost:${PROXY_PORT}/v1'"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
