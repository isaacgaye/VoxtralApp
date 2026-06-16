# Voxtral Dictation — Architecture Spec (v2)

*v2 — radical simplification. Voxtral is now a **pure on-device transcription appliance**: hotkey → streaming STT → deterministic dictionary substitution → raw text at the cursor. No cleanup model, no modes, no transform service. Cleanup, when wanted, happens downstream in whatever LLM the user pastes into next. This supersedes the two-service v1 design.*

*Built and tested on a MacBook Air M5, 24GB (macOS Tahoe 26).*

---

## 1. Purpose

Hold a key, speak, raw text lands at the cursor — instantly, fully on-device. No audio or transcript leaves the machine, no cloud API, no token cost.

The deliberate bet of v2: **transcription and cleanup are separate concerns.** The user already runs a downstream LLM pass for cleanup, so building cleanup into the dictation tool was redundant work that added latency, a second resident model, and most of the system's complexity. Voxtral now does one thing — fast, accurate, local voice-to-text — and gets out of the way. The instant, field-native feel *is* the product.

---

## 2. Hard constraints (non-negotiable)

- **Local inference only.** No audio or transcript leaves the device. No cloud STT/LLM APIs in any path — privacy is the entire point.
- **Target machine:** MacBook Air M5, 24GB, fanless. Memory footprint and sustained-load thermals are first-class design concerns. *(v2 makes this far easier — one resident model instead of two.)*
- **Shareable as a public GitHub repo, technical audience.** (Revised from the original "non-technical colleagues" framing.) Clone + a couple of committed `bin/` scripts should get it running — no installer, no guided non-technical onboarding flow.

---

## 3. Architecture: one service, one pipeline

v1 was two composable services (STT + transform). v2 is a single linear pipeline:

```
mic ─▶ Audio Recorder ─▶ STT Client ─▶ Layer 2 substitution ─▶ Injector ─▶ cursor
       (AVFoundation)    (streaming,    (Swift, deterministic)   (AX + ⌘V)
                          continuous)
```

One inference service (STT only). No transform service, no mode branching, no clipboard/selection input sources, no context-driven prompt selection.

---

## 4. Components (one responsibility each)

1. **Hotkey Manager** — global key state machine on a single user-configurable key: hold-to-talk (release = stop), plus a double-tap-to-lock gesture (tap-tap = recording continues hands-free; one more tap = stop). Both live on the same key — no separate activation-mode setting.
2. **Audio Recorder** — mic → audio buffer (AVFoundation). Dumb.
3. **STT Client** — streams buffer → text via the local Voxtral sidecar. Continuous stream; **VAD is used only for end-of-utterance detection, not to slice audio into independently-transcribed chunks** (chunk-slicing hurt accuracy in the PoC).
4. **Dictionary** — Layer 2 deterministic `variant → canonical` substitution map (see §7).
5. **Injector** — text → cursor via clipboard write + synthesized ⌘V. (An earlier AX-direct path via `kAXValueAttribute` replaced the whole field and caused double-text; clipboard+paste is the only path now.)
6. **HUD Pill** — floating status indicator only (see §6).
7. **Config Store** — hotkey + dictionary. Plain JSON in Application Support (human-editable, shareable).
8. **Inference Sidecar** — local Python + MLX server (localhost), hosting the **STT model only**.

**Removed vs v1:** Context Provider (frontmost-app → mode selection) and Transform Client (Service 2). Both existed only to serve modes/cleanup.

---

## 5. Key decisions & rationale

- **Continuous streaming, VAD for endpointing only.** PoC showed chunk-slicing made accuracy unstable (mic-dependent VAD boundaries cut words mid-phoneme, lost context). Continuous streaming keeps full context with streaming latency.
- **Keep the current pill flow; remove only cleaning.** The pill works today and is the instant feel to preserve. Transcribed text streams into the pill as a rolling tail during recording (dim = provisional, solid = locked); finalized text is injected at the cursor on stop. The *only* removal is the post-stop cleaning step — text now goes straight from STT-final to injection, no transform in between.
- **Native Swift + Python/MLX sidecar.** Swift owns the system-level pieces (hotkeys, AX, injection, UI). MLX sidecar is the proven STT inference path from the PoC.

**Removed vs v1:** transform-model sizing rationale (no transform model exists anymore).

---

## 5b. Lifecycle & warm-up (hard requirement)

**The user must NEVER pay model warm-up at the moment of dictation.**

