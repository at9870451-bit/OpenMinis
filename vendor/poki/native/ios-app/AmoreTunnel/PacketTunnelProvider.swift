import NetworkExtension
import PokiLoopback

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let packets = DispatchQueue(label: "app.amore.loopback.packets")
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        setTunnelNetworkSettings(LoopbackNetworkSettings.make()) { error in
            self.packets.async {
                if error == nil { self.running = true; self.readPackets() }
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        // The app dials the tunnel again after a failure, but not after the owner turned it off in
        // Settings or another VPN took the single packet tunnel: it hears that from here.
        if TunnelStop.isOnPurpose(reason), let id = Bundle.main.bundleIdentifier {
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName((id + TunnelStopSignal.suffix) as CFString), nil, nil, true)
        }
        packets.async { self.running = false; completionHandler() }
    }

    private func readPackets() {
        guard running else { return }
        packetFlow.readPackets { packets, protocols in
            self.packets.async {
                guard self.running else { return }
                var reflected: [Data] = []
                for (packet, family) in zip(packets, protocols) where family.int32Value == AF_INET {
                    if let packet = LoopbackPacket.reflect(packet) { reflected.append(packet) }
                }
                if !reflected.isEmpty {
                    guard self.packetFlow.writePackets(reflected, withProtocols: Array(repeating: NSNumber(value: AF_INET), count: reflected.count)) else {
                        self.running = false
                        self.cancelTunnelWithError(NSError(domain: "AmoreLoopback", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The local connection stopped accepting packets. Reconnect in Amore Settings > Connection."]))
                        return
                    }
                }
                self.readPackets()
            }
        }
    }
}
