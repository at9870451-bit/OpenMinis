import XCTest
import Combine
import Foundation
import AVFoundation
@testable import Amore134Components

@MainActor
final class Amore136VoiceTests: XCTestCase {
    private var calls: [VoiceSessionManager] = []
    // Retain UI-facing Combine callbacks until teardown, then cancel on MainActor.
    private var callbacks: Set<AnyCancellable> = []
    // Async XCTest cleanup hops explicitly to MainActor instead of overriding
    // the nonisolated synchronous tearDown() with actor-isolated state access.
    nonisolated override func tearDown() async throws {
        await cleanUpCalls()
        try await super.tearDown()
    }
    private func cleanUpCalls() {
        calls.forEach { $0.hangUp() }
        callbacks.removeAll()
        calls.removeAll()
    }
    private func fixture(authorize: @escaping () async -> Bool = { true },
                         transcribe: @escaping (Data) async throws -> String = { _ in "Hello from speech" },
                         synthesize: @escaping (String) async throws -> Data = { _ in Data([1, 2]) }) -> (VoiceSessionManager, FakeCallAudio, FakeCallConversation) {
        let audio = FakeCallAudio(), agent = FakeCallConversation()
        let manager = VoiceSessionManager(audio: audio, services: .init(authorize: authorize, transcribe: transcribe, synthesize: synthesize))
        calls.append(manager); return (manager, audio, agent)
    }
    private func settle(_ count: Int = 16) async { for _ in 0..<count { await Task.yield() }; try? await Task.sleep(for: .milliseconds(50)) }
    private var wav: Data { Data(repeating: 0, count: 16000) }

