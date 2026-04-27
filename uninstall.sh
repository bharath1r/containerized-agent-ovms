#!/bin/bash
# =============================================================================
# uninstall.sh — Remove OVMS agent stack components
#
# Each component is confirmed individually so you can remove just the model,
# just the venv, or everything at once.
#
# Usage:
#   bash uninstall.sh          # interactive (confirms each step)
#   bash uninstall.sh --all    # remove everything without prompting
# =============================================================================

set -euo pipefail

ALL=false
[[ "${1:-}" == "--all" ]] && ALL=true

confirm() {
    # confirm <prompt> <default_size>
    if [[ "$ALL" == "true" ]]; then
        echo "  → $1 (--all)"
        return 0
    fi
    read -rp "  $1 [y/N] " ans
    [[ "${ans,,}" == "y" ]]
}

# Docker command
if docker info &>/dev/null 2>&1; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " OVMS Agent Stack — Uninstall"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 1. Stop running services ──────────────────────────────────────────────────
echo "[1/6] Stop running services (OVMS container + proxy)"
if confirm "Stop OVMS container and proxy now?"; then
    $DOCKER_CMD stop ovms-test 2>/dev/null && echo "      OVMS stopped" || true
    $DOCKER_CMD rm   ovms-test 2>/dev/null || true
    pkill -f "simple_proxy.py" 2>/dev/null && echo "      Proxy stopped" || true
    rm -f /tmp/simple_proxy.pid
    echo "      Done."
else
    echo "      Skipped."
fi

# ── 2. Downloaded model(s) ────────────────────────────────────────────────────
echo ""
echo "[2/6] Downloaded models  (~${HOME}/ovms-models/)"
if [[ -d "${HOME}/ovms-models" ]]; then
    SIZE=$(du -sh "${HOME}/ovms-models" 2>/dev/null | cut -f1)
    echo "      Found: ${HOME}/ovms-models  (${SIZE})"
    # List models inside
    find "${HOME}/ovms-models" -maxdepth 3 -name "openvino_model.bin" \
        | sed 's|/openvino_model.bin||' \
        | sed "s|${HOME}/ovms-models/||" \
        | while read -r m; do echo "        • $m"; done
    if confirm "Delete ALL downloaded models? (${SIZE})"; then
        rm -rf "${HOME}/ovms-models"
        echo "      Deleted."
    else
        echo "      Skipped. (To delete a single model: rm -rf ~/ovms-models/<owner>/<model>)"
    fi
else
    echo "      Not found — nothing to do."
fi

# ── 3. Python venv ────────────────────────────────────────────────────────────
echo ""
echo "[3/6] Python venv  (~${HOME}/ovms-agent-env/)"
if [[ -d "${HOME}/ovms-agent-env" ]]; then
    SIZE=$(du -sh "${HOME}/ovms-agent-env" 2>/dev/null | cut -f1)
    echo "      Found: ${HOME}/ovms-agent-env  (${SIZE})"
    if confirm "Delete Python venv? (removes Flask, aider, huggingface-hub, etc.)"; then
        rm -rf "${HOME}/ovms-agent-env"
        echo "      Deleted."
    else
        echo "      Skipped."
    fi
else
    echo "      Not found — nothing to do."
fi

# ── 4. OVMS Docker image ──────────────────────────────────────────────────────
echo ""
echo "[4/6] OVMS Docker image  (openvino/model_server:latest-gpu)"
if $DOCKER_CMD image inspect openvino/model_server:latest-gpu &>/dev/null 2>&1; then
    SIZE=$($DOCKER_CMD image inspect openvino/model_server:latest-gpu \
        --format '{{.Size}}' 2>/dev/null | awk '{printf "%.1f GB", $1/1e9}')
    echo "      Found: openvino/model_server:latest-gpu  (~${SIZE})"
    if confirm "Remove OVMS Docker image?"; then
        $DOCKER_CMD rmi openvino/model_server:latest-gpu
        echo "      Removed."
    else
        echo "      Skipped."
    fi
else
    echo "      Not found — nothing to do."
fi

# ── 5. Installed scripts ──────────────────────────────────────────────────────
echo ""
echo "[5/6] Installed scripts  (~/start.sh, ~/stop.sh, ~/launch-agent.sh, ~/simple_proxy.py, ~/docker-compose.yml)"
SCRIPTS=(start.sh stop.sh launch-agent.sh simple_proxy.py docker-compose.yml Dockerfile.proxy uninstall.sh)
FOUND=()
for f in "${SCRIPTS[@]}"; do
    [[ -f "${HOME}/${f}" ]] && FOUND+=("$f")
done
if [[ ${#FOUND[@]} -gt 0 ]]; then
    printf "      Found: %s\n" "${FOUND[@]}"
    if confirm "Delete installed scripts from ~/?"; then
        for f in "${FOUND[@]}"; do rm -f "${HOME}/${f}"; done
        echo "      Deleted."
    else
        echo "      Skipped."
    fi
else
    echo "      Not found — nothing to do."
fi

# ── 6. Claude Code (npm global) ───────────────────────────────────────────────
echo ""
echo "[6/6] Claude Code  (~/.npm-global/)"
if [[ -d "${HOME}/.npm-global" ]]; then
    SIZE=$(du -sh "${HOME}/.npm-global" 2>/dev/null | cut -f1)
    echo "      Found: ${HOME}/.npm-global  (${SIZE})"
    if confirm "Remove Claude Code and npm global installs?"; then
        npm uninstall -g @anthropic-ai/claude-code 2>/dev/null || true
        echo "      Removed."
    else
        echo "      Skipped."
    fi
else
    echo "      Not found — nothing to do."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " Uninstall complete."
echo " Docker, Node.js, and Python system packages were NOT removed."
echo " To remove those: sudo apt-get remove docker-ce nodejs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