- **One model now — STT, always hot.** Launches at login (macOS LaunchAgent), loads the Voxtral model, runs a dummy inference at startup to force MLX graph compilation — hot before the first keypress. Stays resident.
- **No idle-unload timer.** That existed only to free the ~5GB transform model when idle. With a single resident STT model (~3–4GB), there is nothing to unload — the timer and its config are gone.
- App respects readiness: if triggered before the sidecar reports `stt:ready`, show a brief "warming up…" pill state rather than a frozen gap.

**Latency characterization (confirmed, M5 Air 24GB fanless):**
- *Input-streaming TTFT (mlx-audio v0.4.3):* ~2.3s from first chunk on a 9.9s FR/EN clip with `transcription_delay_ms=480`. `transcription_delay_ms` is the tuning lever: 160ms = faster / higher WER, 480ms = default sweet spot, 2400ms = best WER. App-phase tuning, not a blocker.
- *On-stop flush:* a small final STT decode of remaining buffered audio. The old ~370–500ms "Cleaning…" window is **gone** — it was Service 2's flush, and Service 2 no longer exists.

---

## 6. HUD pill states

Unchanged from current working behavior **except** the cleaning state is removed.

1. **Idle** — faint or hidden until hotkey. Zero noise when not dictating.
2. **Recording** — red dot + waveform + rolling tail of recent words (dim = provisional, solid = locked). A glance confirms accuracy; not a read-along.
3. ~~**Transcribing / cleaning**~~ — **removed.** This spinner state was scoped entirely to Service 2's flush window. On stop, text goes straight from STT-final to injection; any residual STT flush is sub-second and needs no dedicated state.
4. **Committed** — green check ("Pasted"), then fades to idle.

---

## 7. Dictionary (Layer 2 only)

**One single user-owned dictionary of entities.** Manually managed — add / edit / delete in a settings table. No detection, no learning, no pattern-matching. Transparent and fully user-owned.

### Layers — only Layer 2 survives
- **Layer 1 — STT context biasing.** *Unavailable on the entire local MLX path — verified across both the batch and streaming APIs.* `generate()` drops context via unreferenced `**kwargs`; `create_streaming_session()` / the session object / `feed()` / `step()` expose **no** context/prompt/hotword/vocabulary/bias parameter and have no catch-all to slip one in (mlx-audio v0.4.3 source inspection). Reserved only for an eventual Mistral-API path (non-confidential only).
- **Layer 2 — Deterministic live substitution (the dictionary).** Exact `variants → canonical` map applied to the token stream. Language-independent, no model support, runs live. **This is now the dictionary, in full.**
- **Layer 3 — LLM cleaning prompt.** *Removed.* It only existed to feed canonical terms into Service 2's prompt.

### Consequences of being Layer-2-only (read carefully)
- **Variants are now required.** Layer 2 matches *variant strings* in the stream. An entry with a canonical but **zero variants is inert** — there is nothing to match, so it does nothing. (In v1 a zero-variant entry was still useful via Layer 3; that is no longer true.) Every functional entry needs ≥1 variant.
- **No contextual disambiguation exists anywhere in the system.** Layer 2 is context-blind exact-match. It cannot tell a domain term from a common-word homophone (the "Isaac Guy" vs "guys" problem). There is no longer any layer that can.
- **Therefore: distinctive, low-collision terms only.** The dictionary is for distinctive multi-syllable domain vocabulary — `SFCC`, `Voxtral`, `Kubernetes`, `cartridge override map` — where a variant string won't appear inside common words. **Do not add entries whose variants collide with everyday words** (e.g. a surname spelled like "guy/guys"); they will clobber legitimate text. Such cases are delegated to the downstream LLM pass, same as all other cleanup.

```json
{ "canonical": "Voxtral", "variants": ["Voxtroll", "Vox trial"] }
{ "canonical": "SFCC",    "variants": ["sfcc", "S F C C"] }
```

---

## 8. Modes — removed

v2 has a single behavior (raw streaming + Layer 2). "Mode" is no longer a concept. Removed: the `Clean` / `Professional` / custom prompts, `AppConfig.json → modes{}`, the mode picker in the header menu, the Mode default in Settings, and the per-app "App Rules" mapping.

---

## 9. Scope

**MVP (v1.0) — Transcription core**
Hotkey (hold-to-talk, plus double-tap-to-lock for hands-free) → record → continuous streaming STT → raw text + Layer 2 substitution → inject at cursor (clipboard + ⌘V). Pill states 1–2 (+ optional 3). Settings: hotkey + dictionary editor.

**Deliberately deferred (banked, not built):**
- Any text transform / cleanup mode (the whole v1 Service 2 — explicitly out; cleanup is downstream).
- Per-app rules / auto-mode by frontmost app.
- "Clean my selection" / clipboard-transform surface.

