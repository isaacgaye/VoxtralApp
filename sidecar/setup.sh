#!/usr/bin/env bash
# Guided sidecar setup. Run once per machine. Safe to re-run (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

echo "=== Voxtral Sidecar Setup ==="

# 1. Virtual environment
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python venv..."
    python3 -m venv "$VENV_DIR"
fi

# 2. Dependencies
echo "Installing dependencies..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install setuptools
"$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt"

# 3. Models
echo "Downloading models..."
bash "$SCRIPT_DIR/../scripts/download_models.sh"

echo ""
echo "Setup complete. To start the sidecar at login:"
echo "  cp $SCRIPT_DIR/../launchagent/com.voxtral.dictation.sidecar.plist ~/Library/LaunchAgents/"
echo "  # Edit the plist to set the absolute paths (REPLACE placeholders)"
echo "  launchctl load ~/Library/LaunchAgents/com.voxtral.dictation.sidecar.plist"
