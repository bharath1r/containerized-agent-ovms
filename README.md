# containerized-agent-ovms

Local AI coding assistant using Claude Code + OpenVINO Model Server (OVMS) on Intel CPU/GPU/NPU — no cloud API needed. Ships with Phi-3.5-mini by default; swap to any OpenVINO INT4/INT8 model with one flag.

## Architecture

```
Any agent  →  simple_proxy.py (port 4000)  →  OVMS Docker (port 8000)  →  any OpenVINO INT4/INT8 model
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

bash setup.sh                                  # no proxy, default model (Phi-3.5-mini)
bash setup.sh --proxy http://your-proxy:911    # behind a corporate proxy
bash setup.sh --model OpenVINO/Llama-3.2-3B-Instruct-int4-ov   # different model

# ── Every session ────────────────────────────────────────────────────────────
bash start.sh           # auto-detects Intel GPU → NPU → CPU
bash start.sh --gpu     # force GPU (Intel Arc / Iris Xe)
bash start.sh --npu     # force NPU (Intel Core Ultra — requires intel-npu-driver)
bash start.sh --cpu     # force CPU
bash start.sh --model Llama-3.2-3B-Instruct-int4-ov --gpu   # use a different model

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
TARGET_DEVICE=GPU docker compose up -d     # GPU, default model
TARGET_DEVICE=CPU docker compose up -d     # CPU

# Use a different model (pass as env vars or put in .env file)
MODEL_REPO=OpenVINO/Llama-3.2-3B-Instruct-int4-ov \
OVMS_MODEL=Llama-3.2-3B-Instruct-int4-ov \
TARGET_DEVICE=GPU docker compose up -d

# Or via .env file (persistent across restarts)
cat >> .env <<EOF
MODEL_REPO=OpenVINO/Llama-3.2-3B-Instruct-int4-ov
OVMS_MODEL=Llama-3.2-3B-Instruct-int4-ov
TARGET_DEVICE=GPU
EOF
docker compose up -d

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

## Changing the model

Any model from the [OpenVINO org on HuggingFace](https://huggingface.co/OpenVINO) that is in INT4/INT8 IR format works.

```bash
# 1. Download the model (one-time; --skip-aider --skip-docker-pull skips re-installing tools)
bash setup.sh --model srang992/Llama-3.2-3B-Instruct-ov-INT4 --skip-aider --skip-docker-pull

# 2. Stop any running session
bash stop.sh

# 3. Start OVMS with the new model
bash start.sh --model srang992/Llama-3.2-3B-Instruct-ov-INT4 --gpu

# 4. Launch an agent — set OVMS_MODEL to the folder name (last segment of the HF repo path)
OVMS_MODEL=Llama-3.2-3B-Instruct-ov-INT4 bash launch-agent.sh --agent aider
OVMS_MODEL=Llama-3.2-3B-Instruct-ov-INT4 bash launch-agent.sh --agent claude

# Tip: export it once to avoid repeating it
export OVMS_MODEL=Llama-3.2-3B-Instruct-ov-INT4
bash launch-agent.sh --agent aider
bash launch-agent.sh --agent claude
```

For compose mode:
```bash
MODEL_REPO=srang992/Llama-3.2-3B-Instruct-ov-INT4 \
OVMS_MODEL=Llama-3.2-3B-Instruct-ov-INT4 \
TARGET_DEVICE=GPU docker compose up -d
```

The `OVMS_MODEL` value must match the **folder name** of the downloaded model under `~/ovms-models/` (i.e. the last segment of the HuggingFace repo path: `owner/folder` → use `folder`).

**Some tested models:**

| Model | HF repo | Size | Gated? | NPU? |
|-------|---------|------|--------|------|
| Phi-3.5-mini (default) | `OpenVINO/Phi-3.5-mini-instruct-int4-ov` | ~2 GB | No | Yes |
| Llama 3.2 3B (ungated) | `srang992/Llama-3.2-3B-Instruct-ov-INT4` | ~2 GB | No | No |
| Llama 3.2 3B (ungated) | `llmware/llama-3.2-3b-instruct-ov` | ~2 GB | No | No |
| Llama 3.2 3B (official) | `OpenVINO/Llama-3.2-3B-Instruct-int4-ov` | ~2 GB | Yes* | Yes |
| Llama 3.2 1B (official) | `OpenVINO/Llama-3.2-1B-Instruct-int4-ov` | ~1 GB | Yes* | Yes |
| Qwen2.5 7B | `OpenVINO/Qwen2.5-7B-Instruct-int4-ov` | ~4.5 GB | No | No |
| Mistral 7B | `OpenVINO/Mistral-7B-Instruct-v0.2-int4-ov` | ~4.5 GB | No | No |

\* **Gated model** — requires accepting the license on HuggingFace and a token:
1. Accept at `https://huggingface.co/<repo>`
2. Get a token at `https://huggingface.co/settings/tokens`
3. Pass it: `bash setup.sh --model <repo> --hf-token hf_YOUR_TOKEN`  
   or via env: `HF_TOKEN=hf_xxx bash setup.sh --model <repo>`

## Connection details (for manual config)

| Setting | Value |
|---------|-------|
| OpenAI API base | `http://localhost:4000/v1` |
| Anthropic API base | `http://localhost:4000` |
| API key | any value (e.g. `local-ovms`) |
| Model name | matches `OVMS_MODEL` (default: `Phi-3.5-mini-instruct-int4-ov`) |

## Hardware targets

| Flag | Device | Requirement |
|------|--------|-------------|
| *(none)* | Auto: GPU → NPU → CPU | — |
| `--gpu` | Intel Arc / Iris Xe GPU | xe/i915 driver, `/dev/dri/renderD128` |
| `--npu` | Intel Core Ultra NPU | `intel-npu-driver`, `/dev/accel/accel0` |
| `--cpu` | CPU fallback | any x86 |

**NPU note**: NPU requires models exported with NPU-targeted compilation. Community re-uploads (e.g. `srang992/`, `llmware/`) are CPU/GPU only and will fail on NPU with "Failed to compile for NPU". Use models from the official `OpenVINO/` org for NPU, e.g. `OpenVINO/Phi-3.5-mini-instruct-int4-ov`. GPU is recommended for best compatibility across all models.

## Verify GPU/NPU is being used

```bash
# Check what device OVMS started with
docker inspect ovms-test --format '{{.Args}}' | grep target_device

# Check graph config (definitive)
cat ~/ovms-models/OpenVINO/Phi-3.5-mini-instruct-int4-ov/graph.pbtxt | grep device
```

## Uninstall

Remove individual components interactively:

```bash
bash uninstall.sh          # prompts yes/no for each component
bash uninstall.sh --all    # remove everything without prompting
```

Components covered: running services, downloaded models, Python venv, OVMS Docker image, installed scripts, Claude Code.

To delete just a single model without running uninstall.sh:
```bash
rm -rf ~/ovms-models/srang992/Llama-3.2-3B-Instruct-ov-INT4
```

