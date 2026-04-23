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
# ── First time only ──────────────────────────────────────────────────────────
git clone https://github.com/bharath1r/containerized-agent-ovms.git
cd containerized-agent-ovms

bash setup.sh                                  # no proxy
bash setup.sh --proxy http://your-proxy:911    # behind a corporate proxy

# ── Every session ────────────────────────────────────────────────────────────
bash ~/start.sh           # auto-detects Intel GPU, falls back to CPU
bash ~/start.sh --gpu     # force GPU (Intel Arc / Iris Xe)
bash ~/start.sh --cpu     # force CPU

# ── Launch your agent ────────────────────────────────────────────────────────
bash ~/launch-agent.sh --agent claude                             # Claude Code
bash ~/launch-agent.sh --agent aider                              # Aider
bash ~/launch-agent.sh --agent aider --args "--no-auto-commits"   # Aider options

# Any OpenAI-compatible tool
bash ~/launch-agent.sh --agent custom --cmd "mytool --api-base http://localhost:4000/v1 --model Phi-3.5-mini"

# ── Stop services ────────────────────────────────────────────────────────────
bash ~/stop.sh
```

## Connection details (for manual config)

| Setting | Value |
|---------|-------|
| OpenAI API base | `http://localhost:4000/v1` |
| Anthropic API base | `http://localhost:4000` |
| API key | any value (e.g. `local-ovms`) |
| Model name | `Phi-3.5-mini` |

## Hardware targets

| Flag | Behaviour |
|------|-----------|
| *(none)* | Auto-detects Intel GPU via `/dev/dri/renderD128` + vendor ID `8086:*`, falls back to CPU |
| `--gpu` | Force GPU — requires Intel xe/i915 driver and `/dev/dri/renderD128` |
| `--cpu` | Force CPU — works on any x86 machine |

GPU is passed into the Docker container via `--device /dev/dri --group-add <render_gid>` only when GPU mode is active.

