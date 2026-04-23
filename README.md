# containerized-agent-ovms

Local AI coding assistant using Claude Code + OpenVINO Model Server (OVMS) running Phi-3.5-mini on Intel CPU/GPU — no cloud API needed.

## Architecture

```
Any agent  →  simple_proxy.py (port 4000)  →  OVMS Docker (port 8000)  →  Phi-3.5-mini (INT4)
               Anthropic + OpenAI format          model server              Intel CPU / Arc GPU
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-time install: Docker, Python venv, Node.js, Claude Code, Aider, model download |
| `start.sh` | Start OVMS + proxy — auto-detects Intel GPU, falls back to CPU |
| `stop.sh` | Stop all services cleanly |
| `simple_proxy.py` | Flask bridge: Anthropic API + OpenAI API → OVMS |
| `launch-agent.sh` | Universal launcher — pick Claude Code, Aider, or any custom tool |

## Quick start

```bash
# First time only
bash setup.sh --proxy http://your-proxy:911   # omit --proxy if not behind one

# Every session
bash ~/start.sh

# Launch your agent
bash ~/launch-agent.sh --agent claude          # Claude Code
bash ~/launch-agent.sh --agent aider           # Aider
bash ~/launch-agent.sh --agent aider --args "--no-auto-commits"

# Any OpenAI-compatible tool
bash ~/launch-agent.sh --agent custom --cmd "mytool --api-base http://localhost:4000/v1 --model Phi-3.5-mini"
```

## Connection details (for manual config)

| Setting | Value |
|---------|-------|
| OpenAI API base | `http://localhost:4000/v1` |
| Anthropic API base | `http://localhost:4000` |
| API key | any value (e.g. `local-ovms`) |
| Model name | `Phi-3.5-mini` |

## Hardware targets

- Intel Core Ultra / Arc GPU (xe driver) — GPU inference (auto-detected)
- Any x86 CPU — automatic fallback

