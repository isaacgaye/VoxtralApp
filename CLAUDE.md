# CLAUDE.md — Voxtral Dictation (CC session seed)

> Clean rewrite for **v2 (radical simplification)**. Supersedes the two-service version. If anything here disagrees with `ARCHITECTURE.md`, the architecture doc wins — flag the conflict, don't guess.

## What this is

A **local-first, on-device transcription appliance**. Hotkey → streaming STT → deterministic dictionary substitution → raw text at the cursor. Fully local, no cloud, no token cost, no audio or transcript ever leaves the device. Target machine: MacBook Air M5, 24GB, macOS Tahoe 26.

**v2 is one thing only: fast accurate local voice-to-text.** Cleanup is NOT this app's job — the user runs a downstream LLM pass for that. There is no transform model, no modes, no cleaning.

## Hard constraints (non-negotiable)

- Local inference only. No audio or transcript leaves the device. No cloud STT/LLM in any confidential path.
- Fanless M5 Air, 24GB. Memory + thermals are first-class concerns.
- Shareable to non-technical colleagues — simple setup, guided permissions.

## Architecture (v2 — single pipeline)

```
mic ─▶ Audio Recorder ─▶ STT Client ─▶ Layer 2 substitution ─▶ Injector ─▶ cursor
       (AVFoundation)    (streaming)    (Swift, deterministic)   (AX + ⌘V)
```

One inference service (STT only). No transform service, no mode branching, no clipboard/selection input, no per-app context selection.

**Components:** Hotkey Manager (hold-to-talk, plus a double-tap-to-lock gesture on the same key for hands-free recording — tap-tap to lock, one more tap to stop) · Audio Recorder · STT Client (continuous stream; VAD = end-of-utterance only, never chunk-slicing) · Dictionary (Layer 2 only) · Injector (clipboard write + synthesized ⌘V — AX-direct injection was tried and dropped, it replaced the whole field and caused double-text) · HUD Pill (status: idle / recording+rolling-tail / committed — NO cleaning state) · Config Store (hotkey + dictionary JSON) · Inference Sidecar (Python+MLX, **STT model only**).

## Dictionary — Layer 2 only

- **Layer 1 (STT biasing): unavailable** on the entire local MLX path — verified across batch `generate()` AND `create_streaming_session()`/`feed()`/`step()` (mlx-audio v0.4.3). No context/prompt/hotword/vocab param exists; no catch-all to add one.
- **Layer 2 (the dictionary): deterministic `variants → canonical` substitution**, Swift-side, applied live to every received token. This is the whole dictionary now.
- **Layer 3 (LLM cleaning prompt): removed** with Service 2.

**Rules that follow:**
- An entry with **zero variants is inert** — Layer 2 has nothing to match. Every functional entry needs ≥1 variant.
- Layer 2 is **context-blind exact-match** — it cannot disambiguate homophones (the "Isaac Guy" vs "guys" problem). Nothing in the system can anymore.
- **Distinctive, low-collision terms only.** Do NOT add variants that collide with everyday words; they will clobber legitimate text. Homophone cases go to the downstream LLM.

## Locked decisions — do not re-litigate

- STT transport: WebSocket `ws://127.0.0.1:{PORT}/stt`, binary PCM up / JSON tokens down. `URLSessionWebSocketTask` + FastAPI.
- Health: `GET /health` → `{"stt":"ready"|"warming_up"}`. **STT-only — no `transform` field.**
- VAD sidecar-side (`vad.py`), emits `{"type":"eou"}`. Hotkey-release authoritative in hold-to-talk; eou advisory only.
- Layer 2 ownership: **Swift only.** `STTClient` applies `DictionaryStore.layer2Map`. Sidecar is stateless on dictionaries. `layer2_sub.py` does not exist.
- Bundle ID: `com.voxtral.dictation` — never changes. TCC keys on this. Display name swappable via `CFBundleDisplayName`.
- Audio wire format: 16 kHz / 16-bit signed / mono PCM throughout.
- Default port: 50051, configurable via `AppConfig.json → sidecarPort`.

