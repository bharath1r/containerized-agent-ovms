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
import traceback
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
        timeout=300,
    )


def anthropic_to_openai(data: dict) -> dict:
    """Convert Anthropic /v1/messages request body → OpenAI chat format."""
    messages = data.get("messages", [])

    # Anthropic puts system prompt separately; move it into messages.
    # Claude Code sends a very large system prompt with tool definitions that
    # overwhelms small models — keep only the first 1500 chars.
    system = data.get("system")
    if system:
        if isinstance(system, list):
            system_text = " ".join(
                b.get("text", "") for b in system if isinstance(b, dict)
            )
        else:
            system_text = str(system)
        system_text = system_text[:1500]
        messages = [{"role": "system", "content": system_text}] + messages

    max_tokens = min(int(data.get("max_tokens", 1024)), 2048)

    return {
        "model":       data.get("model", MODEL_NAME),
        "messages":    messages,
        "max_tokens":  max_tokens,
        "temperature": data.get("temperature", 0.1),
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

@app.errorhandler(Exception)
def handle_exception(e):
    """Return JSON instead of HTML for unhandled exceptions."""
    traceback.print_exc()
    return jsonify({"error": {"message": str(e), "type": type(e).__name__}}), 500

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
    try:
        payload = request.get_json(force=True, silent=True) or {}
        payload.setdefault("model", MODEL_NAME)

        stream = payload.get("stream", False)
        resp = forward_to_ovms(payload)

        if resp.status_code != 200:
            return jsonify({"error": {"message": f"OVMS error {resp.status_code}: {resp.text[:500]}", "type": "upstream_error"}}), 502

        if stream:
            return Response(
                stream_with_context(resp.iter_content(chunk_size=None)),
                content_type=resp.headers.get("Content-Type", "text/event-stream"),
            )

        try:
            return jsonify(resp.json())
        except Exception:
            return jsonify({"error": {"message": f"OVMS returned non-JSON: {resp.text[:200]}", "type": "parse_error"}}), 502
    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": {"message": str(e), "type": type(e).__name__}}), 500


@app.route("/v1/messages", methods=["POST"])
def anthropic_messages():
    """
    Anthropic-format endpoint — used by Claude Code.
    Converts request to OpenAI format, forwards to OVMS, converts response back.
    """
    try:
        data = request.get_json(force=True, silent=True) or {}
        openai_payload = anthropic_to_openai(data)

        stream = openai_payload.get("stream", False)
        resp = forward_to_ovms(openai_payload)

        if resp.status_code != 200:
            return jsonify({"error": {"message": f"OVMS error {resp.status_code}: {resp.text[:500]}", "type": "upstream_error"}}), 502

        if stream:
            def generate():
                yield 'event: message_start\n'
                yield 'data: ' + json.dumps({
                    "type": "message_start",
                    "message": {
                        "id": "msg_stream", "type": "message", "role": "assistant",
                        "content": [], "model": MODEL_NAME,
                        "stop_reason": None, "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0},
                    }
                }) + '\n\n'
                yield 'event: content_block_start\n'
                yield 'data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}\n\n'
                yield 'event: ping\n'
                yield 'data: {"type":"ping"}\n\n'

                output_tokens = 0
                for line in resp.iter_lines():
                    if not line:
                        continue
                    decoded = line.decode('utf-8', errors='replace')
                    if not decoded.startswith('data: '):
                        continue
                    chunk_str = decoded[6:]
                    if chunk_str.strip() == '[DONE]':
                        break
                    try:
                        chunk = json.loads(chunk_str)
                        content = chunk.get('choices', [{}])[0].get('delta', {}).get('content', '')
                        if content:
                            output_tokens += 1
                            yield 'event: content_block_delta\n'
                            yield 'data: ' + json.dumps({
                                "type": "content_block_delta", "index": 0,
                                "delta": {"type": "text_delta", "text": content},
                            }) + '\n\n'
                    except (json.JSONDecodeError, KeyError, IndexError):
                        pass

                yield 'event: content_block_stop\n'
                yield 'data: {"type":"content_block_stop","index":0}\n\n'
                yield 'event: message_delta\n'
                yield 'data: ' + json.dumps({
                    "type": "message_delta",
                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                    "usage": {"output_tokens": output_tokens},
                }) + '\n\n'
                yield 'event: message_stop\n'
                yield 'data: {"type":"message_stop"}\n\n'

            return Response(
                stream_with_context(generate()),
                content_type="text/event-stream",
                headers={"X-Accel-Buffering": "no", "Cache-Control": "no-cache"},
            )

        try:
            return jsonify(openai_to_anthropic(resp.json()))
        except Exception:
            return jsonify({"error": {"message": f"OVMS returned non-JSON: {resp.text[:200]}", "type": "parse_error"}}), 502

    except Exception as e:
        traceback.print_exc()
        return jsonify({"error": {"message": str(e), "type": type(e).__name__}}), 500


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
