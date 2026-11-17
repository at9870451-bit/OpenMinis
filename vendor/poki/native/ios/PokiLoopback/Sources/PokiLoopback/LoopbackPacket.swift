import Foundation

public enum LoopbackPacket {
    /// Reflects only TCP between this tunnel's interface and its local developer endpoint.
    public static func reflect(_ packet: Data) -> Data? {
        var bytes = [UInt8](packet)
        guard bytes.count >= 40, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0f) * 4
        let totalLength = Int(bytes[2]) * 256 + Int(bytes[3])
        let fragments = UInt16(bytes[6]) * 256 + UInt16(bytes[7])
        guard headerLength >= 20, totalLength == bytes.count,
              headerLength + 20 <= totalLength, fragments & 0x3fff == 0,
              bytes[9] == 6,
              bytes[12..<16].elementsEqual([10, 7, 0, 2]),
              bytes[16..<20].elementsEqual([10, 7, 0, 1]) else { return nil }
        let tcpHeaderLength = Int(bytes[headerLength + 12] >> 4) * 4
        guard tcpHeaderLength >= 20, headerLength + tcpHeaderLength <= totalLength else { return nil }
        for i in 0..<4 { bytes.swapAt(12 + i, 16 + i) }
        // Swapping the addresses leaves both one's-complement checksum sums unchanged.
        return Data(bytes)
    }
}
