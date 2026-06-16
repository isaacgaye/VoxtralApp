"""
VAD — webrtcvad-wheels wrapper.
Frame-level speech detection + stateful end-of-utterance detection.

STOP-SIGNAL PRECEDENCE RULE (enforced in stt.py, documented here):
  Hold-to-talk mode:    hotkey RELEASE is the authoritative session-end.
                        EOU from this module is ADVISORY — caller sends
                        {"type":"eou"} to lock the pill tail (dim→solid)
                        but must NOT close the session.
  Double-tap-toggle:    EOU from this module MAY auto-stop the session
                        (no held key; user delegated the stop decision).
"""
from __future__ import annotations

from typing import Generator

import webrtcvad  # webrtcvad-wheels: Python 3.14-compatible drop-in; same import name


SAMPLE_RATE        = 16_000   # must match AudioRecorder (16 kHz)
FRAME_DURATION_MS  = 30       # webrtcvad supports 10 / 20 / 30 ms
FRAME_BYTES        = int(SAMPLE_RATE * FRAME_DURATION_MS / 1000) * 2  # int16 mono = 960


class EndpointDetector:
    """Sliding-window silence counter → emits EOU after N consecutive silent frames."""

    def __init__(self, aggressiveness: int = 2, silent_frames_threshold: int = 15) -> None:
        self._vad          = webrtcvad.Vad(aggressiveness)
        self._threshold    = silent_frames_threshold
        self._silent_count = 0

    def reset(self) -> None:
        self._silent_count = 0

    def process_frame(self, pcm_frame: bytes) -> bool:
        """Return True the moment end-of-utterance is detected."""
        is_speech = self._vad.is_speech(pcm_frame, SAMPLE_RATE)
        if is_speech:
            self._silent_count = 0
            return False
        self._silent_count += 1
        # Fires True on every call once threshold is reached; repeated firing is intentional —
        # callers (stt.py) must call reset() immediately on the first True return.
        # If reset() is not called, this keeps returning True on each subsequent silent frame.
        return self._silent_count >= self._threshold


def iter_frames(pcm_bytes: bytes) -> Generator[bytes, None, None]:
    """Yield FRAME_BYTES-sized PCM frames from a raw buffer."""
    for i in range(0, len(pcm_bytes) - FRAME_BYTES + 1, FRAME_BYTES):
        yield pcm_bytes[i : i + FRAME_BYTES]
