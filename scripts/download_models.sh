#!/usr/bin/env bash
# Download the STT model via hf CLI. Detects and skips it if already cached.
set -euo pipefail

VOXTRAL_ID="mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit"

if [ -z "${HF_TOKEN:-}" ]; then
    echo "Error: HF_TOKEN is not set. Run: export HF_TOKEN=<your-token>"
    exit 1
fi

export HF_TOKEN

VOXTRAL_CACHE="$HOME/.cache/huggingface/hub/models--mlx-community--Voxtral-Mini-4B-Realtime-2602-4bit"
if [ -d "$VOXTRAL_CACHE" ]; then
    echo "Voxtral weights found in cache — skipping."
else
    echo "Downloading Voxtral-Mini-4B-Realtime-2602-4bit (~3.5GB)..."
    hf download "$VOXTRAL_ID"
fi

echo "Models ready."
