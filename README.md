# Voxtral Dictation

A local-first, on-device dictation appliance for macOS. Hold a key, speak, raw text lands at the cursor — fully on-device, no cloud, no token cost. Cleanup/formatting is intentionally not this app's job; pipe the raw text into whatever downstream LLM pass you like.

For the full architecture and design rationale, see [`ARCHITECTURE.md`](ARCHITECTURE.md). For collaborator/session context, see [`CLAUDE.md`](CLAUDE.md). This README is just the quickstart.

Target audience: technical users, on a Mac (built and tested on Apple Silicon, macOS Tahoe 26). No installer — clone, build once, run.

## Setup

```bash
git clone <this repo>
cd voxtral-app

# 1. Sidecar: venv + Python deps + model download
export HF_TOKEN=<your-huggingface-token>
bash sidecar/setup.sh

# 2. App: build once (produces VoxtralApp/build/Build/Products/Debug/VoxtralApp.app)
bin/voxbuild
```

On first launch, macOS will ask for **Microphone** and **Accessibility** permissions — grant both (Accessibility is required for the global hotkey and for ⌘V injection). Note: a clean Xcode rebuild currently invalidates the granted Accessibility permission, so you may need to re-grant it after rebuilding.

## Running it

```bash
bin/voxbuild  # build (or rebuild after a code change) to the fixed path the scripts below expect
bin/vox       # launch (sidecar + app), quiet
bin/voxquit   # stop everything
bin/voxlog    # launch with verbose logging, tails /tmp/voxtral_app.log + /tmp/voxtral_sidecar.log live
```

`bin/vox` waits for the sidecar's `/health` endpoint to report the STT model is ready before opening the app, so you never race a cold model.

## Using it

- **Hold-to-talk**: hold the configured hotkey, speak, release to stop. Text is injected at the cursor immediately.
- **Double-tap-to-lock**: tap the hotkey twice quickly to start recording hands-free (no need to keep holding it) — useful for longer utterances. One more tap stops it and injects the text.
- The hotkey is configurable in **Settings → General** (fn, Right Option, or Right Command).

## Dictionary (Layer 2 substitution)

**Settings → Dictionary** lets you add terms with `variants → canonical` substitution, applied live during dictation — e.g. `Lengo, Lengow, lango → Lengow`. An entry needs at least one variant to do anything. Keep entries distinctive (multi-syllable domain terms); avoid variants that collide with common words, since matching is exact and context-blind — homophone disambiguation is left to your downstream LLM pass.

## Logging

Logging is off by default (no cost in normal use). `bin/voxlog` turns it on for that session (`VOXTRAL_LOG=1`) and tails:
- `/tmp/voxtral_app.log` — Swift app (hotkey state machine, injection, STT client lifecycle)
- `/tmp/voxtral_sidecar.log` — Python sidecar

## Repo layout

- `VoxtralApp/` — the SwiftUI menu-bar app
- `sidecar/` — Python + MLX inference service (STT only)
- `bin/` — `voxbuild` / `vox` / `voxlog` / `voxquit` scripts
- `scripts/download_models.sh` — model weight download (called by `sidecar/setup.sh`)
- `launchagent/` — optional "launch sidecar at login" LaunchAgent plist (advanced; `bin/vox` doesn't need it)
