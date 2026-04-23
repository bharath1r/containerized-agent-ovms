#!/usr/bin/env python3
"""
simple_proxy.py — Universal OVMS adapter (port 4000)

Accepts both Anthropic and OpenAI API formats so any agent can use it:

  Anthropic format  POST /v1/messages          → Claude Code
  OpenAI format     POST /v1/chat/completions  → Aider, Continue.dev, etc.
  Models list       GET  /v1/models            → agent discovery
  Health            GET  /health

All requests are forwarded to OVMS at http://localhost:8000/v3/chat/completions
"""

import os
import json
import requests
from flask import Flask, request, jsonify, Response, stream_with_context

app = Flask(__name__)

OVMS_URL    = os.environ.get("OVMS_URL", "http://localhost:8000/v3/chat/completions")
MODEL_NAME  = os.environ.get("MODEL_NAME", "Phi-3.5-mini")
PROXY_PORT  = int(os.environ.get("PROXY_PORT", "4000"))


# ─── Helpers ──────────────────────────────────────────────────────────────────

def forward_to_ovms(openai_payload: dict) -> requests.Response:
    """Send an OpenAI-format payload to OVMS and return the raw response."""
    openai_payload.setdefault("model", MODEL_NAME)
    return requests.post(
        OVMS_URL,
        json=openai_payload,
        headers={"Content-Type": "application/json"},
        stream=openai_payload.get("stream", False),
        timeout=120,
    )


def anthropic_to_openai(data: dict) -> dict:
    """Convert Anthropic /v1/messages request body → OpenAI chat format."""
    messages = data.get("messages", [])

    # Anthropic puts system prompt separately; move it into messages
    system = data.get("system")
    if system:
        messages = [{"role": "system", "content": system}] + messages

    return {
        "model":       data.get("model", MODEL_NAME),
        "messages":    messages,
        "max_tokens":  data.get("max_tokens", 1024),
        "temperature": data.get("temperature", 0.7),
        "stream":      data.get("stream", False),
    }


def openai_to_anthropic(openai_resp: dict) -> dict:
    """Convert OpenAI chat response → Anthropic /v1/messages response."""
    choice  = openai_resp.get("choices", [{}])[0]
    content = choice.get("message", {}).get("content", "")
    usage   = openai_resp.get("usage", {})
    return {
        "id":           f"msg_{openai_resp.get('id', 'unknown')}",
        "type":         "message",
        "role":         "assistant",
        "model":        openai_resp.get("model", MODEL_NAME),
        "stop_reason":  "end_turn",
        "content":      [{"type": "text", "text": content}],
        "usage": {
            "input_tokens":  usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0),
        },
    }


# ─── Routes ───────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def health():
    """Health check — also probes OVMS."""
    try:
        r = requests.get(
            OVMS_URL.replace("/chat/completions", "/models"),
            timeout=3,
        )
        ovms_ok = r.status_code < 500
    except Exception:
        ovms_ok = False
    return jsonify({"status": "healthy", "ovms_reachable": ovms_ok})


@app.route("/v1/models", methods=["GET"])
def list_models():
    """OpenAI-compatible model listing (used by Aider, Continue.dev, etc.)."""
    return jsonify({
        "object": "list",
        "data": [
            {
                "id":       MODEL_NAME,
                "object":   "model",
                "owned_by": "ovms",
                "created":  0,
            }
        ],
    })


@app.route("/v1/chat/completions", methods=["POST"])
def openai_chat():
    """
    OpenAI-format endpoint — used by Aider, Continue.dev, Cursor, etc.
    Passes through directly to OVMS (same format).
    """
    payload = request.json or {}
    payload.setdefault("model", MODEL_NAME)

    stream = payload.get("stream", False)
    resp = forward_to_ovms(payload)

    if resp.status_code != 200:
        return jsonify({"error": f"OVMS error {resp.status_code}: {resp.text}"}), 502

    if stream:
        return Response(
            stream_with_context(resp.iter_content(chunk_size=None)),
            content_type=resp.headers.get("Content-Type", "text/event-stream"),
        )

    return jsonify(resp.json())


@app.route("/v1/messages", methods=["POST"])
def anthropic_messages():
    """
    Anthropic-format endpoint — used by Claude Code.
    Converts request to OpenAI format, forwards to OVMS, converts response back.
    """
    data = request.json or {}
    openai_payload = anthropic_to_openai(data)

    stream = openai_payload.get("stream", False)
    resp = forward_to_ovms(openai_payload)

    if resp.status_code != 200:
        return jsonify({"error": f"OVMS error {resp.status_code}: {resp.text}"}), 502

    if stream:
        # Stream back as Anthropic SSE format
        def generate():
            for chunk in resp.iter_lines():
                if chunk:
                    yield chunk.decode() + "\n"
        return Response(stream_with_context(generate()), content_type="text/event-stream")

    return jsonify(openai_to_anthropic(resp.json()))


# ─── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print(f"OVMS proxy listening on port {PROXY_PORT}")
    print(f"  Forwarding to: {OVMS_URL}")
    print(f"  Default model: {MODEL_NAME}")
    print(f"  Endpoints:")
    print(f"    GET  /health")
    print(f"    GET  /v1/models")
    print(f"    POST /v1/chat/completions  (OpenAI — Aider, Continue.dev, ...)")
    print(f"    POST /v1/messages          (Anthropic — Claude Code)")
    app.run(host="0.0.0.0", port=PROXY_PORT)
