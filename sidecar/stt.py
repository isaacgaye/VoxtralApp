"""
STT WebSocket endpoint — ws://127.0.0.1:{PORT}/stt

Receives binary PCM frames (16 kHz / 16-bit / mono) from Swift AudioRecorder.
Feeds frames into an mlx-audio streaming session; emits transcription tokens as JSON.

Streaming input API (confirmed mlx-audio v0.4.3 — use this, NOT generate(stream=True)):
  sess = model.create_streaming_session()
  sess.feed(np.ndarray)   ← float32 audio chunk
  tokens = sess.step()    ← returns any tokens ready so far
  sess.close()
  sess.done               ← True when session is finished
  StreamingAudioSource + generate_streaming() is a higher-level wrapper over this API.

Wire format (sidecar → Swift):
  {"type": "token",  "text": "bonjour "}
  {"type": "eou"}
  {"type": "error",  "msg": "..."}
"""
from __future__ import annotations

import asyncio
import functools
import json

import numpy as np
from fastapi import WebSocket, WebSocketDisconnect

from vad import EndpointDetector, iter_frames


async def stt_endpoint(websocket: WebSocket, model_manager) -> None:
    # VAD stop-signal precedence rule:
    # HOLD-TO-TALK: hotkey release is the authoritative session-end.
    #   VAD eou is ADVISORY — transitions pill tail dim→solid only.
    #   This endpoint never closes the WS session on VAD eou alone.
    # DOUBLE-TAP-TOGGLE: VAD eou MAY auto-stop (no held key; user
    #   delegated the stop decision). Swift closes the WS on receipt.
    #
    # ⚠️ G5 — OUTCOME A CONFIRMED (mlx-audio v0.4.3, validated on
    #   real 9.9s FR/EN clip). Concurrent record-while-stream works.
    #   Use create_streaming_session() / feed() / step() / close().
    #   DO NOT use generate(stream=True) — that is output-only,
    #   batch input. See ARCHITECTURE.md §5b for latency numbers.
    await websocket.accept()

    sess = None
    endpoint = EndpointDetector()

    try:
        sess = model_manager.get_stt().create_streaming_session(
            transcription_delay_ms=480  # latency/quality lever; see §5b
        )
    except Exception as exc:
        await websocket.send_text(json.dumps({"type": "error", "msg": str(exc)}))
        await websocket.close()
        return

    try:
        while True:
            pcm_bytes = await websocket.receive_bytes()
            await _process_chunk(websocket, pcm_bytes, sess, endpoint)
            if sess.done:  # very short audio — session ended before Swift disconnected
                break
    except WebSocketDisconnect:
        pass  # normal exit; finally handles cleanup
    except Exception as exc:
        try:
            await websocket.send_text(json.dumps({"type": "error", "msg": str(exc)}))
        except Exception:
            pass  # WS may already be gone
    finally:
        if sess is not None:
            sess.close()
            # Drain remaining tokens to release MLX resources. Tokens are intentionally
            # discarded here — Swift has already disconnected at this point.
            while not sess.done:
                await asyncio.to_thread(functools.partial(sess.step, max_decode_tokens=4))
        endpoint.reset()


async def _process_chunk(
    websocket: WebSocket,
    pcm_bytes: bytes,
    sess,
    endpoint: EndpointDetector,
) -> None:
    # 1. Convert int16 PCM to float32 normalised [-1.0, 1.0]
    audio_np = np.frombuffer(pcm_bytes, dtype=np.int16).astype(np.float32) / 32768.0

    # 2. Feed audio — cheap queue push, no MLX work, safe on event-loop thread
    sess.feed(audio_np)

    # 3. Decode — step() holds the MLX executor; run in thread to avoid blocking event loop.
    #    functools.partial over to_thread **kwargs: raises immediately if step()'s signature
    #    ever becomes positional-only, rather than silently passing a wrong kwarg.
    tokens: list[str] = await asyncio.to_thread(
        functools.partial(sess.step, max_decode_tokens=4)
    )
    for token in tokens:
        await websocket.send_text(json.dumps({"type": "token", "text": token}))

    # 4. VAD: one EOU per chunk maximum; reset so next silence window starts fresh
    for frame in iter_frames(pcm_bytes):
        if endpoint.process_frame(frame):
            await websocket.send_text(json.dumps({"type": "eou"}))
            endpoint.reset()
            break
