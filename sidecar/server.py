"""
FastAPI server — mounts all routes; owns the ModelManager singleton.

Routes:
  WS   /stt        → stt.stt_endpoint  (WebSocket, binary PCM in / JSON tokens out)
  GET  /health     → {"stt": "ready" | "warming_up"}
"""
from __future__ import annotations

from fastapi import FastAPI, WebSocket
from fastapi.responses import JSONResponse

from model_manager import ModelManager
from stt import stt_endpoint

app     = FastAPI(title="Voxtral Sidecar")
manager = ModelManager()


@app.websocket("/stt")
async def ws_stt(websocket: WebSocket) -> None:
    await stt_endpoint(websocket, manager)


@app.get("/health")
async def get_health() -> JSONResponse:
    return JSONResponse({"stt": manager.stt_state.value})