    func testPermissionDeniedNeverStartsMicrophoneOrAgent() async {
        let (manager,audio,agent) = fixture(authorize: { false })
        await manager.connect(to: agent)
        XCTAssertEqual(manager.state,.failed); XCTAssertEqual(audio.starts,0)
        XCTAssertTrue(agent.sent.isEmpty); XCTAssertNil(agent.voiceCallDelegate)
    }
    func testConnectUsesSameConversationAndDoesNotSendOnEntry() async {
        let (manager,audio,agent) = fixture(); await manager.connect(to: agent)
        XCTAssertEqual(manager.state,.listening); XCTAssertEqual(audio.starts,1)
        XCTAssertTrue(agent.voiceCallDelegate === manager); XCTAssertTrue(agent.sent.isEmpty)
    }
    func testRecognizedUtteranceInvokesTheExistingAgentExactlyOnce() async {
        let (manager,_,agent)=fixture(); await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        XCTAssertEqual(agent.sent,["Hello from speech"]); XCTAssertEqual(manager.state,.thinking)
        XCTAssertEqual(agent.context,["prior user","prior assistant","Hello from speech"])
    }
    func testAgentSpeechUsesInjectedTTSAndSameDuplexPlayer() async {
        var spoken:[String]=[]
        let (manager,audio,agent)=fixture(synthesize:{ spoken.append($0); return Data([8]) })
        await manager.connect(to: agent); manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        agent.voiceCallDelegate?.enqueueCallSpeech("A real reply."); await settle()
        XCTAssertEqual(spoken,["A real reply."]); XCTAssertEqual(audio.played,[Data([8])])
        XCTAssertEqual(manager.state,.speaking)
        audio.completePlayback(); agent.complete(); await settle()
        XCTAssertEqual(manager.state,.listening)
    }
    func testBargeInStopsAudioImmediatelyBeforeNextASR() async {
        let (manager,audio,agent)=fixture(); await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        manager.enqueueCallSpeech("The answer"); await settle()
        let stops=audio.playbackStops
        manager.callAudioSpeechBegan()
        XCTAssertGreaterThan(audio.playbackStops,stops); XCTAssertEqual(agent.cancels,1)
        XCTAssertEqual(manager.state,.listening)
        manager.callAudioSegment(wav); await settle()
        XCTAssertEqual(agent.sent.count,2)
    }
    func testLateASRAfterHangupCannotSend() async {
        let gate=CallTestGate<String>()
        let (manager,audio,agent)=fixture(transcribe:{ _ in await gate.wait() })
        await manager.connect(to: agent); manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        manager.hangUp(); gate.finish("late speech"); await settle()
        XCTAssertEqual(manager.state,.ended); XCTAssertTrue(agent.sent.isEmpty)
        XCTAssertNil(agent.voiceCallDelegate); XCTAssertGreaterThan(audio.stops,0)
    }
    func testLateTTSAfterInterruptCannotPlay() async {
        let gate=CallTestGate<Data>()
        let (manager,audio,agent)=fixture(synthesize:{ _ in await gate.wait() })
        await manager.connect(to: agent); manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        manager.enqueueCallSpeech("stale reply"); await settle(); manager.callAudioSpeechBegan()
        gate.finish(Data([8,9])); await settle()
        XCTAssertTrue(audio.played.isEmpty); XCTAssertEqual(agent.cancels,1)
    }
    func testMuteGatesNewAudioAndPreservesConversation() async {
        let (manager,audio,agent)=fixture(); await manager.connect(to: agent)
        manager.toggleMute(); XCTAssertTrue(audio.muted); XCTAssertTrue(manager.muted)
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        XCTAssertTrue(agent.sent.isEmpty)
        manager.toggleMute(); manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        XCTAssertEqual(agent.sent.count,1)
    }
    func testSpeakerRouteAndHangupUseOwnedAudioTransport() async {
        let (manager,audio,agent)=fixture(); await manager.connect(to: agent)
        manager.toggleSpeaker(); XCTAssertEqual(audio.speaker,false)
        manager.hangUp(); XCTAssertEqual(manager.state,.ended); XCTAssertNil(agent.voiceCallDelegate)
        XCTAssertGreaterThan(audio.stops,0)
    }
    func testInterruptedAudioRequiresExplicitResume() async {
        let (manager,audio,agent)=fixture(); await manager.connect(to: agent)
        manager.callAudioInterrupted(); XCTAssertEqual(manager.state,.interrupted)
        XCTAssertFalse(manager.canControlAudio)
        manager.callAudioSegment(wav); await settle(); XCTAssertTrue(agent.sent.isEmpty)
        await manager.resume(); XCTAssertEqual(audio.starts,2); XCTAssertEqual(manager.state,.listening)
    }
    func testAnotherConversationCannotAcquireTheMicrophoneLease() async {
        let (one,_,agent)=fixture(); await one.connect(to: agent)
        let (two,audio,other)=fixture(); await two.connect(to: other)
        XCTAssertEqual(two.state,.failed); XCTAssertEqual(audio.starts,0); XCTAssertTrue(other.sent.isEmpty)
        XCTAssertTrue(agent.voiceCallDelegate === one)
    }
    func testLateAuthorizationAfterHangupCannotStartTransport() async {
        let gate = CallTestGate<Bool>()
        let (manager, audio, agent) = fixture(authorize: { await gate.wait() })
        let connect = Task { @MainActor in await manager.connect(to: agent) }
        await settle()
        XCTAssertEqual(manager.state, .requestingPermission)
        manager.hangUp(); gate.finish(true)
        await connect.value
        XCTAssertEqual(manager.state, .ended)
        XCTAssertEqual(audio.starts, 0); XCTAssertTrue(agent.sent.isEmpty)
        XCTAssertNil(agent.voiceCallDelegate)
    }
    func testLatePlaybackAndUICallbacksAfterHangupCannotReviveSession() async {
        let (manager, audio, agent) = fixture()
        var states: [VoiceCallState] = []
        manager.$state.sink { value in
            XCTAssertTrue(Thread.isMainThread)
            states.append(value)
        }.store(in: &callbacks)
        await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        manager.enqueueCallSpeech("A reply"); await settle()
        // Capture the closure before stop() clears it, simulating an already
        // queued real audio callback. Never replace the manager's epoch guards.
        let lateCompletion = audio.pendingPlaybackCompletion
        XCTAssertNotNil(lateCompletion)
        manager.hangUp()
        lateCompletion?(); agent.complete(); await settle()
        XCTAssertEqual(manager.state, .ended); XCTAssertEqual(states.last, .ended)
        XCTAssertNil(agent.voiceCallDelegate)
        XCTAssertEqual(audio.played.count, 1)
        XCTAssertEqual(agent.processingCancellations, 1)
        XCTAssertEqual(agent.changeCancellations, 1)
        callbacks.removeAll()
        let count = states.count
        manager.hangUp(); await settle()
        XCTAssertEqual(states.count, count)
    }
    func testPartialSpeechDoesNotSendBeforeFinalEndpoint() async {
        var count = 0
        let (manager,_,agent) = fixture(transcribe: { _ in count += 1; return count == 1 ? "first part" : "second part" })
        await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioPartialSegment(wav); await settle()
        XCTAssertTrue(agent.sent.isEmpty)
        manager.callAudioSegment(wav); await settle()
        XCTAssertEqual(agent.sent, ["first part second part"])
    }
    func testFailedASRPiecePausesInsteadOfSubmittingPartialTurn() async {
        var count = 0
        let (manager,audio,agent) = fixture(transcribe: { _ in
            count += 1
            if count == 1 { return "incomplete instruction" }
            throw NSError(domain: "asr-test", code: 1)
        })
        await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioPartialSegment(wav); await settle()
        manager.callAudioSegment(wav); await settle()
        XCTAssertTrue(agent.sent.isEmpty)
        XCTAssertEqual(manager.state, .interrupted)
        XCTAssertGreaterThan(audio.stops, 0)
        XCTAssertNotNil(manager.errorMessage)
    }
    func testContinuousSecondTurnKeepsTheExistingContext() async {
        let (manager,audio,agent) = fixture()
        await manager.connect(to: agent)
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        manager.enqueueCallSpeech("first answer"); await settle()
        audio.completePlayback(); agent.complete(); await settle()
        manager.callAudioSpeechBegan(); manager.callAudioSegment(wav); await settle()
        XCTAssertEqual(agent.sent.count, 2)
        XCTAssertEqual(agent.context, ["prior user", "prior assistant", "Hello from speech", "Hello from speech"])
    }

