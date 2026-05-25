import Foundation

protocol TranscriptionEngine {
    func transcribe(audioPath: String) async throws -> String
}
