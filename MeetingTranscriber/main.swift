import Foundation

func usage() -> Never {
    print("""
    Usage:
      MeetingTranscriber record        <output.caf> [seconds]
      MeetingTranscriber record-system <output.caf> [seconds]
      MeetingTranscriber transcribe    <input.caf> [model] [prompt]
      MeetingTranscriber transcribe-batch <dir> [model] [rollingPrompt 0|1]
      MeetingTranscriber live          [seconds]
    """)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 2 else { usage() }

let command = args[1]

let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

let task = Task {
    do {
        switch command {
        case "record":
            guard args.count >= 3 else { usage() }
            let path = args[2]
            let seconds = args.count >= 4 ? (Double(args[3]) ?? 10) : 10
            let url = URL(fileURLWithPath: path)
            print("Recording \(seconds)s from default mic to \(url.path)...")
            let mic = MicCapture()
            try await mic.record(to: url, durationSeconds: seconds)
            print("Saved \(url.path)")

        case "record-system":
            guard args.count >= 3 else { usage() }
            let path = args[2]
            let seconds = args.count >= 4 ? (Double(args[3]) ?? 10) : 10
            let url = URL(fileURLWithPath: path)
            print("Recording \(seconds)s of system audio to \(url.path)...")
            print("(If prompted, grant Screen Recording permission in System Settings → Privacy & Security.)")
            let sys = SystemCapture()
            try await sys.record(to: url, durationSeconds: seconds)
            print("Saved \(url.path)")

        case "transcribe":
            guard args.count >= 3 else { usage() }
            let path = args[2]
            print("Loading WhisperKit (first run downloads the model, ~500MB)...")
            // Optional model + prompt args let us A/B-test the app's exact decode
            // setup (model choice, rolling prompt) on a kept utterance clip.
            let engine: TranscriptionEngine = args.count >= 4
                ? try await WhisperKitEngine(model: args[3],
                                             initialPrompt: args.count >= 5 ? args[4] : nil)
                : try await WhisperKitEngine()
            print("Model loaded. Transcribing \(path)...")
            let text = try await engine.transcribe(audioPath: path)
            print("---")
            print(text)
            print("---")

        case "transcribe-batch":
            // Replays a kept session's clips through ONE engine instance,
            // back-to-back, updating the rolling prompt between clips — the
            // exact conditions of LiveTranscriber's worker. Reproduces failures
            // that single-clip tests can't (rapid serial inference + prompt).
            guard args.count >= 3 else { usage() }
            let dir = URL(fileURLWithPath: args[2])
            let model = args.count >= 4 ? args[3] : "openai_whisper-large-v3-v20240930_turbo"
            let useRollingPrompt = args.count >= 5 ? (args[4] == "1") : true
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "caf" }
                .sorted { a, b in
                    let na = Int(a.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") ?? 0
                    let nb = Int(b.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "") ?? 0
                    return na < nb
                }
            print("Loading \(model)...")
            // Optional 6th arg: a STATIC prompt held for every clip (tests
            // prompt-on-reused-engine without the rolling updates).
            let staticPrompt = args.count >= 6 ? args[5] : nil
            let batchEngine = try await WhisperKitEngine(model: model, initialPrompt: staticPrompt)
            var transcribed: [String] = []
            var emptyCount = 0
            for f in files {
                let t0 = Date()
                do {
                    let text = try await batchEngine.transcribe(audioPath: f.path)
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let dt = String(format: "%.1f", Date().timeIntervalSince(t0))
                    if trimmed.isEmpty || trimmed == "[BLANK_AUDIO]" {
                        emptyCount += 1
                        print("[\(f.lastPathComponent)] (\(dt)s) <EMPTY>")
                    } else {
                        print("[\(f.lastPathComponent)] (\(dt)s) \(trimmed)")
                        transcribed.append(trimmed)
                    }
                } catch {
                    emptyCount += 1
                    print("[\(f.lastPathComponent)] ERROR: \(error)")
                }
                // Mirror LiveTranscriber.updateRollingPrompt: recent tail, ~600 chars.
                if useRollingPrompt {
                    var tail: [String] = []
                    var chars = 0
                    for line in transcribed.reversed() {
                        chars += line.count + 1
                        if chars > 600 { break }
                        tail.append(line)
                    }
                    let recent = tail.reversed().joined(separator: " ")
                    batchEngine.initialPrompt = recent.isEmpty ? nil : recent
                }
            }
            print("---\n\(files.count) clips, \(emptyCount) empty/error")

        case "live":
            let seconds = args.count >= 3 ? (Double(args[2]) ?? 120) : 120

            print("Loading WhisperKit...")
            let engine: TranscriptionEngine = try await WhisperKitEngine()

            // Open transcript file in ~/Documents/MeetingTranscripts/
            let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Documents/MeetingTranscripts")
            try? FileManager.default.createDirectory(at: transcriptsDir,
                                                     withIntermediateDirectories: true)
            let fileTsFormatter = DateFormatter()
            fileTsFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let mdURL = transcriptsDir.appendingPathComponent("\(fileTsFormatter.string(from: Date())).md")
            FileManager.default.createFile(atPath: mdURL.path, contents: nil)
            guard let mdHandle = try? FileHandle(forWritingTo: mdURL) else {
                throw NSError(domain: "Main", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not open transcript file"])
            }
            let headerFormatter = DateFormatter()
            headerFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            let header = "# Meeting transcript — \(headerFormatter.string(from: Date()))\n\n"
            try? mdHandle.write(contentsOf: Data(header.utf8))

            print("Listening for \(Int(seconds))s — speak into your mic and play meeting audio.")
            print("Saving transcript to \(mdURL.path)\n")

            let (stream, continuation) = AsyncStream.makeStream(of: (String, URL, Date).self)

            let micChunker = VADChunker(label: "You") { label, url in
                continuation.yield((label, url, Date()))
            }
            let sysChunker = VADChunker(label: "Them") { label, url in
                continuation.yield((label, url, Date()))
            }

            let mic = MicCapture()
            try mic.startStreaming { buf in micChunker.feed(buf) }

            let sys = SystemCapture()
            try await sys.startStreaming { buf in sysChunker.feed(buf) }

            // Transcription worker
            let worker = Task {
                for await (label, url, ts) in stream {
                    do {
                        let text = try await engine.transcribe(audioPath: url.path)
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty && trimmed != "[BLANK_AUDIO]" {
                            let line = "[\(timeFormatter.string(from: ts))] [\(label)] \(trimmed)"
                            print(line)
                            try? mdHandle.write(contentsOf: Data((line + "\n").utf8))
                        }
                    } catch {
                        print("(transcription error: \(error))")
                    }
                    try? FileManager.default.removeItem(at: url)
                }
            }

            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            mic.stop()
            try await sys.stop()
            continuation.finish()
            _ = await worker.value
            try? mdHandle.close()
            print("\nDone. Saved \(mdURL.path)")

        default:
            usage()
        }
        exit(0)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
