# containerized-agent-ovms

Local AI coding assistant using Claude Code + OpenVINO Model Server (OVMS) running Phi-3.5-mini on Intel CPU/GPU/NPU — no cloud API needed.

## Architecture

```
Any agent  →  simple_proxy.py (port 4000)  →  OVMS Docker (port 8000)  →  Phi-3.5-mini (INT4)
               Anthropic + OpenAI format          model server              Intel CPU / Arc GPU / NPU

Open WebUI (port 3000)  ──────────────────────────────────────────────────────────────^
  browser chat UI for any team member (no agent install needed)
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | One-time install: Docker, Python venv, Node.js, Claude Code, Aider, model download |
| `start.sh` | Start OVMS + proxy — auto-detects Intel GPU/NPU, falls back to CPU |
| `stop.sh` | Stop all services cleanly |
| `simple_proxy.py` | Flask bridge: Anthropic API + OpenAI API → OVMS |
| `launch-agent.sh` | Universal launcher — pick Claude Code, Aider, or any custom tool |
| `docker-compose.yml` | Full stack: OVMS + proxy + Open WebUI in one command |
| `Dockerfile.proxy` | Container image for simple_proxy.py |

## Quick start — Script mode (recommended for dev)

```bash
# ── First time only ──────────────────────────────────────────────────────────
git clone https://github.com/bharath1r/containerized-agent-ovms.git
cd containerized-agent-ovms

bash setup.sh                                  # no proxy
bash setup.sh --proxy http://your-proxy:911    # behind a corporate proxy

# ── Every session ────────────────────────────────────────────────────────────
bash start.sh           # auto-detects Intel GPU → NPU → CPU
bash start.sh --gpu     # force GPU (Intel Arc / Iris Xe)
bash start.sh --npu     # force NPU (Intel Core Ultra — requires intel-npu-driver)
bash start.sh --cpu     # force CPU

# ── Launch your agent ────────────────────────────────────────────────────────
bash launch-agent.sh --agent claude                             # Claude Code
bash launch-agent.sh --agent aider                              # Aider
bash launch-agent.sh --agent aider --args "--no-auto-commits"

# Any OpenAI-compatible tool
bash launch-agent.sh --agent custom --cmd "mytool --api-base http://localhost:4000/v1 --model Phi-3.5-mini"

# ── Stop services ────────────────────────────────────────────────────────────
bash stop.sh
```

## Quick start — Compose mode (persistent stack + browser UI)

```bash
# Start full stack (OVMS + proxy + Open WebUI)
TARGET_DEVICE=GPU docker compose up -d     # GPU
TARGET_DEVICE=CPU docker compose up -d     # CPU

# Open WebUI (browser chat — no agent install needed)
# http://localhost:3000

# Stop
docker compose down
```

## Supported agents

| Agent | How to use | API format |
|-------|-----------|------------|
| Claude Code | `bash launch-agent.sh --agent claude` | Anthropic `/v1/messages` |
| Aider | `bash launch-agent.sh --agent aider` | OpenAI `/v1/chat/completions` |
| Open WebUI | `http://localhost:3000` (compose only) | OpenAI |
| Continue.dev | Set `apiBase: http://localhost:4000/v1` in config | OpenAI |
| Cursor | Override API base in settings | OpenAI |
| Any OpenAI tool | `--api-base http://localhost:4000/v1 --api-key local-ovms` | OpenAI |

## Connection details (for manual config)

| Setting | Value |
|---------|-------|
| OpenAI API base | `http://localhost:4000/v1` |
| Anthropic API base | `http://localhost:4000` |
| API key | any value (e.g. `local-ovms`) |
| Model name | `Phi-3.5-mini` |

## Hardware targets

| Flag | Device | Requirement |
|------|--------|-------------|
| *(none)* | Auto: GPU → NPU → CPU | — |
| `--gpu` | Intel Arc / Iris Xe GPU | xe/i915 driver, `/dev/dri/renderD128` |
| `--npu` | Intel Core Ultra NPU | `intel-npu-driver`, `/dev/accel/accel0` |
| `--cpu` | CPU fallback | any x86 |

**NPU note**: OVMS GenAI LLM pipeline NPU support is experimental. GPU is recommended for best performance. Check `/dev/accel/accel0` exists before using `--npu`.

## Verify GPU/NPU is being used

```bash
# Check what device OVMS started with
docker inspect ovms-test --format '{{.Args}}' | grep target_device

# Check graph config (definitive)
cat ~/ovms-models/OpenVINO/Phi-3.5-mini-instruct-int4-ov/graph.pbtxt | grep device
```

