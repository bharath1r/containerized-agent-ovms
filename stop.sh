#!/bin/bash
# =============================================================================
# stop.sh — Stop all OVMS + proxy services
# =============================================================================

echo "Stopping services..."

# Docker command (use sudo if group not active yet)
if docker info &>/dev/null 2>&1; then
    DOCKER_CMD="docker"
else
    DOCKER_CMD="sudo docker"
fi

# OVMS container
$DOCKER_CMD stop ovms-test 2>/dev/null && echo "  OVMS stopped" || true
$DOCKER_CMD rm   ovms-test 2>/dev/null || true

# Proxy process (by PID file or process name)
if [[ -f /tmp/simple_proxy.pid ]]; then
    kill "$(cat /tmp/simple_proxy.pid)" 2>/dev/null && echo "  Proxy stopped" || true
    rm -f /tmp/simple_proxy.pid
fi
pkill -f "simple_proxy.py" 2>/dev/null || true

echo "Done."
