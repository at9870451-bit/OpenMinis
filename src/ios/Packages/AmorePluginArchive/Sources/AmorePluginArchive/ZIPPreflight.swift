import Foundation

/// ZIPFoundation's iterator can stop at an unreadable entry. Check the central
/// directory independently so a valid prefix cannot masquerade as a full ZIP.
enum ZIPPreflight {
    static func validate(_ url: URL) throws -> Int {
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count >= 22 else { throw PluginArchiveError.invalid("Truncated archive") }
        let lower = max(0, bytes.count - 65557)
        var end: Int?
        for index in stride(from: bytes.count - 22, through: lower, by: -1) {
            if u32(bytes, index) == 0x06054b50,
               index + 22 + Int(u16(bytes, index + 20)) == bytes.count {
                end = index
                break
            }
        }
        guard let end else { throw PluginArchiveError.invalid("End of ZIP directory missing") }
        let count = Int(u16(bytes, end + 10))
        let directorySize = Int(u32(bytes, end + 12))
        let directoryOffset = Int(u32(bytes, end + 16))
        guard count > 0, count <= PluginArchive.maximumEntries else { throw PluginArchiveError.tooManyFiles }
        guard u16(bytes, end + 4) == 0, u16(bytes, end + 6) == 0,
              Int(u16(bytes, end + 8)) == count,
              directorySize != Int(UInt32.max), directoryOffset != Int(UInt32.max),
              directoryOffset <= end, directorySize <= end - directoryOffset else {
            throw PluginArchiveError.invalid("Multi-volume or ZIP64 packages are not supported")
        }
        var position = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        var total: UInt64 = 0
        for _ in 0..<count {
            guard position + 46 <= directoryEnd, u32(bytes, position) == 0x02014b50 else {
                throw PluginArchiveError.invalid("Damaged central directory")
            }
            let flags = u16(bytes, position + 8)
            let method = u16(bytes, position + 10)
            let compressed = Int(u32(bytes, position + 20))
            let uncompressed = UInt64(u32(bytes, position + 24))
            let nameLength = Int(u16(bytes, position + 28))
            let extraLength = Int(u16(bytes, position + 30))
            let commentLength = Int(u16(bytes, position + 32))
            let local = Int(u32(bytes, position + 42))
            let attributes = u32(bytes, position + 38)
            let mode = (attributes >> 16) & 0xf000
            guard flags & 0x0041 == 0, method == 0 || method == 8 else {
                throw PluginArchiveError.invalid("Encrypted or unsupported compression")
            }
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else {
                throw PluginArchiveError.invalid("Symbolic links and special files are not allowed")
            }
            let next = position + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, next <= directoryEnd,
                  local >= 0, local + 30 <= directoryOffset,
                  u32(bytes, local) == 0x04034b50,
                  u16(bytes, local + 6) == flags, u16(bytes, local + 8) == method else {
                throw PluginArchiveError.invalid("Invalid ZIP entry header")
            }
            let localNameLength = Int(u16(bytes, local + 26))
            let localExtraLength = Int(u16(bytes, local + 28))
            let payload = local + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, payload <= directoryOffset,
                  compressed <= directoryOffset - payload,
                  bytes.subdata(in: (local + 30)..<(local + 30 + localNameLength))
                    == bytes.subdata(in: (position + 46)..<(position + 46 + nameLength)) else {
                throw PluginArchiveError.invalid("ZIP local/central entry mismatch")
            }
            total += uncompressed
            guard total <= UInt64(PluginArchive.maximumBytes) else { throw PluginArchiveError.tooLarge }
            position = next
        }
        guard position == directoryEnd else { throw PluginArchiveError.invalid("Unexpected central directory data") }
        return count
    }

    private static func u16(_ data: Data, _ i: Int) -> UInt16 {
        UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
    }
    private static func u32(_ data: Data, _ i: Int) -> UInt32 {
        UInt32(data[i]) | (UInt32(data[i + 1]) << 8) | (UInt32(data[i + 2]) << 16) | (UInt32(data[i + 3]) << 24)
    }
}