    func testStateMachineRejectsStaleRecognitionAcrossMuteHangup() {
        var state=VoiceStateMachine();let token=state.start();state.set(.listening)
        XCTAssertTrue(state.accepts(token));state.mute(true);XCTAssertFalse(state.accepts(token))
        state.mute(false);let newer=state.speechBegan();state.finish();XCTAssertFalse(state.accepts(newer))
        state.set(.speaking);XCTAssertEqual(state.state,.ended)
    }
}

// Pure tests against the byte-identical production splitter, not a Swift port.
final class Amore136VoiceWAVTests: XCTestCase {
    private func pcm(byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: ($0 * 31) ^ ($0 >> 8) ^ ($0 >> 16)) })
    }
    private func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int, in data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.replaceSubrange(offset..<(offset + $0.count), with: $0) }
    }
    private func read32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
    private func makeWAV(_ payload: Data) -> Data {
        var header = Data(repeating: 0, count: 44)
        header.replaceSubrange(0..<4, with: Data("RIFF".utf8))
        header.replaceSubrange(8..<12, with: Data("WAVE".utf8))
        header.replaceSubrange(12..<16, with: Data("fmt ".utf8))
        writeLE(UInt32(36 + payload.count), at: 4, in: &header)
        writeLE(UInt32(16), at: 16, in: &header)
        writeLE(UInt16(1), at: 20, in: &header)
        writeLE(UInt16(1), at: 22, in: &header)
        writeLE(UInt32(16_000), at: 24, in: &header)
        writeLE(UInt32(32_000), at: 28, in: &header)
        writeLE(UInt16(2), at: 32, in: &header)
        writeLE(UInt16(16), at: 34, in: &header)
        header.replaceSubrange(36..<40, with: Data("data".utf8))
        writeLE(UInt32(payload.count), at: 40, in: &header)
        header.append(payload)
        return header
    }
    private func assertChunk(_ chunk: Data, payloadBytes: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(chunk.count, 44 + payloadBytes, file: file, line: line)
        guard chunk.count >= 44 else { return }
        XCTAssertEqual(read32(chunk, at: 4), UInt32(36 + payloadBytes), file: file, line: line)
        XCTAssertEqual(read32(chunk, at: 40), UInt32(payloadBytes), file: file, line: line)
        XCTAssertEqual(String(data: chunk.prefix(4), encoding: .ascii), "RIFF", file: file, line: line)
        XCTAssertEqual(String(data: chunk[8..<12], encoding: .ascii), "WAVE", file: file, line: line)
        XCTAssertEqual(String(data: chunk[36..<40], encoding: .ascii), "data", file: file, line: line)
    }
    func testRealAVFoundationDecoderProduces48kMonoPCM() throws {
        // Synthetic 16k PCM, no mic permission or speech service is involved.
        let wav = makeWAV(Data(repeating: 32, count: 16_000))
        let decoded = try VoiceCallAudioDecoder.decode(wav).pcm
        XCTAssertEqual(decoded.format.sampleRate, 48_000)
        XCTAssertEqual(decoded.format.channelCount, 1)
        XCTAssertEqual(decoded.format.commonFormat, .pcmFormatFloat32)
        XCTAssertGreaterThan(decoded.frameLength, 23_000)
        XCTAssertLessThan(decoded.frameLength, 25_000)
        XCTAssertNotNil(decoded.floatChannelData)
    }
    func testRealDecoderRejectsInvalidData() {
        XCTAssertThrowsError(try VoiceCallAudioDecoder.decode(Data()))
        XCTAssertThrowsError(try VoiceCallAudioDecoder.decode(Data("not an audio file".utf8)))
    }
    func testWAV48SecondsSplitsInto24SecondChunksWithoutChangingPCM() {
        let payload = pcm(byteCount: 48 * 32_000)
        let chunks = VoiceCallWAV.split(makeWAV(payload))
        XCTAssertEqual(chunks.count, 2)
        for chunk in chunks { assertChunk(chunk, payloadBytes: 24 * 32_000) }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append(contentsOf: $1.dropFirst(44)) }, payload)
    }
    func testWAVCustomChunkLengthKeepsFinalPartialChunkAndHeaderFormat() {
        let payload = pcm(byteCount: 25 * 32_000), wav = makeWAV(payload)
        let chunks = VoiceCallWAV.split(wav, maxSeconds: 12)
        XCTAssertEqual(chunks.count, 3)
        for (chunk, seconds) in zip(chunks, [12, 12, 1]) {
            assertChunk(chunk, payloadBytes: seconds * 32_000)
            XCTAssertEqual(Data(chunk[8..<40]), Data(wav[8..<40]))
        }
        XCTAssertEqual(chunks.reduce(into: Data()) { $0.append(contentsOf: $1.dropFirst(44)) }, payload)
    }
    func testWAVBadHeadersAndUnsupportedFormatsAreRejected() {
        let good = makeWAV(pcm(byteCount: 32))
        for offset in [0, 8, 36] {
            var bad = good; bad[offset] = 0
            XCTAssertTrue(VoiceCallWAV.split(bad).isEmpty, "Bad header marker at \(offset)")
        }
        var nonPCM = good; writeLE(UInt16(3), at: 20, in: &nonPCM)
        var stereo = good; writeLE(UInt16(2), at: 22, in: &stereo)
        var wrongRate = good; writeLE(UInt32(48_000), at: 24, in: &wrongRate)
        var wrongBits = good; writeLE(UInt16(8), at: 34, in: &wrongBits)
        for bad in [Data(), Data(good.prefix(43)), Data(good.prefix(44)), nonPCM, stereo, wrongRate, wrongBits] {
            XCTAssertTrue(VoiceCallWAV.split(bad).isEmpty)
        }
    }
    func testWAVInvalidPayloadLengthsAndOversizeInputAreRejected() {
        let good = makeWAV(pcm(byteCount: 32))
        for length in [UInt32(0), UInt32(31), UInt32(34), UInt32.max] {
            var bad = good; writeLE(length, at: 40, in: &bad)
            XCTAssertTrue(VoiceCallWAV.split(bad).isEmpty, "Bad declared payload length: \(length)")
        }
        XCTAssertTrue(VoiceCallWAV.split(makeWAV(Data(repeating: 0, count: 181 * 32_000))).isEmpty)
    }
    func testWAVChunkSecondsClampToOneThroughThirtyWithoutLosingBytes() {
        let payload = pcm(byteCount: 31 * 32_000), wav = makeWAV(payload)
        for (requested, effective) in [(0, 1), (-5, 1), (31, 30), (Int.max, 30)] {
            let chunks = VoiceCallWAV.split(wav, maxSeconds: requested)
            XCTAssertEqual(chunks.count, effective == 1 ? 31 : 2)
            for (index, chunk) in chunks.enumerated() {
                assertChunk(chunk, payloadBytes: min(effective * 32_000, payload.count - index * effective * 32_000))
            }
            XCTAssertEqual(chunks.reduce(into: Data()) { $0.append(contentsOf: $1.dropFirst(44)) }, payload)
        }
    }
}

