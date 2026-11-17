import AVFoundation
import Foundation
import WebRTC

/// What VoiceModel talks through: a VoiceLink in the app, a recorded conversation in tests.
protocol VoiceConnection: AnyObject, Sendable {
    func connect(secret: String, microphone: Bool, direct: Bool) async throws
    @discardableResult func send(_ event: [String: Any]) -> Bool
    func setRemoteVolume(_ value: Double)
    func diagnose(_ write: @escaping @MainActor (String) -> Void)
    func close()
}

/// One WebRTC connection to the OpenAI Realtime API: the microphone as the audio track, the model's
/// voice on the speaker, and the `oai-events` data channel for events. Opened with a short-lived client
/// secret; it never sees an API key. Callbacks arrive on the main actor.
final class VoiceLink: NSObject, VoiceConnection, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    private static let factory: RTCPeerConnectionFactory = {
        // Voice chat: echo cancellation on, so Poki's own voice from the speaker doesn't interrupt it.
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.category = AVAudioSession.Category.playAndRecord.rawValue
        audio.mode = AVAudioSession.Mode.voiceChat.rawValue
        audio.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(audio)
        return RTCPeerConnectionFactory()
    }()
    /// The second try: the same, but WebRTC leaves VPN interfaces out. A loopback VPN or a proxy app
    /// that drops UDP otherwise takes the voice packets, and the connection never opens.
    private static let directFactory: RTCPeerConnectionFactory = {
        _ = factory // the audio session configuration above, set once
        let direct = RTCPeerConnectionFactory()
        let options = RTCPeerConnectionFactoryOptions()
        options.ignoreVPNNetworkAdapter = true
        options.ignoreLoopbackNetworkAdapter = true
        direct.setOptions(options)
        return direct
    }()
    #if DEBUG
    /// Test runs: WebRTC's own audio device would set up a voice-chat audio session, and iOS would ask
    /// for the microphone. This one never touches audio; the model's voice is received and dropped.
    private static let silentFactory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: SilentAudioDevice())
    #endif

    private let onEvent: @MainActor ([String: Any]) -> Void
    private let onClosed: @MainActor (String) -> Void
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    /// WebRTC calls the delegate methods on its own threads and the app calls in from the main actor,
    /// so these three are only touched under `lock`.
    private let lock = NSLock()
    private var remoteAudio: RTCAudioTrack?
    private var volume = 1.0
    private var closing = false
    /// Until the connection is open, a failure is connect's to report (it may try again), not a loss.
    private var opened = false

    init(onEvent: @escaping @MainActor ([String: Any]) -> Void, onClosed: @escaping @MainActor (String) -> Void) {
        self.onEvent = onEvent
        self.onClosed = onClosed
    }

    /// `microphone: false` (test runs) sends no audio track and needs no microphone permission; the
    /// model's voice still comes back.
    /// `direct: true` keeps the connection off VPN interfaces (the retry after a try that never opened).
    func connect(secret: String, microphone: Bool = true, direct: Bool = false) async throws {
        #if DEBUG
        let factory = !microphone ? Self.silentFactory : direct ? Self.directFactory : Self.factory
        #else
        let factory = direct ? Self.directFactory : Self.factory
        #endif
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        // A public address of our own as well, so the path opens behind NAT that host addresses alone
        // do not get through.
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302", "stun:stun.cloudflare.com:3478"])]
        config.continualGatheringPolicy = .gatherContinually
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { throw VoiceError.noWebRTC }
        self.peer = peer
        if microphone {
            // Poki's background keep-alive may have left the shared session in .playback, which cannot
            // record; set voice chat explicitly before the microphone track starts.
            let session = RTCAudioSession.sharedInstance()
            session.lockForConfiguration()
            defer { session.unlockForConfiguration() }
            do {
                try session.setConfiguration(RTCAudioSessionConfiguration.webRTC(), active: true)
            } catch {
                // After an earlier conversation (or the keep-alive) the shared session can refuse
                // WebRTC's preferred sample rate, buffer or channel counts (OSStatus -50). Voice chat
                // needs none of them: set the category and mode, activate, and tell WebRTC.
                let av = AVAudioSession.sharedInstance()
                try? av.setActive(false)
                try av.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try av.setActive(true)
                session.audioSessionDidActivate(av)
            }
            let mic = factory.audioTrack(with: factory.audioSource(with: constraints), trackId: "poki-mic")
            peer.add(mic, streamIds: ["poki-voice"])
        } else {
            let receiveOnly = RTCRtpTransceiverInit()
            receiveOnly.direction = .recvOnly
            peer.addTransceiver(of: .audio, init: receiveOnly)
        }
        let channel = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
        channel?.delegate = self
        self.channel = channel

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { done in
            peer.offer(for: constraints) { sdp, error in
                if let sdp { done.resume(returning: sdp) } else { done.resume(throwing: error ?? VoiceError.noOffer) }
            }
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/calls")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(offer.sdp.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let answer = String(decoding: data, as: UTF8.self)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VoiceError.realtime(http.statusCode, String(answer.prefix(300)))
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer)) { error in if let error { done.resume(throwing: error) } else { done.resume() } }
        }
        let deadline = Date().addingTimeInterval(12)
        while channel?.readyState != .open {
            if Date() > deadline || peer.connectionState == .failed { throw VoiceError.noPath(Self.describe(peer.iceConnectionState)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        lock.withLock { opened = true }
    }

    private static func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        default: "unknown"
        }
    }

    /// The shared audio session: category, mode, routes, and whether WebRTC counts it active.
    static func audioSession() -> String {
        let av = AVAudioSession.sharedInstance()
        return "audio session \(av.category.rawValue) \(av.mode.rawValue), input available \(av.isInputAvailable), input channels \(av.inputNumberOfChannels), input \(av.currentRoute.inputs.map { "\($0.portType.rawValue) \($0.portName)" }.joined(separator: ", ")), output \(av.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ", ")), webrtc active \(RTCAudioSession.sharedInstance().isActive), record permission \(AVAudioApplication.shared.recordPermission == .granted)"
    }

    /// One log line about the audio session now, and one ~3 s later about what the microphone sent:
    /// media-source totalSamplesDuration stays 0 when nothing is captured, whatever the room sounds like.
    func diagnose(_ write: @escaping @MainActor (String) -> Void) {
        let now = Self.audioSession()
        Task { @MainActor in write(now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let peer = self?.peer else { return }
            peer.statistics { report in
                var parts: [String] = []
                for stat in report.statistics.values where (stat.values["kind"] as? String) == "audio" {
                    let value = { (key: String) in stat.values[key].map { "\($0)" } ?? "none" }
                    switch stat.type {
                    case "media-source":
                        parts.append("captured \(value("totalSamplesDuration")) s, level \(value("audioLevel"))")
                    case "outbound-rtp":
                        parts.append("sent \(value("bytesSent")) bytes in \(value("packetsSent")) packets")
                    default: break
                    }
                }
                let line = "microphone after 3 s: " + (parts.isEmpty ? "no audio stats" : parts.joined(separator: "; "))
                Task { @MainActor in write(line) }
            }
        }
    }

    @discardableResult
    func send(_ event: [String: Any]) -> Bool {
        guard let channel, channel.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: event) else { return false }
        return channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// 0 mutes Poki's voice (silent test runs); 1 is normal.
    func setRemoteVolume(_ value: Double) {
        lock.withLock {
            volume = value
            remoteAudio?.source.volume = value
            remoteAudio?.isEnabled = value > 0
        }
    }

    func close() {
        lock.withLock { closing = true }
        channel?.close()
        peer?.close()
        channel = nil
        peer = nil
        // Hand the audio session back through WebRTC, so its count of activations matches and the
        // next conversation can set voice chat again.
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        if session.isActive { try? session.setActive(false) }
        session.unlockForConfiguration()
    }

    private func lost(_ reason: String) {
        let first = lock.withLock { () -> Bool in
            guard !closing, opened else { return false }
            closing = true
            return true
        }
        guard first else { return }
        let onClosed = onClosed
        Task { @MainActor in onClosed(reason) }
    }

    // MARK: RTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        if dataChannel.readyState == .closed { lost("the data channel closed") }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let event = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
        let onEvent = onEvent
        Task { @MainActor in onEvent(event) }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        switch newState {
        case .failed: lost("the network path failed")
        case .disconnected:
            // ICE often recovers from a short gap by itself; give it a few seconds before giving up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak peerConnection] in
                if let peerConnection, peerConnection.connectionState != .connected { self?.lost("the network dropped") }
            }
        default: break
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCAudioTrack else { return }
        lock.withLock {
            remoteAudio = track
            track.source.volume = volume
            track.isEnabled = volume > 0
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

#if DEBUG
/// An audio device with no microphone and no speaker, for silent test runs (development builds only).
private final class SilentAudioDevice: NSObject, RTCAudioDevice {
    let deviceInputSampleRate = 48000.0
    let inputIOBufferDuration: TimeInterval = 0.01
    let inputNumberOfChannels = 1
    let inputLatency: TimeInterval = 0
    let deviceOutputSampleRate = 48000.0
    let outputIOBufferDuration: TimeInterval = 0.01
    let outputNumberOfChannels = 1
    let outputLatency: TimeInterval = 0
    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool { isInitialized = true; return true }
    func terminateDevice() -> Bool { isInitialized = false; isPlaying = false; isRecording = false; return true }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func startPlayout() -> Bool { isPlaying = true; return true }
    func stopPlayout() -> Bool { isPlaying = false; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startRecording() -> Bool { isRecording = true; return true }
    func stopRecording() -> Bool { isRecording = false; return true }
}
#endif
