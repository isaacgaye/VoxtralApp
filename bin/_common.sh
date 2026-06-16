#!/usr/bin/env bash
# Shared by bin/vox, bin/voxquit, bin/voxlog. Not meant to be run directly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIDECAR_DIR="$REPO_ROOT/sidecar"
VENV_PYTHON="$SIDECAR_DIR/.venv/bin/python3"
APP_BIN="$REPO_ROOT/VoxtralApp/build/Build/Products/Debug/VoxtralApp.app/Contents/MacOS/VoxtralApp"
PORT="${VOXTRAL_PORT:-50051}"
HEALTH_URL="http://127.0.0.1:$PORT/health"

stop_voxtral() {
    pkill -f "$APP_BIN" 2>/dev/null || true
    pkill -f "$SIDECAR_DIR/main.py" 2>/dev/null || true
}

start_voxtral() {
    if [ ! -x "$VENV_PYTHON" ]; then
        echo "Error: sidecar venv not found. Run sidecar/setup.sh first." >&2
        exit 1
    fi
    if [ ! -x "$APP_BIN" ]; then
        echo "Error: VoxtralApp.app not built. Build it first — see README.md." >&2
        exit 1
    fi

    echo "Starting sidecar..."
    (cd "$SIDECAR_DIR" && exec "$VENV_PYTHON" main.py) &
    disown

    echo "Waiting for sidecar to warm up..."
    for _ in $(seq 1 60); do
        if status=$(curl -s "$HEALTH_URL" 2>/dev/null) && [[ "$status" == *'"stt":"ready"'* ]]; then
            echo "Sidecar ready."
            "$APP_BIN" &
            disown
            return 0
        fi
        sleep 1
    done

    echo "Error: sidecar did not become ready within 60s." >&2
    exit 1
}
