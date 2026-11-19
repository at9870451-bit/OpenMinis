import AVFoundation
import Foundation

/// No microphone or audio-session mutation. Decoding runs on a worker before
/// the owning call schedules this buffer on its duplex player.
enum VoiceCallAudioDecoder {
    struct Buffer: @unchecked Sendable { let pcm: AVAudioPCMBuffer }
    static func decode(_ data: Data) throws -> Buffer {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= 24 * 1024 * 1024 else { throw failure() }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("amore-call-\(UUID().uuidString).audio")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        defer { try? FileManager.default.removeItem(at: url) }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard file.length > 0, duration.isFinite, duration <= 120,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration * 48000)) + 512) else { throw failure() }
        try file.read(into: input)
        try Task.checkCancellation()
        var consumed = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        try Task.checkCancellation()
        guard output.frameLength > 0 else { throw failure() }
        return Buffer(pcm: output)
    }
    private static func failure() -> NSError {
        NSError(domain: "Amore.VoiceAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid or unsupported voice playback audio"])
    }
}