**Killed in v2 (dead — remove on sight, don't preserve):** transform transport (HTTP POST + SSE) · transform model (Mistral-7B) · mode prompts (`AppConfig.json → modes{}`) · health `transform` field · Context Provider · idle-unload timer.

## Lifecycle

- One model (STT), **always hot**. LaunchAgent at login → load weights → dummy inference to force MLX compile → resident. App waits for `stt:ready` before accepting dictation (brief "warming up…" pill otherwise).
- **No idle-unload timer** — that was the transform model's; with ~3–4GB STT-only resident there's nothing to unload. RAM relief, if ever needed, is "quit Voxtral," not a timer that ambushes the next dictation.

## Environment

- macOS Tahoe 26, Xcode 27 beta. Python 3.14.5.
- ML stack: `mlx-audio==0.4.3`, MLX, Voxtral-Mini-4B-Realtime-2602-4bit. Weights cached at `~/.cache/huggingface/hub/`.
- If you're behind a corporate SSL-inspecting proxy, `pip`/`hf` may need extra cert configuration. Builds use `CODE_SIGNING_REQUIRED=NO`.
- `pip` is NOT aliased — use `pip3` or `python3 -m pip`. `setuptools` must be installed explicitly. Use the `hf` CLI (not deprecated `huggingface-cli`).

## Key paths

- Repo: `~/claude/voxtral-app` · PoC: `~/claude/voxtral-poc`
- Logs: `/tmp/voxtral_app.log`, `/tmp/voxtral_sidecar.log` — only written when `VOXTRAL_LOG=1` (set by `bin/voxlog`); empty/absent otherwise. Unrelated: `/tmp/com.voxtral.dictation.sidecar.{out,err}` are the LaunchAgent's own stdout/stderr redirect, only relevant if running the sidecar via LaunchAgent instead of `bin/vox`.
- Config: `~/Library/Application Support/` (`AppConfig.json`)

## Build / run

```
bin/voxbuild
```

Wraps `xcodebuild -scheme VoxtralApp -configuration Debug CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -derivedDataPath ./build clean build`. `-derivedDataPath ./build` is required — `bin/vox`/`bin/voxlog` open the app from that fixed, predictable path rather than Xcode's per-machine DerivedData hash.

Committed scripts in `bin/` (portable, no personal-shell dependency — see README.md):
- `bin/voxbuild` — build/rebuild the app to the fixed path the other scripts expect
- `bin/vox` — kill any running instance, relaunch sidecar + app, quiet (no logging)
- `bin/voxlog` — same, but with verbose logging on (`VOXTRAL_LOG=1`); tails both log files live
- `bin/voxquit` — kill both processes cleanly

## Working discipline (locked)

- **Any manually installed package → immediately update `requirements.txt` AND `setup.sh`.** No exceptions.
- **Plan Mode is the review gate** before any feature implementation. Explore → plan → (approve) → implement → commit.
- **Manual approve mode is always on.** Nothing runs without review.
- `/clear` between CC sessions for context hygiene. Repeated compaction in long sessions is expected, not an error.
- Verify capabilities on the **actual constrained stack**, never from docs/memory. A cloud-API feature ≠ a local-MLX feature.
- Architecture before tooling. Single responsibility per component. Decouple by default.

## Gotchas

- Two sidecar instances compete for Metal/GPU memory — the `pkill -f` guard in `bin/_common.sh` prevents ghost-process collisions.
- TCC Accessibility permission is invalidated on each clean build (open item — needs a durable fix).
- Real TTFT from first chunk is ~2.3s (NOT ~400ms — that was batch prefill latency).
- `open VoxtralApp.app` does not propagate shell-exported env vars to the launched process (LaunchServices, not a direct fork/exec) — this is why `bin/_common.sh` launches the binary directly (`Contents/MacOS/VoxtralApp`) rather than via `open`, so `VOXTRAL_LOG` set by `bin/voxlog` actually reaches the app.

## Current state

- **v2 simplification complete** (2026-06-15): transform/modes/cleanup fully removed from the Swift app, docs rewritten for the single-pipeline architecture, health sink spam fixed.
- **V3 cleanup pass complete** (2026-06-16):
  1. Double-tap-to-lock implemented on the existing hotkey — `HotkeyManager.swift` disambiguates it from the hardware dual-fire artifact by deciding on the *second tap's release*, not its press (see file comments for the full reasoning). No UI/config changes; `ActivationMode`/`.toggle` (always dead) removed.
  2. Logging is now env-gated (`VOXTRAL_LOG=1`) on both sides — replaces the old unconditional `diagLog()`/`print()` calls; added new coverage to `Injector.swift` and `STTClient.swift`.
  3. Sidecar fully caught up to the v2 docs: `transform.py` deleted, `model_manager.py`/`server.py` stripped to STT-only (they had silently still carried the full Mistral-7B transform service despite the docs already describing it as removed), `mlx-lm` dropped from `requirements.txt`.
  4. Shareable packaging: `bin/vox` / `bin/voxlog` / `bin/voxquit` committed (portable, path-relative — no personal `~/.zshrc` dependency). `stale context.md` deleted; `README.md` added.
- **Open:** TCC Accessibility permission invalidated on each clean build — needs durable fix (stable signing identity). Double-tap-lock timing thresholds (300ms tap / 500ms gap) are best-guess defaults — flagged for one real on-hardware validation pass.
