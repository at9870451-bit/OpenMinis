import Foundation

enum VoiceCallWAV {
    /// The existing VAD returns canonical 16kHz mono 16-bit PCM WAV. Slice
    /// without re-encoding, ensuring a long sentence never becomes one huge
    /// provider request or silently disappears at a size guard.
    static func split(_ wav: Data, maxSeconds: Int = 24) -> [Data] {
        guard wav.count > 44, wav.count <= 16_000 * 2 * 180 + 256,
              String(data: wav.prefix(4), encoding: .ascii) == "RIFF",
              String(data: wav[8..<12], encoding: .ascii) == "WAVE",
              String(data: wav[36..<40], encoding: .ascii) == "data",
              UInt16(littleEndian: wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt16.self) }) == 1,
              UInt16(littleEndian: wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: UInt16.self) }) == 1,
              UInt32(littleEndian: wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }) == 16_000,
              UInt16(littleEndian: wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: UInt16.self) }) == 16 else { return [] }
        let size = Int(UInt32(littleEndian: wav.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }))
        guard size > 0, size <= wav.count - 44, size % 2 == 0 else { return [] }
        let step = max(1, min(30, maxSeconds)) * 32_000
        return stride(from: 0, to: size, by: step).map { start in
            let count = min(step, size - start)
            var header = Data(wav.prefix(44))
            var riff = UInt32(36 + count).littleEndian, payload = UInt32(count).littleEndian
            withUnsafeBytes(of: &riff) { header.replaceSubrange(4..<8, with: $0) }
            withUnsafeBytes(of: &payload) { header.replaceSubrange(40..<44, with: $0) }
            header.append(wav[(44 + start)..<(44 + start + count)])
            return header
        }
    }
}
