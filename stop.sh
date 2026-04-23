#!/bin/bash
# =============================================================================
# stop.sh — Stop all OVMS + proxy services
# =============================================================================

echo "Stopping services..."

# OVMS container
docker stop ovms-test 2>/dev/null && echo "  OVMS stopped" || true
docker rm   ovms-test 2>/dev/null || true

# Proxy process (by PID file or process name)
if [[ -f /tmp/simple_proxy.pid ]]; then
    kill "$(cat /tmp/simple_proxy.pid)" 2>/dev/null && echo "  Proxy stopped" || true
    rm -f /tmp/simple_proxy.pid
fi
pkill -f "simple_proxy.py" 2>/dev/null || true

echo "Done."
