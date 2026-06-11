# Marty

A macOS meeting transcriber that files what was said under your agenda's headlines, live.

Marty is a native macOS app. Before a meeting you give it an agenda — pasted as Markdown, or fetched from Google Calendar or Notion. While you talk, it transcribes both sides of the conversation **on your own Mac** and, every half-minute or so, files the new points as bullets under the right headline. When you stop, a final editorial pass rewrites the whole document into a clean record of the meeting: labeled decisions, owners, next steps, and a "Not covered" marker on anything the meeting skipped.

Audio never leaves the machine. The only thing sent anywhere is transcript text, to the Anthropic API.

## What it does

**Live transcription.** Marty captures two audio tracks at once — your microphone (`You`) and the system audio coming out of your Mac (`Them`) — so it hears both you and whoever you're meeting with on Zoom, Meet, or anything else. Both tracks run through Whisper on-device, and a speaker-labeled transcript builds up in real time. Transcripts auto-save as Markdown to `~/Documents/MeetingTranscripts/`.

**The living agenda.** This is the core of the app. Each agenda section is filled incrementally as the conversation reaches it: bounded chunks of new transcript go to a fast Claude model (Haiku), which routes each spoken point to the section it belongs to — guided by your own prepared bullets, the recent context, and the order of the agenda. Bullets are written to stand alone: someone who missed the meeting should understand each point without the transcript. Tangents that fit no headline land in an **Off agenda** parking lot. The document auto-saves next to the transcript after every update — closing the app loses nothing.

**The write-up.** On stop, a stronger Claude model (Sonnet) re-reads the complete transcript and rewrites every section authoritatively — deduplicating, fixing anything the live pass mis-filed, labeling concrete outcomes (**Decision:** / **Owner:** / **Risk:** / **Next step:**). You can also generate a narrative summary and a cleaned manuscript-style transcript, then export everything as Markdown or text, to the clipboard, to Google Drive, or straight into Notion.

## How it's built

Marty is a native macOS app written in Swift and SwiftUI — no server, no web stack, no accounts.

- **Audio capture.** The microphone is tapped through `AVAudioEngine`; system audio is captured with `ScreenCaptureKit`. A custom energy-based voice-activity detector (`VADChunker`) slices each stream into utterances as people speak.
- **Speech-to-text.** Runs entirely on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI Whisper `large-v3-turbo` by default), pinned to the Neural Engine so it never competes with anything for the GPU. The model downloads on first use (~600 MB) and is cached locally.
- **Intelligence.** Agenda fills, the refine pass, summaries, and transcript cleanup call the Anthropic API directly (`claude-haiku-4-5` for latency-critical live work, `claude-sonnet-4-6` for quality-critical passes). Live fills are append-only and bounded (≤12 transcript lines per request) so they stay fast for the whole meeting, self-heal on transient API failures, and surface any problem in the UI instead of failing silently.
- **Connectors.** Google Calendar and Google Drive use an OAuth 2.0 loopback flow (PKCE, per RFC 8252); Notion uses an integration token. All connectors are optional and off until you connect them.
- **Secrets.** Everything sensitive — the Anthropic API key, Google refresh token, Notion token — lives in the macOS Keychain (`SecureStorage`), never in files or `UserDefaults`.

## Privacy & data flow

Written out explicitly, because it matters:

- **Audio:** captured and transcribed entirely on-device. Never uploaded, never sent anywhere. Per-utterance audio is kept locally next to the transcript so a higher-quality re-transcription stays possible.
- **Transcript text:** sent to `api.anthropic.com` over HTTPS — incrementally during recording (for live agenda fills) and in full when you stop (for the refine pass, summary, and cleanup). That is the entire automatic network surface.
- **Optional, user-initiated:** exports to Google Drive or Notion send the document to your own accounts; fetching an agenda reads from your Calendar/Notion. These never happen unless you connected the service and clicked the action.
- **Model download:** WhisperKit fetches the Whisper model from Hugging Face once, on first use.
- **Nothing else.** No telemetry, no analytics, no crash reporting, no accounts, no third-party SDKs beyond WhisperKit and Apple's `swift-argument-parser`.
- **Optional diagnostics (off by default):** Settings has a "Collect usage diagnostics" toggle. When enabled, Marty records *how it behaved* — fill timings, error counts, utterance statistics; numbers only, never any transcript text, headlines, or names. The data stays in a local file and is never transmitted; an "Export diagnostics" button produces a human-readable JSON you can inspect line by line and share by hand if you choose. A delete button removes everything collected.

