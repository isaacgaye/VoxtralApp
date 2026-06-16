"""
warmup — forces MLX JIT compilation for the STT model at sidecar startup.
Must complete before the server begins accepting connections (§5b: user must
never pay warm-up at dictation time).

Uses the confirmed streaming session API (mlx-audio v0.4.3):
  create_streaming_session() / feed() / step() / close()
"""
from __future__ import annotations

import logging

import numpy as np

logger = logging.getLogger("voxtral.warmup")

STT_SAMPLE_RATE = 16_000
STT_WARMUP_SECS = 0.5   # 8000 samples — just above the 480ms transcription_delay_ms window


def warm_up(model_manager) -> None:
    """Force MLX JIT compilation for the STT model before accepting connections."""
    _warmup_stt(model_manager)


def _warmup_stt(model_manager) -> None:
    logger.debug("warmup: STT starting — forcing MLX JIT compilation")
    silence = np.zeros(int(STT_WARMUP_SECS * STT_SAMPLE_RATE), dtype=np.float32)
    model   = model_manager.get_stt()
    sess    = model.create_streaming_session(transcription_delay_ms=480)
    sess.feed(silence)
    sess.step(max_decode_tokens=4)   # first step triggers MLX graph compile
    sess.close()
    while not sess.done:             # drain to release session resources cleanly
        sess.step(max_decode_tokens=4)
    logger.debug("warmup: STT complete — model hot, sidecar ready")
