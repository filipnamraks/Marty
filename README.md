# Marty

A local-first macOS meeting transcriber.

Marty is a native macOS app that listens to your meetings and turns them into something you can use. It records both sides of a conversation, transcribes them on your own machine, and hands the text to Claude to make sense of. Audio and transcription never leave the Mac — only the text you choose to summarize is ever sent out.

## What it does

Marty has three parts.

**Live transcription.** Marty captures two audio tracks at once — your microphone and the system audio coming out of your Mac — so it hears both you and whoever you're meeting with on Zoom, Meet, or anything else. Both tracks run through Whisper on-device, and a speaker-labeled transcript (`You` / `Them`) builds up in real time. Transcripts auto-save as Markdown to `~/Documents/MeetingTranscripts/`.

**The write-up.** When you stop recording, Marty asks Claude to do two things in parallel: clean the raw transcript so it reads like a manuscript instead of stuttered speech-to-text, and write an editorial summary — a headline, a narrative recap, key points, decisions, action items, open questions, and notable quotes. From there you can export it as a Markdown or text file, to the clipboard, to Google Drive, or push it straight into Notion.

**The live assistant.** Hold a hotkey from anywhere — even mid-call — and ask Marty a question out loud. Whisper transcribes the question, Claude answers in a small floating panel that sits over whatever app you're in, and answers stay short and scannable. The assistant can search your Notion workspace, search the web, and read the last minute or two of the live transcript as context.

## How it's built

Marty is a native macOS app written in Swift and SwiftUI — no server, no web stack.

- **Audio capture.** The microphone is tapped through `AVAudioEngine`; system audio is captured with `ScreenCaptureKit`. A custom energy-based voice-activity detector (`VADChunker`) slices each stream into utterances as people speak.
- **Speech-to-text.** Runs entirely on-device using [WhisperKit](https://github.com/argmaxinc/WhisperKit) (OpenAI Whisper `large-v3`). The model downloads on first use (~500 MB) and is cached locally.
- **Intelligence.** Summaries, transcript cleanup, and the live assistant call the Anthropic API directly (Claude Haiku 4.5 / Sonnet 4.6), including a hand-written streaming (SSE) parser.
- **The assistant's tools.** The live assistant is a client-side agentic loop. A `ToolRegistry` exposes typed tools — Notion search and Exa web search — that Claude can call and get results back from within a single answer.
- **Connectors.** Google Calendar and Google Drive use an OAuth 2.0 loopback flow; Notion and Exa use API tokens. All secrets are stored in the macOS Keychain (`SecureStorage`), never in files or `UserDefaults`.

## Project layout

```
MeetingTranscriber.xcodeproj      Xcode project — two targets

MeetingTranscriber/               Command-line target + shared capture core
  main.swift                      CLI entry point (record / transcribe / live)
  MicCapture.swift                Microphone capture
  SystemCapture.swift             System-audio capture (ScreenCaptureKit)
  VADChunker.swift                Energy-based voice-activity detection
  WhisperKitEngine.swift          On-device speech-to-text
  TranscriptionEngine.swift       Transcription protocol

MeetingTranscriberApp2/           The Marty app (SwiftUI)
  ContentView.swift               Root layout
  LiveTranscriber.swift           Recording + transcription state machine
  Models/                         Plain data types
  Views/                          SwiftUI screens (Home, Transcript, Summary, Export, …)
  Services/                       Engines, connectors, storage, the HUD assistant
  Theme.swift                     Editorial visual style
```

The two targets share the low-level capture and Whisper code in `MeetingTranscriber/`. The CLI target is the original prototype; `MeetingTranscriberApp2` is the full app.

## Requirements

- A recent version of macOS and Xcode (the project targets macOS 26.5).
- An [Anthropic API key](https://console.anthropic.com/settings/keys) — required for summaries and the assistant. A summary costs roughly half a cent.
- Optional: Google, Notion, and Exa credentials to enable those connectors.

## Building and running

1. Open `MeetingTranscriber.xcodeproj` in Xcode. It resolves the WhisperKit Swift package automatically on first open.
2. Select the **MeetingTranscriberApp2** scheme and run.
3. On first launch, onboarding walks you through pasting your Anthropic API key and granting **Microphone** and **Screen Recording** permissions.
4. The first transcription downloads the Whisper model (~500 MB); later runs use the cached copy.

Tip: use headphones during meetings so your microphone doesn't pick up the other side's audio.

### Enabling the Google connectors

The Google OAuth credentials are not committed to this repository. To use the Calendar and Drive features, follow the one-time Google Cloud Console setup documented at the top of `MeetingTranscriberApp2/Services/GoogleCalendarProvider.swift`, then copy the credentials template:

```bash
cp MeetingTranscriberApp2/Services/GoogleSecrets.swift.example \
   MeetingTranscriberApp2/Services/GoogleSecrets.swift
```

and fill in your Client ID and Client secret. `GoogleSecrets.swift` is gitignored, so your credentials stay on your machine and never get committed. The other connectors (Anthropic, Notion, Exa) are configured from inside the app's Settings and stored in the macOS Keychain.

## The command-line tool

The `MeetingTranscriber` target is a small CLI that exercises the capture and transcription core:

```
MeetingTranscriber record         <output.caf> [seconds]   # record the mic
MeetingTranscriber record-system  <output.caf> [seconds]   # record system audio
MeetingTranscriber transcribe     <input.caf>              # transcribe a file
MeetingTranscriber live           [seconds]                # live dual-channel transcription
```

## Privacy

Marty is local-first by design. Audio capture and speech-to-text happen entirely on your Mac. The only data that leaves the machine is the transcript text you choose to send to Anthropic for a summary or to the live assistant, plus anything you explicitly export to Google Drive or Notion. API keys live in the macOS Keychain.
