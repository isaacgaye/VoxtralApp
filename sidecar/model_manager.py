"""
ModelManager — loads and holds the STT model.

STT model is always hot (latency-critical; non-negotiable per §5b). v2 is
STT-only — there is no transform model anymore.
"""
from __future__ import annotations

from enum import Enum
from typing import Any, Optional

from mlx_audio.stt.utils import load as _load_stt_model


class ModelState(str, Enum):
    WARMING_UP = "warming_up"
    READY      = "ready"


class ModelManager:
    STT_MODEL_ID = "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

    def __init__(self) -> None:
        self._stt_model: Optional[Any] = None
        self._stt_state  = ModelState.WARMING_UP

    @property
    def stt_state(self) -> ModelState:
        return self._stt_state

    def load_stt(self) -> None:
        # Called once from main.py at startup, before any concurrent access.
        # No lock needed here — STT model is immutable after this point.
        self._stt_model = _load_stt_model(self.STT_MODEL_ID)
        self._stt_state = ModelState.READY

    def get_stt(self) -> Any:
        if self._stt_model is None:
            raise RuntimeError("STT model not loaded — call load_stt() before serving requests")
        return self._stt_model