These are recorded so the architecture stays honest about what was cut on purpose vs. forgotten. None are MVP.

---

## 10. Open items — verify during build

- Clipboard+⌘V injection reliability across native vs Electron/web apps (Slack, Teams).
- Accessibility-permission onboarding flow (detect missing → deep-link to settings pane) — still needed for the hotkey's CGEvent tap, independent of injection.
- TCC permission instability on rebuild (each clean build invalidates granted Accessibility permission) — needs a durable solution.
- Double-tap-to-lock timing thresholds (300ms tap / 500ms gap, see `HotkeyManager.swift`) are best-guess defaults — flagged for one real on-hardware validation pass.
- Sustained-load thermals on the fanless Air *(materially easier now — one model)*.

**Closed:** Layer 1 availability (unavailable, full API surface). Concurrent record-while-stream latency (Outcome A confirmed). Sidecar packaging (`bin/vox`/`bin/voxlog`/`bin/voxquit`, technical-audience GitHub repo). Double-tap-to-lock (implemented on the existing hotkey, no UI changes).

---

## 11. Tech stack

- **App / UI:** Swift / SwiftUI, menu-bar (`MenuBarExtra`), macOS 26 target.
- **System glue:** `CGEvent` (hotkey + ⌘V), `AVFoundation` (mic), Accessibility API (`AXUIElement`, field detection/injection). *(NSWorkspace frontmost-app no longer needed — Context Provider removed.)*
- **Inference:** Python + MLX sidecar over localhost. **STT only** = `mlx-audio` + Voxtral-Mini-4B-Realtime-2602-4bit.
  - *Streaming input API (confirmed v0.4.3):* `create_streaming_session()` / `feed(np.ndarray)` / `step()` / `close()` / `sess.done`. DO NOT use `generate(stream=True)` for live input — output-only, batch input.
  - **Removed:** Mistral-7B transform model, SSE transport, HTTP POST transform path.
- **Config:** JSON in `~/Library/Application Support/`.

---

## §12 Locked decisions — revised

**Surviving (still locked):**

| Decision | Resolution |
|---|---|
| STT IPC transport | WebSocket `ws://127.0.0.1:{PORT}/stt` — binary PCM frames up, JSON token frames down. Single connection per session. `URLSessionWebSocketTask` + FastAPI WebSocket. |
| Health contract | `GET /health` → `{"stt":"ready"\|"warming_up"}`. STT-only; the `transform` field is removed. |
| VAD ownership | Sidecar-side (`vad.py`). `EndpointDetector` emits `{"type":"eou"}`. eou is always advisory only — never authoritative, including during a double-tap-locked recording. Only a hotkey release or a deliberate tap ever stops a session. |
| Layer 2 ownership | Swift only. `STTClient` applies `DictionaryStore.layer2Map` to every received token. Sidecar is stateless on dictionaries. |
| Bundle ID | `com.voxtral.dictation` — committed, never changes. TCC (Accessibility + Mic) keys on this. Display name swappable via `CFBundleDisplayName`. |
| Audio wire format | 16 kHz / 16-bit signed / mono PCM throughout. |
| Default port | 50051, configurable via `AppConfig.json → sidecarPort`. |

**Killed (dead with the transform service):**
- Transform transport (HTTP POST + SSE).
- Transform model (`Mistral-7B-Instruct-v0.3-4bit`).
- Mode prompts (`AppConfig.json → modes{}`).
- Health contract `transform` field (`ready｜cold｜loading`).

---

## §13 UI simplification (this pass)

Concrete UI changes that follow from the cuts:

1. **Remove the "App Rules" tab** (per-app mode mapping, e.g. Outlook → Clean). Modes are gone, so the tab and the Context Provider behind it are removed.
2. **Remove the Mode picker** from the header menu *and* the "Mode: Raw" default in Settings. One behavior, nothing to pick.
3. **Remove "Idle unload: N min"** from Settings — it controlled the transform-model unload timer, which no longer exists.
4. **Settings → two tabs.** **Hotkey** (set the trigger button) and **Dictionary** (entity editor). The "App Rules" tab is removed; the Defaults section (Mode + Idle-unload) is removed. Tabbed window kept, down to these two.
5. **Dictionary editor — enlarge the Term / Variants input fields.** They are cramped; widen them. Keep the helper text "*Variants are replaced live during dictation (Layer 2)*" — and given §7, consider signalling that **at least one variant is needed** for an entry to do anything.