## Project layout

```
MeetingTranscriber.xcodeproj      Xcode project — two targets

MeetingTranscriber/               Command-line target + shared capture core
  main.swift                      CLI entry point (record / transcribe / transcribe-batch / live)
  MicCapture.swift                Microphone capture
  SystemCapture.swift             System-audio capture (ScreenCaptureKit)
  VADChunker.swift                Energy-based voice-activity detection
  WhisperKitEngine.swift          On-device speech-to-text (ANE-pinned)
  TranscriptionEngine.swift       Transcription protocol

MeetingTranscriberApp2/           The Marty app (SwiftUI)
  ContentView.swift               Root layout + page routing
  LiveTranscriber.swift           Recording + transcription state machine
  Models/                         Plain data types (Agenda, transcript, summary, …)
  Views/                          SwiftUI screens (agenda document, transcript, settings, …)
  Services/
    AnthropicEngine.swift         The LLM client (api.anthropic.com, non-streaming)
    AgendaFiller.swift            Live fill scheduling — cadence, chunking, self-healing
    AgendaFillPrompts.swift       The fill prompts + JSON contract, shared with the smoke test
    AgendaSidecar.swift           Auto-saves the agenda document next to the transcript
    AgendaResolver.swift          Natural-language agenda fetch (Calendar / Notion / Drive)
    DemoSession.swift             Scripted demo (⇧⌘D scripted, ⌥⇧⌘D through the real pipeline)
    SecureStorage.swift           Keychain wrapper
    …                             Connectors, sidecars, library persistence
  Theme.swift                     Editorial visual style

scripts/
  anthropic_incremental_smoke.py  Validates the agenda-fill API contract end-to-end
```

The two targets share the low-level capture and Whisper code in `MeetingTranscriber/`. The CLI target is a developer tool for exercising the capture/transcription core in isolation.

## Requirements

- An Apple Silicon Mac on a recent macOS (the project targets macOS 26.5) and Xcode.
- An [Anthropic API key](https://console.anthropic.com/settings/keys). A typical meeting costs roughly $0.30–0.60 per hour in API usage; the post-meeting passes add a few cents more.
- Optional: Google and Notion credentials to enable those connectors.

## Building and running

1. Open `MeetingTranscriber.xcodeproj` in Xcode. It resolves the WhisperKit Swift package automatically on first open.
2. Select the **MeetingTranscriberApp2** scheme and run.
3. On first launch, onboarding walks you through pasting your Anthropic API key and granting **Microphone** and **Screen Recording** permissions.
4. The first transcription downloads the Whisper model (~600 MB); later runs use the cached copy.

Tip: use headphones during meetings so your microphone doesn't pick up the other side's audio.

To see the whole pipeline without holding a meeting: **View → Run Demo Session (Real Fills)** (⌥⇧⌘D) replays a scripted conversation through the live agenda-fill pipeline against the real API.

### Enabling the Google connectors

The Google OAuth credentials are not committed to this repository. To use the Calendar and Drive features, follow the one-time Google Cloud Console setup documented at the top of `MeetingTranscriberApp2/Services/GoogleCalendarProvider.swift`, then copy the credentials template:

```bash
cp MeetingTranscriberApp2/Services/GoogleSecrets.swift.example \
   MeetingTranscriberApp2/Services/GoogleSecrets.swift
```

and fill in your Client ID and Client secret. `GoogleSecrets.swift` is gitignored, so your credentials stay on your machine and never get committed. The Anthropic and Notion keys are configured from inside the app's Settings and stored in the macOS Keychain.

## Testing

`scripts/anthropic_incremental_smoke.py` validates the agenda-fill contract against the live API — it mirrors the app's system prompts verbatim and asserts routing (including a snippet that straddles two topics), append-only behavior, bullet quality, and token-budget headroom:

```bash
ANTHROPIC_API_KEY=sk-ant-... python3 scripts/anthropic_incremental_smoke.py
```

## The command-line tool

The `MeetingTranscriber` target is a small CLI that exercises the capture and transcription core:

```
MeetingTranscriber record            <output.caf> [seconds]      # record the mic
MeetingTranscriber record-system     <output.caf> [seconds]      # record system audio
MeetingTranscriber transcribe        <input.caf> [model] [prompt] # transcribe a file
MeetingTranscriber transcribe-batch  <session-audio-dir>          # replay a session's clips through one engine
MeetingTranscriber live              [seconds]                    # live dual-channel transcription
```

## License

MIT — see [LICENSE](LICENSE).
