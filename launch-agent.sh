#!/bin/bash
# =============================================================================
# launch-agent.sh — Universal launcher for any AI coding agent
#
# Supports: claude (Claude Code), aider, or any OpenAI-compatible CLI/tool.
#
# Usage:
#   bash launch-agent.sh --agent claude       # Claude Code (default)
#   bash launch-agent.sh --agent aider        # Aider
#   bash launch-agent.sh --agent aider --args "--model Phi-3.5-mini --no-auto-commits"
#   bash launch-agent.sh --agent custom --cmd "mycli --api-base http://localhost:4000/v1"
#
# Environment variables (override defaults):
#   OVMS_MODEL    model name reported by OVMS (default: Phi-3.5-mini)
#   PROXY_PORT    proxy port (default: 4000)
#   OVMS_PORT     OVMS port (default: 8000)
# =============================================================================

set -euo pipefail

OVMS_MODEL="${OVMS_MODEL:-Phi-3.5-mini}"
PROXY_PORT="${PROXY_PORT:-4000}"
OVMS_PORT="${OVMS_PORT:-8000}"
VENV_DIR="${HOME}/ovms-agent-env"

# API endpoints
ANTHROPIC_BASE="http://localhost:${PROXY_PORT}"   # /v1/messages  (Claude Code)
OPENAI_BASE="http://localhost:${PROXY_PORT}/v1"   # /v1/chat/completions (Aider, etc.)
OVMS_DIRECT="http://localhost:${OVMS_PORT}/v3"    # direct to OVMS (no proxy)

# Defaults
AGENT="claude"
EXTRA_ARGS=""
CUSTOM_CMD=""

# ─── Parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent) AGENT="$2"; shift 2 ;;
        --args)  EXTRA_ARGS="$2"; shift 2 ;;
        --cmd)   CUSTOM_CMD="$2"; shift 2 ;;
        *) echo "Unknown: $1"; echo "Usage: $0 --agent <claude|aider|custom> [--args '...'] [--cmd '...']"; exit 1 ;;
    esac
done

# ─── Verify services are running ──────────────────────────────────────────────
check_services() {
    local proxy_ok ovms_ok
    # /v1/models is always present (even old proxy builds); /health may not exist in old installs
    proxy_ok=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:${PROXY_PORT}/v1/models 2>/dev/null || echo "000")
    ovms_ok=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:${OVMS_PORT}/v3/chat/completions 2>/dev/null || echo "000")

    # OVMS returns 400 on bare GET, 405 on some versions — anything but 000 means it's up
    if [[ "$proxy_ok" == "000" ]]; then
        echo "ERROR: Proxy not running on port ${PROXY_PORT}. Run: bash start.sh"
        exit 1
    fi
    if [[ "$ovms_ok" == "000" ]]; then
        echo "ERROR: OVMS not running on port ${OVMS_PORT}. Run: bash start.sh"
        exit 1
    fi
    echo "Services OK  [OVMS: ${ovms_ok}  Proxy: ${proxy_ok}]"
}

check_services

# ─── Agent launchers ──────────────────────────────────────────────────────────

launch_claude() {
    echo "Launching Claude Code → ${ANTHROPIC_BASE}"
    export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE}"
    export ANTHROPIC_API_KEY="local-ovms"
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS="32000"
    # Map all model tiers to the local model
    export ANTHROPIC_MODEL="${OVMS_MODEL}"
    export ANTHROPIC_SMALL_FAST_MODEL="${OVMS_MODEL}"
    # Ensure npm-global bin is in PATH (set by setup.sh, may not be in current session)
    export PATH="${HOME}/.npm-global/bin:${PATH}"
    exec claude ${EXTRA_ARGS}
}

launch_aider() {
    echo "Launching Aider → ${OPENAI_BASE}"
    if ! command -v aider &>/dev/null; then
        echo "Aider not found. Installing..."
        "${VENV_DIR}/bin/pip" install aider-chat
    fi
    # litellm (used by aider) requires "openai/" prefix for custom OpenAI-compatible endpoints
    exec "${VENV_DIR}/bin/aider" \
        --openai-api-base "${OPENAI_BASE}" \
        --openai-api-key  "local-ovms" \
        --model           "openai/${OVMS_MODEL}" \
        --no-check-update \
        ${EXTRA_ARGS}
}

launch_custom() {
    if [[ -z "$CUSTOM_CMD" ]]; then
        echo "ERROR: --agent custom requires --cmd 'your command here'"
        echo ""
        echo "Example:"
        echo "  $0 --agent custom --cmd \"mycli --api-base ${OPENAI_BASE} --model ${OVMS_MODEL}\""
        exit 1
    fi
    echo "Launching custom agent: ${CUSTOM_CMD}"
    # Expose env vars so custom commands can use them
    export OPENAI_API_BASE="${OPENAI_BASE}"
    export OPENAI_BASE_URL="${OPENAI_BASE}"
    export OPENAI_API_KEY="local-ovms"
    export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE}"
    export ANTHROPIC_API_KEY="local-ovms"
    export LOCAL_MODEL="${OVMS_MODEL}"
    eval "$CUSTOM_CMD"
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
echo ""
case "$AGENT" in
    claude)  launch_claude  ;;
    aider)   launch_aider   ;;
    custom)  launch_custom  ;;
    *)
        echo "Unknown agent: ${AGENT}"
        echo ""
        echo "Supported agents:"
        echo "  claude   — Claude Code (Anthropic API, port ${PROXY_PORT}/v1/messages)"
        echo "  aider    — Aider       (OpenAI API,    port ${PROXY_PORT}/v1/chat/completions)"
        echo "  custom   — Any tool    (use --cmd to specify)"
        echo ""
        echo "Any OpenAI-compatible tool can point to:"
        echo "  API base: ${OPENAI_BASE}"
        echo "  API key:  local-ovms (any value works)"
        echo "  Model:    ${OVMS_MODEL}"
        exit 1
        ;;
esac
