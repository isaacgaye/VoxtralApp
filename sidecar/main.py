"""
Sidecar entrypoint.

Persistent, pre-warmed background service — never spawned per dictation (§5b).
Launched at login via LaunchAgent (com.voxtral.dictation.sidecar).

Startup sequence:
  1. Load STT model (always hot)
  2. Warm up both models (forces MLX JIT compilation)
  3. Accept connections — sidecar is ready before first keypress
"""
from __future__ import annotations

import logging
import os

import uvicorn

from server import app, manager
from warmup import warm_up

VERBOSE = os.environ.get("VOXTRAL_LOG") == "1"


def _configure_logging() -> None:
    if VERBOSE:
        logging.basicConfig(
            level=logging.DEBUG,
            filename="/tmp/voxtral_sidecar.log",
            format="%(asctime)s %(name)s %(levelname)s %(message)s",
        )
    else:
        logging.basicConfig(level=logging.WARNING)


def main() -> None:
    _configure_logging()
    manager.load_stt()
    warm_up(manager)
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=50051,
        log_level="debug" if VERBOSE else "warning",
    )


if __name__ == "__main__":
    main()