@MainActor
private final class FakeCallAudio: VoiceCallAudioTransport {
    weak var delegate: VoiceCallAudioIODelegate?
    var starts=0,stops=0,playbackStops=0
    var muted=false,speaker=true
    var played:[Data]=[]
    private var completion:(@MainActor ()->Void)?
    var pendingPlaybackCompletion: (@MainActor () -> Void)? { completion }
    func start() async throws { starts += 1 }
    func setMuted(_ value:Bool){muted=value}
    func useSpeaker(_ enabled:Bool){speaker=enabled}
    func stopPlayback(){playbackStops += 1;completion=nil}
    func play(_ data:Data,completed:@escaping @MainActor ()->Void) async throws{played.append(data);completion=completed}
    func completePlayback(){let done=completion;completion=nil;done?()}
    func stop(){stops += 1;completion=nil}
}
@MainActor
private final class FakeCallConversation: VoiceCallConversation {
    weak var voiceCallDelegate:(any VoiceCallSpeechDelegate)?
    @Published var running=false
    var callIsProcessing:Bool{running}
    var callCanStart=true
    var callError:String?
    var callReply=""
    var processingCancellations = 0, changeCancellations = 0
    var callProcessing: AnyPublisher<Bool, Never> {
        $running.handleEvents(receiveCancel: { [weak self] in
            self?.processingCancellations += 1
        }).eraseToAnyPublisher()
    }
    var callChanges: AnyPublisher<Void, Never> {
        $running.map { _ in () }.handleEvents(receiveCancel: { [weak self] in
            self?.changeCancellations += 1
        }).eraseToAnyPublisher()
    }
    var sent:[String]=[],context=["prior user","prior assistant"]
    var cancels=0
    func submitCallTurn(_ text:String)->Bool{guard !running else{return false};sent.append(text);context.append(text);running=true;return true}
    func cancelCallTurn(){cancels += 1;running=false}
    func complete(){running=false}
}
@MainActor
private final class CallTestGate<Value> {
    private var continuation:CheckedContinuation<Value,Never>?
    private var buffered:Value?
    func wait() async->Value{
        if let value=buffered {buffered=nil;return value}
        return await withCheckedContinuation{continuation=$0}
    }
    func finish(_ value:Value){if let c=continuation{continuation=nil;c.resume(returning:value)}else{buffered=value}}
}
