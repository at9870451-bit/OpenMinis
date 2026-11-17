import Foundation
import Observation
import PokiCore
import UIKit

/// The voice bridge on the person's Mac (`bin/voice-bridge.mjs`): it hands out short-lived OpenAI
/// Realtime credentials, so the phone never holds an API key, and runs the voice tools that move the
/// phone through the Mac's Poki MCP. Entered once, like the relay address.
struct VoiceBridge: Equatable {
    /// http://<Mac>:47830/voice/<secret>
    let base: URL

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        let parts = url.path().split(separator: "/")
        guard parts.count == 2, parts[0] == "voice", parts[1].count >= 16 else { return nil }
        base = url
    }

    var display: String { "\(base.host() ?? "")\(base.port.map { ":\($0)" } ?? "")" }

    static var saved: VoiceBridge? {
        get { UserDefaults.standard.string(forKey: "voiceBridge").flatMap(VoiceBridge.init) }
        set { UserDefaults.standard.set(newValue?.base.absoluteString, forKey: "voiceBridge") }
    }

    struct Token: Decodable { let value: String; let model: String; let local_tools: [String] }
    struct ToolResult: Decodable {
        let state: String
        var output = ""
        var replayed = false
        /// state "check" (tap_text before the phone cleared it): the app in front and the element it would tap.
        var app: App?
        var target: Target?
        struct App: Decodable { let bundle_id: String?; let name: String? }
        struct Target: Decodable { let text: String; let says: String }

        enum CodingKeys: CodingKey { case state, output, replayed, app, target }
        init(state: String, output: String) { self.state = state; self.output = output }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(String.self, forKey: .state)
            output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
            replayed = try c.decodeIfPresent(Bool.self, forKey: .replayed) ?? false
            app = try c.decodeIfPresent(App.self, forKey: .app)
            target = try c.decodeIfPresent(Target.self, forKey: .target)
        }
    }

    /// The phone's language goes along: the one the session speaks before the person has spoken.
    func token() async throws -> Token {
        let url = base.appending(path: "token").appending(queryItems: [URLQueryItem(name: "language", value: Locale.preferredLanguages.first ?? "en")])
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.check(response, data)
        return try JSONDecoder().decode(Token.self, from: data)
    }

    /// `checked`: for tap_text, the app and element text the phone cleared; without it tap_text only answers "check".
    func run(callID: String, name: String, arguments: String, checked: [String: String]? = nil) async throws -> ToolResult {
        var request = URLRequest(url: base.appending(path: "tool"), timeoutInterval: 75)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) ?? [String: Any]()
        var body: [String: Any] = ["call_id": callID, "name": name, "arguments": args]
        if let checked { body["checked"] = checked }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try JSONDecoder().decode(ToolResult.self, from: data)
    }

    #if DEBUG
    /// Test runs only: recorded utterance n (24 kHz mono PCM16), served by a bridge started with --test-dir.
    func utterance(_ n: Int) async throws -> Data {
        var parts = URLComponents(url: base.appending(path: "utterance"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "n", value: String(format: "%02d", n))]
        let (data, response) = try await URLSession.shared.data(from: parts.url!)
        try Self.check(response, data)
        return data
    }

    func report(_ turn: [String: Any]) async throws {
        var request = URLRequest(url: base.appending(path: "report"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: turn)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
    }
    #endif

    private static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw VoiceError.bridge(http.statusCode, reason)
    }
}

enum VoiceError: LocalizedError {
    /// The bridge's status and the reason it gave, if any.
    case bridge(Int, String?)
    case realtime(Int, String)
    case noBridge
    case timeout(String)
    /// The connection was set up but no network path to OpenAI opened (the ICE state at the end).
    case noPath(String)
    /// WebRTC on this iPhone could not make a connection, or could not offer one.
    case noWebRTC, noOffer

    /// In English, for the log and for the model when a step's outcome is unknown.
    var errorDescription: String? {
        switch self {
        case .bridge(404, _): "The voice bridge doesn't know this address. Copy it again from the Mac."
        case .bridge(let code, let reason): "The voice bridge answered \(code): \(reason ?? "no reason given")"
        case .realtime(let code, let reason): "OpenAI answered \(code): \(reason)"
        case .noBridge: "Set up Poki's model first (an OpenAI key talks fastest), or enter a voice bridge address from your Mac."
        case .timeout(let what): "\(what) took too long."
        case .noPath: "The voice connection could not reach OpenAI over this network. Check Wi-Fi or cellular, or a VPN or proxy app that blocks calls, then try again."
        case .noWebRTC: "WebRTC could not start"
        case .noOffer: "WebRTC made no connection offer."
        }
    }

    /// For the talk bar, in Poki's language. A reason the bridge or OpenAI sent stays in their words.
    var words: String {
        switch self {
        case .bridge(404, _): AppLocalization.text(LocalizedStringResource("The voice bridge doesn't know this address. Copy it again from the Mac."))
        case .bridge(let code, let reason):
            AppLocalization.text(LocalizedStringResource("The voice bridge answered \(code): \(reason ?? AppLocalization.text(LocalizedStringResource("no reason given")))"))
        case .realtime(let code, let reason): AppLocalization.text(LocalizedStringResource("OpenAI answered \(code): \(reason)"))
        case .noBridge: AppLocalization.text(LocalizedStringResource("Set up Poki's model first (an OpenAI key talks fastest), or enter a voice bridge address from your Mac."))
        case .timeout(let what): AppLocalization.text(LocalizedStringResource("\(what) took too long."))
        case .noPath: AppLocalization.text(LocalizedStringResource("The voice connection could not reach OpenAI over this network. Check Wi-Fi or cellular, or a VPN or proxy app that blocks calls, then try again."))
        case .noWebRTC: AppLocalization.text(LocalizedStringResource("WebRTC could not start"))
        case .noOffer: AppLocalization.text(LocalizedStringResource("WebRTC made no connection offer."))
        }
    }

    /// Why a talk could not start or listen, for the talk bar: Poki's own reasons and the network
    /// failures it can name in Poki's language, anything else as iOS words it.
    static func reason(for error: Error) -> String {
        if let error = error as? VoiceError { return error.words }
        switch (error as? URLError)?.code {
        case .timedOut?:
            return AppLocalization.text(LocalizedStringResource("The voice connection took too long. Check the network, then try again."))
        case .notConnectedToInternet?, .networkConnectionLost?, .cannotConnectToHost?, .cannotFindHost?, .dnsLookupFailed?,
             .internationalRoamingOff?, .dataNotAllowed?:
            return AppLocalization.text(LocalizedStringResource("Poki could not reach the voice service. Check the network, then try again."))
        default:
            return error.localizedDescription
        }
    }
}

/// One function call the model asked for. Keyed by the model's call_id, it runs at most once, whatever
/// happens to the connection: a call outlives the session that asked for it, and a new session is told
/// how it ended instead of asking for it again.
struct VoiceCall: Identifiable, Equatable {
    enum State: Equatable { case running, done, failed }
    let id: String
    let name: String
    let arguments: String
    /// The connection that asked for it. Only that connection can take a function_call_output for it.
    let session: Int
    var state = State.running
    var output = ""
    /// The model has the result (as a function_call_output, or in a reconnect note).
    var delivered = false
    let started = Date()
    var finished: Date?
}

/// When each step of one turn happened. `said` is the end of the person's speech (or when recorded
/// speech was sent); the rest are measured from it.
struct TurnClock {
    var said: Date?
    var heard: Date?
    var call: Date?
    var toolDone: Date?
    var delivered: Date?
    var spoken: Date?
    var callNames: [String] = []
    var reply = ""
    /// Tokens the turn's responses used, from `response.done` (text_in, audio_in, text_cached, audio_cached, text_out, audio_out).
    var tokens: [String: Int] = [:]

    mutating func add(usage: [String: Any]) {
        let input = usage["input_token_details"] as? [String: Any] ?? [:]
        let cached = input["cached_tokens_details"] as? [String: Any] ?? [:]
        let output = usage["output_token_details"] as? [String: Any] ?? [:]
        for (key, source, field) in [("text_in", input, "text_tokens"), ("audio_in", input, "audio_tokens"), ("text_cached", cached, "text_tokens"),
                                     ("audio_cached", cached, "audio_tokens"), ("text_out", output, "text_tokens"), ("audio_out", output, "audio_tokens")] {
            tokens[key, default: 0] += source[field] as? Int ?? 0
        }
    }

    func ms(_ step: KeyPath<TurnClock, Date?>) -> Int? {
        guard let said, let at = self[keyPath: step] else { return nil }
        return Int(at.timeIntervalSince(said) * 1000)
    }
}

struct VoiceLine: Identifiable, Equatable {
    enum Role { case you, poki, tool, note }
    let id = UUID()
    let role: Role
    let text: String
    var at = Date()
}

enum VoicePhase: Equatable {
    case off, connecting, listening, hearing, thinking, speaking
    case lost(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .hearing: "Hearing you"
        case .thinking: "Working"
        case .speaking: "Speaking"
        case .lost(let why): why
        }
    }
}

/// The time VoiceModel reads and waits on.
struct VoiceClock {
    var now: @MainActor () -> Date = { Date() }
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
}

/// Talking to Poki: one Realtime session at a time over WebRTC, the calls it asked for, and what was
/// said. The model hears the microphone and speaks through the speaker; `get_ios_version` is answered
/// here, the other tools by the voice bridge.
@MainActor
@Observable
final class VoiceModel {
    private(set) var bridge = VoiceBridge.saved
    private(set) var phase = VoicePhase.off
    private(set) var lines: [VoiceLine] = [] { didSet { saveTranscript() } }
    /// The live conversation's row in the session list, and the lines that belong to it.
    private var transcript: (id: String, started: Date, from: Int)?
    private(set) var calls: [VoiceCall] = []
    /// The person spoke over Poki's answer, or stopped it: the talk's screens say so for `interruptedShows`.
    private(set) var interrupted = false
    private var interruptedLapse: Task<Void, Never>?
    static let interruptedShows: Duration = .milliseconds(1400)
    #if DEBUG && targetEnvironment(simulator)
    /// A screenshot's state, held whatever the session does next (`-pokiTalkHold`).
    var staged: TalkState?
    #endif
    /// Model audio off: for silent test runs. Speech is still transcribed into `lines`.
    var muted = false { didSet { link?.setRemoteVolume(muted ? 0 : 1) } }
    /// The last measured turn: from the end of speech to the first audio of the answer that carries a tool result.
    private(set) var lastTurnMS: Int?
    /// Timestamps of the current turn, from the end of the person's speech.
    private(set) var clock = TurnClock()

    private var link: VoiceConnection?
    /// session.created arrived on the current link: it takes events now.
    private var ready = false
    private var session = 0
    private var activeResponse: String?
    private var wantsResponse = false
    /// An answer is expected (the person stopped speaking, or response.create went out) and the server
    /// has not started it yet.
    private var awaitingAnswer = false
    /// The event_id of the response.create Poki sent and the server has not started yet: an error naming
    /// it means that answer is not coming.
    private var requestedAnswer: String?
    /// Running while the conversation waits for the person to go on after an answer.
    private var endWindow: Task<Void, Never>?
    /// Running while a conversation is open: ends it when the server owes something and says nothing.
    private var stallWatch: Task<Void, Never>?
    /// The last time the server said anything, a request went out to it, a step's result was handed over, or
    /// Poki went to the background: the wait for the server counts from here.
    private var lastActivity = Date()
    /// When the last live conversation with something said in it ended, and what the person and Poki
    /// said. One opened soon after is told those lines (kept in memory only). A conversation nobody spoke
    /// in leaves both as they were.
    private var lastEnd: Date?
    private var lastLines: [VoiceLine] = []
    private var inBackground = UIApplication.shared.applicationState == .background

    /// How long the conversation waits after an answer for the person to go on before it ends.
    static let followUp: Duration = .seconds(8)
    /// A conversation opened this soon after the last one ended is told the last turns.
    static let carryOver: TimeInterval = 5 * 60
    static let carriedLines = 6
    /// How long the conversation waits for something it is owed (the end of the person's speech, an answer,
    /// the end of the audio) while the server says nothing, before it ends. Shorter in the background, where
    /// the microphone should not stay on for an event that never comes.
    static let stall: Duration = .seconds(60)
    static let backgroundStall: Duration = .seconds(30)
    private var localTools: Set<String> = []
    private let log = AppLog.shared
    /// Poki's approval for a tap (PokiCore's rules and approval card): text, app bundle id, app name.
    private let clearTap: @MainActor (String, String?, String?) async -> TapClearance

    /// How long a tap waits for the owner's OK on the phone: about as long as the card says it lasts.
    static let approvalWait: Double = 115

    /// look and do, run by PokiCore on this phone (the relay's tools): name, JSON arguments → text, failed.
    private let phoneTool: @MainActor (String, String) async -> (String, Bool)

    /// true while a conversation with the microphone is on: Poki's silent keep-alive audio steps aside
    /// (its .playback session cannot record), and the voice-chat session keeps Poki running instead.
    private let holdMicrophone: @MainActor (Bool) -> Void

    /// Opens the connection for one session: events, then why it closed.
    private let connection: @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection
    private let time: VoiceClock

    init(clearTap: @escaping @MainActor (String, String?, String?) async -> TapClearance,
         phoneTool: @escaping @MainActor (String, String) async -> (String, Bool),
         holdMicrophone: @escaping @MainActor (Bool) -> Void = { _ in },
         connection: @escaping @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection = { VoiceLink(onEvent: $0, onClosed: $1) },
         time: VoiceClock = VoiceClock()) {
        self.clearTap = clearTap
        self.phoneTool = phoneTool
        self.holdMicrophone = holdMicrophone
        self.connection = connection
        self.time = time
        // Poki in the background goes on with the talk (the owner, 2026-11-13): you speak to it from the
        // app you went to, and the Live Activity says what it is doing and carries End. It ends there as
        // it does in front, when nobody speaks for `followUp` after an answer. Only the wait for a server
        // that says nothing is shorter there.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.inBackground = true
                guard self.isOn, self.answerDue else { return }
                // What is still due is waited for, but not for ever: the wait for the server now has 30 s.
                self.lastActivity = self.time.now()
                if self.ready { self.watchForStall(session: self.session) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inBackground = false }
        }
    }
    private var holdingMicrophone = false {
        didSet { if holdingMicrophone != oldValue { holdMicrophone(holdingMicrophone) } }
    }

    /// On from the tap: while the key is exchanged and the connection opens (a second or two, longer
    /// while AirPods switch to their microphone) the button and the bar already show it, and a second
    /// tap ends it instead of starting another one.
    var isOn: Bool { link != nil || dictation != nil || isConnecting }
    private var isConnecting: Bool { if case .connecting = phase { return true }; return false }

    /// Voice can start: the OpenAI key on this iPhone (Realtime, no bridge), the Mac's voice bridge, or
    /// dictation into the chat with whichever model Poki uses.
    var canTalk: Bool { VoiceDirect.apiKey != nil || bridge != nil || VoiceDirect.canDictate }

    /// A live (Realtime) conversation can start: the OpenAI key on this iPhone or the voice bridge.
    /// Without one, voice is dictation into the message field, turn by turn.
    var canTalkLive: Bool { VoiceDirect.apiKey != nil || bridge != nil || rehearsing }

    /// Talk with Poki was asked for with no live voice (no OpenAI key, no voice bridge), from the message
    /// field's button, Poki's profile or `poki://voice`: the message field says what is missing, with
    /// the way to the key, and sets this back.
    var keyAsked = false

    /// A simulator's development build that asked for TalkRehearsal: talks connect to it, with no key.
    var rehearsing: Bool {
        #if DEBUG && targetEnvironment(simulator)
        TalkRehearsal.asked
        #else
        false
        #endif
    }

    /// What the talk is doing, for its screens: nil while no talk is on and none has just failed.
    var talkState: TalkState? {
        #if DEBUG && targetEnvironment(simulator)
        if let staged { return staged }
        #endif
        switch phase {
        case .off: return nil
        case .lost(let why): return .failed(why)
        case .connecting: return .connecting
        case .listening: return interrupted ? .interrupted : .listening
        case .hearing: return interrupted ? .interrupted : .hearing
        case .thinking: return calls.contains { $0.state == .running } ? .acting : .thinking
        case .speaking: return .speaking
        }
    }

    /// Puts away why the last talk ended, once it has been read.
    func dismissProblem() {
        if case .lost = phase { phase = .off }
    }

    private func markInterrupted() {
        interrupted = true
        interruptedLapse?.cancel()
        interruptedLapse = Task { [weak self] in
            await self?.time.sleep(Self.interruptedShows)
            guard !Task.isCancelled else { return }
            self?.interrupted = false
        }
    }

    /// A live Realtime conversation is on (not the hold-to-dictate fallback).
    var isLive: Bool { link != nil }

    /// How voice runs now, for the settings screen.
    var route: String {
        if VoiceDirect.apiKey != nil { return AppLocalization.text(LocalizedStringResource("Your OpenAI key, straight from this iPhone")) }
        if let bridge { return AppLocalization.text(LocalizedStringResource("Voice bridge at \(bridge.display)")) }
        if VoiceDirect.canDictate { return AppLocalization.text(LocalizedStringResource("Dictation to \(ModelKeys.selectedModelName); Poki reads the answer aloud")) }
        return AppLocalization.text(LocalizedStringResource("Not set up"))
    }

    private var dictation: Dictation?

    func setBridge(_ text: String) -> Bool {
        guard let bridge = VoiceBridge(text) else { return false }
        self.bridge = bridge
        VoiceBridge.saved = bridge
        return true
    }

    /// Takes the Mac voice bridge's address off this iPhone. A talk that runs through it ends first: its
    /// next step would go to the bridge.
    func removeBridge() {
        if isLive || isConnecting, VoiceDirect.apiKey == nil { stop() }
        bridge = nil
        VoiceBridge.saved = nil
    }

    /// `poki://voice` can come from any web page, message or app, so it only shows the Voice tab. A link
    /// never changes the voice bridge and never turns on the microphone: the person enters the address
    /// and taps Talk to Poki in the app.
    func open(_ url: URL) {
        let asked = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        if !asked.isEmpty { log.add("voice", "a link asked for \(asked.joined(separator: ", ")); links only bring the chat to the front") }
    }

    #if DEBUG
    /// Development builds only: the `-pokiVoiceLink "poki://voice?bridge=<address>&test=1-20&muted=1"`
    /// launch argument, which only the Mac that installs and launches the build can pass. It may set the
    /// bridge and run silent test turns, which use no microphone.
    func openAtLaunch(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let address = value("bridge") { log.add("voice", setBridge(address) ? "bridge set at launch" : "the launch argument's bridge address was not valid") }
        if value("muted") == "1" { muted = true }
        if let test = value("test"), let range = Self.range(test) { Task { await runTest(range) } }
    }
    #endif

    /// The app's connection: OpenAI's Realtime API, or TalkRehearsal when a simulator build asked for it.
    static let connection: @MainActor (@escaping @MainActor ([String: Any]) -> Void, @escaping @MainActor (String) -> Void) -> VoiceConnection = { onEvent, onClosed in
        #if DEBUG && targetEnvironment(simulator)
        if TalkRehearsal.asked { return TalkRehearsal(onEvent: onEvent, onClosed: onClosed) }
        #endif
        return VoiceLink(onEvent: onEvent, onClosed: onClosed)
    }

    /// Only reached when `rehearsing`.
    private static var rehearsalToken: VoiceBridge.Token {
        #if DEBUG && targetEnvironment(simulator)
        TalkRehearsal.token
        #else
        preconditionFailure("a talk with no key and no bridge outside a rehearsal")
        #endif
    }

    func start(microphone: Bool = true) async {
        guard link == nil, dictation == nil, !isConnecting else { return }
        // The OpenAI key on this iPhone first (no Mac needed), then the bridge, then dictation.
        let key = VoiceDirect.apiKey
        if key == nil, bridge == nil, !rehearsing {
            if VoiceDirect.canDictate, microphone { await startDictation() } else { phase = .lost(VoiceError.noBridge.words) }
            return
        }
        phase = .connecting
        session += 1
        let number = session
        do {
            let token: VoiceBridge.Token
            if rehearsing { token = Self.rehearsalToken } else if let key { token = try await VoiceDirect.token(apiKey: key) } else { token = try await bridge!.token() }
            // Ended (End, or the button again) while the key was exchanged.
            guard number == session else { return }
            localTools = Set(token.local_tools)
            var link = connection({ [weak self] event in self?.handle(event, session: number) },
                                  { [weak self] reason in self?.closed(reason, session: number) })
            self.link = link
            transcript = ("voice-\(UUID().uuidString.prefix(8).lowercased())", Date(), lines.count)
            if microphone { holdingMicrophone = true }
            do {
                try await link.connect(secret: token.value, microphone: microphone, direct: false)
            } catch VoiceError.noPath(let ice) {
                // No path opened (ICE \(ice)): once more, off VPN interfaces (Poki's loopback, a proxy
                // app) and with a fresh key, before telling the owner.
                guard number == session else { return }
                log.add("voice", "no network path opened (ICE \(ice)); trying again off VPN interfaces")
                link.close()
                let retry: VoiceBridge.Token
                if let key { retry = try await VoiceDirect.token(apiKey: key) } else { retry = try await bridge!.token() }
                guard number == session else { return }
                link = connection({ [weak self] event in self?.handle(event, session: number) },
                                  { [weak self] reason in self?.closed(reason, session: number) })
                self.link = link
                try await link.connect(secret: retry.value, microphone: microphone, direct: true)
            }
            guard number == session else { link.close(); return }
            lastActivity = time.now()
            watchForStall(session: number)
            link.setRemoteVolume(muted ? 0 : 1)
            log.add("voice", "connected (\(token.model)), session \(number)")
            if microphone { link.diagnose { [log] line in log.add("voice", line) } }
        } catch {
            // Ended while connecting: stop() already put everything back.
            guard number == session else { return }
            transcript = nil
            link?.close()
            link = nil
            holdingMicrophone = false
            phase = .lost(VoiceError.reason(for: error))
            log.add("voice", "could not connect: \(error.localizedDescription)")
        }
    }

    private func saveTranscript() {
        guard let transcript, lines.count >= transcript.from else { return }
        SessionStore.shared.save(voice: transcript.id, started: transcript.started, lines: Array(lines[transcript.from...]), live: link != nil)
    }

    /// The chat the conversation was held in (Poki's chat): when it ends, what was said and done goes
    /// into that chat's history, where it stays, instead of a separate row that the next conversation
    /// or a relaunch would take off the screen.
    var onConversationEnded: (@MainActor (_ lines: [VoiceLine], _ started: Date) -> Void)?

    private func endTranscript() {
        guard let ended = transcript else { return }
        saveTranscript()
        transcript = nil
        let said = lines.count >= ended.from ? Array(lines[ended.from...]) : []
        guard let onConversationEnded, !said.isEmpty else { return }
        onConversationEnded(said, ended.started)
        // Now in the chat's own session: the voice row (kept while it ran, in case Poki closed) goes.
        SessionStore.shared.delete(ended.id)
        lines.removeAll()
    }

    /// Ends the conversation. Calls already running keep running; the next session hears how they ended.
    func stop() {
        if let dictation {
            dictation.stopSpeaking()
            Task { _ = await dictation.finish() }
            self.dictation = nil
        }
        endSession()
        // A start still connecting sees this and stops where it is.
        session += 1
        phase = .off
        endTranscript()
    }

    /// Drops the connection and the state of its turns; calls already running keep running. The lines of
    /// the conversation are kept for one opened soon after, before the chat takes them.
    private func endSession() {
        keepOpen()
        interruptedLapse?.cancel()
        interrupted = false
        stallWatch?.cancel()
        stallWatch = nil
        if ready, let from = transcript?.from {
            let said = lines[min(from, lines.count)...].filter { $0.role == .you || $0.role == .poki }
            if !said.isEmpty {
                lastEnd = time.now()
                lastLines = said
            }
        }
        if let link {
            link.close()
            // Whether the shared audio session let go of the microphone after WebRTC closed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [log] in log.add("voice", "1 s after the end: \(VoiceLink.audioSession())") }
        }
        link = nil
        holdingMicrophone = false
        ready = false
        activeResponse = nil
        wantsResponse = false
        awaitingAnswer = false
        requestedAnswer = nil
    }

    /// Something is still to be said or done: an answer is expected, being given or about to be asked for,
    /// the person is speaking, or a step is running.
    private var answerDue: Bool {
        awaitingAnswer || activeResponse != nil || wantsResponse
            || phase == .hearing || phase == .speaking || calls.contains { $0.state == .running }
    }

    /// The server owes something: the end of the person's speech, an answer, the end of the audio. A step
    /// that is running is not the server's to answer for, and it has its own time limits.
    private var waitingOnServer: Bool {
        !ready || (awaitingAnswer || activeResponse != nil || wantsResponse || phase == .hearing || phase == .speaking)
            && !calls.contains { $0.state == .running }
    }

    /// Ends the conversation when the server owes something and has said nothing for `stall` (30 s in the
    /// background). A lost event, or an error that names no request, would otherwise leave the microphone on.
    private func watchForStall(session number: Int) {
        stallWatch?.cancel()
        stallWatch = Task { [weak self, time] in
            var wait = self?.stallLeft() ?? .zero
            while true {
                await time.sleep(wait)
                guard !Task.isCancelled, let self, number == session, isOn else { return }
                let left = stallLeft()
                if left > .zero { wait = left; continue }
                if waitingOnServer {
                    log.add("voice", "the server said nothing for \(inBackground ? Self.backgroundStall : Self.stall) while Poki waited on it: conversation ended")
                    lines.append(VoiceLine(role: .note, text: AppLocalization.text(LocalizedStringResource("The server did not answer. The talk ended."))))
                    stop()
                    return
                }
                wait = inBackground ? Self.backgroundStall : Self.stall
            }
        }
    }

    /// How much longer the wait for the server may last, counted from the last activity.
    private func stallLeft() -> Duration {
        let limit = inBackground ? Self.backgroundStall : Self.stall
        let passed = time.now().timeIntervalSince(lastActivity)
        return max(.zero, limit - .seconds(passed))
    }

    /// The answer has played and nothing it asked for is still running or still to be said.
    private var idle: Bool { link != nil && ready && !answerDue }

    /// Once idle, the conversation waits `followUp` for the person to go on; if nobody speaks it ends and
    /// lets go of the microphone. The same in front and in the background.
    private func endIfDone() {
        guard idle, endWindow == nil else { return }
        endWindow = Task { [weak self, time] in
            await time.sleep(Self.followUp)
            guard let self, !Task.isCancelled else { return }
            endWindow = nil
            guard idle else { return }
            log.add("voice", "nobody spoke for \(Self.followUp) after the answer: conversation ended")
            stop()
        }
    }

    private func keepOpen() {
        endWindow?.cancel()
        endWindow = nil
    }

    /// A conversation opened soon after the last one hears what was said last, so it goes on from there.
    private func carryOver(_ link: VoiceConnection) {
        guard let lastEnd, time.now().timeIntervalSince(lastEnd) < Self.carryOver else { return }
        let turns = lastLines.suffix(Self.carriedLines)
        let said = turns.map { "\($0.role == .you ? "User" : "Poki"): \($0.text)" }.joined(separator: "\n")
        link.send(Self.note("This continues a conversation from a few minutes ago. What was said, oldest first. Use it only as context for what the user says next; do not answer or repeat it.\n" + said))
    }

    // MARK: Dictation

    /// The button pressed: starts the conversation, or (dictating) listens for the next request.
    func press() async {
        if let dictation {
            guard phase != .hearing, phase != .thinking else { return }
            do { try dictation.listen(); phase = .hearing } catch { phase = .lost(VoiceError.reason(for: error)) }
            return
        }
        if !isOn, canTalk { await start() }
    }

    /// The button let go. Realtime knows by itself when you stopped; dictation sends what it heard.
    func released() {
        guard let dictation, phase == .hearing else { return }
        phase = .thinking
        Task {
            let text = await dictation.finish()
            if lines.last?.role == .you, lines.last?.text != text { lines.removeLast() }
            guard !text.isEmpty else { phase = .listening; return }
            if lines.last?.text != text { lines.append(VoiceLine(role: .you, text: text)) }
            guard let chat = AskPoki.chat else { phase = .lost(VoiceError.noBridge.words); return }
            if chat.running { lines.append(VoiceLine(role: .note, text: AppLocalization.text(LocalizedStringResource("Poki is still on the last task.")))); phase = .listening; return }
            let before = chat.entries.count
            chat.send(text)
            while chat.running { try? await Task.sleep(for: .milliseconds(200)) }
            let reply = chat.entries.dropFirst(before).compactMap { entry -> String? in if case .poki(let t) = entry.kind { return t }; return nil }.last
                ?? AppLocalization.text(LocalizedStringResource("Done."))
            lines.append(VoiceLine(role: .poki, text: reply))
            guard self.dictation === dictation else { return }
            phase = .speaking
            dictation.speak(reply.replacingOccurrences(of: "**", with: ""))
        }
    }

    private func startDictation() async {
        guard await Dictation.allowed() else { phase = .lost(AppLocalization.text(LocalizedStringResource("Poki needs the microphone and speech recognition: allow them in Settings › Poki."))); return }
        let dictation = Dictation()
        dictation.onHeard = { [weak self] text in
            guard let self, self.phase == .hearing else { return }
            if self.lines.last?.role == .you { self.lines.removeLast() }
            self.lines.append(VoiceLine(role: .you, text: text))
        }
        dictation.onSpoken = { [weak self] in if self?.phase == .speaking { self?.phase = .listening } }
        self.dictation = dictation
        holdingMicrophone = true
        do {
            try dictation.listen()
            phase = .hearing
            log.add("voice", "dictation to the chat (no Realtime key or bridge)")
        } catch {
            self.dictation = nil
            holdingMicrophone = false
            phase = .lost(VoiceError.reason(for: error))
        }
    }

    /// Stops Poki's voice reply. Anything running on the phone keeps running.
    func stopTalking() {
        if let dictation { dictation.stopSpeaking(); if phase == .speaking { phase = .listening }; return }
        guard let link else { return }
        if phase == .speaking { markInterrupted() }
        if activeResponse != nil { link.send(["type": "response.cancel"]) }
        link.send(["type": "output_audio_buffer.clear"])
        // Without this the next answer (say, when a running step finishes) picks the cut-off reply back up.
        if ready { link.send(Self.note(Self.stoppedNote)) }
    }

    private static let stoppedNote = "The user pressed Stop talking. Drop the reply you were giving; do not continue or repeat it. When a running step finishes, report only its result, in one sentence."

    #if DEBUG
    /// Recorded speech instead of the microphone, for test runs: 24 kHz mono PCM16, sent as one user turn.
    func say(pcm24k: Data) {
        guard let link, ready else { return }
        // A data channel message carries about 256 KB at most, so speech goes in as parts of 2 seconds.
        let part = 96_000
        var sent = true
        for start in stride(from: 0, to: pcm24k.count, by: part) {
            let audio = pcm24k.subdata(in: start..<min(start + part, pcm24k.count)).base64EncodedString()
            sent = link.send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_audio", "audio": audio]]]]) && sent
        }
        if !sent { log.add("voice", "the recorded speech did not go out on the data channel") }
        clock = TurnClock(said: Date())
        wantsResponse = true
        flush()
    }
    #endif

    private func closed(_ reason: String, session number: Int) {
        guard number == session, link != nil else { return }
        endSession()
        phase = .lost(TalkState.connectionLost)
        lines.append(VoiceLine(role: .note, text: AppLocalization.text(LocalizedStringResource("Connection lost. Nothing is sent again. Talk again to hear how running steps ended."))))
        endTranscript()
        log.add("voice", "connection lost: \(reason)")
    }

    // MARK: Events

    private func handle(_ event: [String: Any], session number: Int) {
        guard number == session, let link, let type = event["type"] as? String else { return }
        lastActivity = time.now()
        switch type {
        case "session.created":
            log.add("voice", "session created, session \(number)")
            ready = true
            watchForStall(session: number)
            phase = .listening
            carryOver(link)
            catchUp(link)
            endIfDone()
        case "input_audio_buffer.speech_started":
            keepOpen()
            if phase != .hearing { log.add("voice", "speech started") }
            // Spoken over Poki's answer: the server drops the answer's audio, and the talk says so.
            if phase == .speaking { markInterrupted() }
            phase = .hearing
        case "input_audio_buffer.speech_stopped":
            phase = .thinking
            awaitingAnswer = true
            clock = TurnClock(said: Date())
        case "conversation.item.added":
            if (event["item"] as? [String: Any])?["role"] as? String == "user" { clock.heard = clock.heard ?? Date() }
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"] as? String, !text.isEmpty { lines.append(VoiceLine(role: .you, text: text.trimmingCharacters(in: .whitespacesAndNewlines))) }
        case "response.created":
            activeResponse = (event["response"] as? [String: Any])?["id"] as? String
            keepOpen()
            awaitingAnswer = false
            requestedAnswer = nil
        case "response.done":
            let response = event["response"] as? [String: Any]
            if let usage = response?["usage"] as? [String: Any] { clock.add(usage: usage) }
            if response?["id"] as? String == activeResponse { activeResponse = nil }
            flush()
            endIfDone()
        case "response.output_audio_transcript.done":
            if let text = event["transcript"] as? String, !text.isEmpty {
                lines.append(VoiceLine(role: .poki, text: text))
                if clock.delivered != nil { clock.reply += text }
            }
        case "output_audio_buffer.started":
            phase = .speaking
            if let said = clock.said, let delivered = clock.delivered, clock.spoken == nil {
                clock.spoken = Date()
                lastTurnMS = clock.ms(\.spoken)
                log.add("voice", "turn: end of speech to spoken result \(lastTurnMS!) ms (tool result in \(Int(delivered.timeIntervalSince(said) * 1000)) ms)")
            }
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            // Cleared because the person started speaking over the answer: they are still being heard.
            if phase != .hearing { phase = calls.contains { $0.state == .running } ? .thinking : .listening }
            endIfDone()
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any], item["type"] as? String == "function_call",
                  let id = item["call_id"] as? String, let name = item["name"] as? String else { return }
            run(VoiceCall(id: id, name: name, arguments: item["arguments"] as? String ?? "{}", session: number))
        case "error":
            let message = ((event["error"] as? [String: Any])?["message"] as? String) ?? "unknown error"
            log.add("voice", "realtime error: \(message)")
            // An error can be all the server sends after the person spoke, or the answer to Poki's own
            // response.create; no answer is coming then. An error about something else, while Poki's
            // request for an answer is out, leaves that answer expected.
            let about = (event["error"] as? [String: Any])?["event_id"] as? String
            if requestedAnswer == nil || about == requestedAnswer {
                awaitingAnswer = false
                requestedAnswer = nil
            }
            endIfDone()
        default:
            break
        }
    }

    /// Runs a call once. The same call_id again (a repeated event) is ignored.
    private func run(_ call: VoiceCall) {
        guard !calls.contains(where: { $0.id == call.id }) else { return }
        calls.append(call)
        clock.call = clock.call ?? Date()
        clock.callNames.append(call.name)
        phase = .thinking
        lines.append(VoiceLine(role: .tool, text: Self.describe(call)))
        log.add("voice", "tool \(call.name) \(call.arguments)")
        let local = localTools.contains(call.name)
        let bridge = bridge
        Task {
            var state = VoiceCall.State.done
            var output: String
            if local, Self.phoneTools.contains(call.name) {
                let (text, failed) = await phoneTool(call.name, call.arguments)
                output = text.count > 6000 ? String(text.prefix(6000)) + "…" : text
                if failed { state = .failed }
            } else if local {
                output = Self.localTool(call.name)
            } else if let bridge {
                do {
                    var result = try await bridge.run(callID: call.id, name: call.name, arguments: call.arguments)
                    var note = ""
                    if result.state == "check", let target = result.target {
                        // A tap: Poki's approval rules first, and the owner's OK on the phone when they ask for it.
                        let app = result.app
                        let clearance = await clearTap(target.says, app?.bundle_id, app?.name)
                        if clearance.mayTap {
                            if case .approved(let why) = clearance { note = "The user allowed it on the phone (\(why)). "; log.add("voice", "tap approved: \(why)") }
                            var checked = ["text": target.text]
                            checked["app"] = app?.bundle_id
                            result = try await bridge.run(callID: call.id, name: call.name, arguments: call.arguments, checked: checked)
                        } else {
                            result = Self.refused(clearance)
                            log.add("voice", "tap not sent: \(result.output)")
                        }
                    }
                    output = note + result.output
                    if result.state != "done" { state = .failed }
                } catch {
                    // The bridge may have run it; never send it again. The model hears that the outcome is unknown.
                    output = "unknown: the bridge did not answer (\(error.localizedDescription)); the action may have run. Read the screen before trying again."
                    state = .failed
                }
            } else {
                output = "error: no voice bridge"
                state = .failed
            }
            finish(call.id, state: state, output: output)
        }
    }

    private func finish(_ id: String, state: VoiceCall.State, output: String) {
        guard let index = calls.firstIndex(where: { $0.id == id }) else { return }
        calls[index].state = state
        calls[index].output = output
        calls[index].finished = Date()
        clock.toolDone = Date()
        log.add("voice", "tool \(calls[index].name) \(state == .done ? "done" : "failed")")
        deliver(index)
    }

    /// Hands a finished call to the model: as its function_call_output in the session that asked, or as a
    /// note in a later session. With no session, it waits for the next one.
    private func deliver(_ index: Int) {
        guard let link, ready, !calls[index].delivered, calls[index].state != .running else { return }
        let call = calls[index]
        let sent = call.session == session
            ? link.send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": call.id, "output": call.output]])
            : link.send(Self.note("While the connection was down, \(call.name) \(call.arguments) finished. It already ran; do not run it again. Tell the user in one sentence how it ended. Result: \(call.output)"))
        guard sent else { return }
        calls[index].delivered = true
        lastActivity = time.now()
        clock.delivered = Date()
        wantsResponse = true
        flush()
    }

    /// A new session after a drop: say what already ran, so the model reports it instead of asking again.
    private func catchUp(_ link: VoiceConnection) {
        let running = calls.filter { $0.state == .running }
        if !running.isEmpty {
            link.send(Self.note("Before the connection dropped, these were started and are still running; their results will follow. Do not start them again: " + running.map { "\($0.name) \($0.arguments)" }.joined(separator: "; ")))
        }
        for index in calls.indices where calls[index].state != .running && !calls[index].delivered { deliver(index) }
    }

    /// Asks for a response once none is active (the API takes one at a time).
    private func flush() {
        guard wantsResponse, activeResponse == nil, ready, let link else { return }
        wantsResponse = false
        awaitingAnswer = true
        let id = UUID().uuidString
        requestedAnswer = id
        lastActivity = time.now()
        link.send(["type": "response.create", "event_id": id])
    }

    // MARK: Test runs (development builds only)

    #if DEBUG
    /// `-pokiVoiceLink "poki://voice?test=1-20"`: each turn opens a fresh session, plays recorded utterance n from the bridge
    /// over the data channel (no microphone, Poki's voice muted), waits for the spoken result and reports
    /// the turn to the bridge.
    func runTest(_ numbers: ClosedRange<Int>) async {
        guard let bridge else { phase = .lost(VoiceError.noBridge.words); return }
        muted = true
        // Test runs have no microphone, so no voice-chat audio session keeps Poki running while a step
        // brings another app to the front; a silent one does, as for a Poki session.
        let awake = KeepAlive()
        try? awake.start()
        defer { awake.stop() }
        log.add("voice", "test run \(numbers.lowerBound)-\(numbers.upperBound) started")
        for n in numbers {
            stop()
            var report: [String: Any] = ["n": n, "device": Self.localTool("get_ios_version")]
            await start(microphone: false)
            if await until(10, { self.ready }), let pcm = try? await bridge.utterance(n) {
                say(pcm24k: pcm)
                let ok = await until(40, { self.clock.spoken != nil && !self.clock.reply.isEmpty && self.activeResponse == nil })
                report["ok"] = ok
                report["calls"] = clock.callNames
                report["reply"] = clock.reply
                report["tokens"] = clock.tokens
                report["ms"] = ["heard": clock.ms(\.heard), "call": clock.ms(\.call), "toolDone": clock.ms(\.toolDone), "delivered": clock.ms(\.delivered), "spoken": clock.ms(\.spoken)].compactMapValues { $0 }
            } else {
                report["ok"] = false
                report["error"] = { if case .lost(let why) = self.phase { return why } else { return "no session" } }()
            }
            stop()
            try? await bridge.report(report)
        }
        log.add("voice", "test run finished")
    }

    private func until(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private static func range(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard let first = parts.first, let last = parts.last, first >= 1, last >= first, last <= 99 else { return nil }
        return first...last
    }
    #endif

    private static func refused(_ clearance: TapClearance) -> VoiceBridge.ToolResult {
        let output: String
        switch clearance {
        case .declined(let why): output = "not_sent: the user declined on the phone (\(why)). Nothing was tapped."
        case .unanswered(let why): output = "not_sent: the user did not allow it on the phone in time (\(why)). Nothing was tapped."
        case .refused(let why): output = "not_sent: \(why). Nothing was tapped."
        case .clear, .approved: output = ""
        }
        return VoiceBridge.ToolResult(state: "failed", output: output)
    }

    private static func note(_ text: String) -> [String: Any] {
        ["type": "conversation.item.create", "item": ["type": "message", "role": "system", "content": [["type": "input_text", "text": text]]]]
    }

    private static func describe(_ call: VoiceCall) -> String {
        switch call.name {
        case "get_ios_version": AppLocalization.text(LocalizedStringResource("Reading the iOS version"))
        case "open_settings": AppLocalization.text(LocalizedStringResource("Opening Settings"))
        case "read_screen": AppLocalization.text(LocalizedStringResource("Reading the screen"))
        case "open_app": AppLocalization.text(LocalizedStringResource("Opening an app"))
        case "tap_text": AppLocalization.text(LocalizedStringResource("Tapping"))
        case "go_home": AppLocalization.text(LocalizedStringResource("Going Home"))
        case "look": AppLocalization.text(LocalizedStringResource("Looking at the screen"))
        case "do": AppLocalization.text(LocalizedStringResource("Using the phone"))
        default: call.name
        }
    }

    /// PokiCore's tools, answered on this phone through the runner.
    static let phoneTools: Set<String> = ["look", "do"]

    /// Tools the phone answers itself. They change nothing.
    static func localTool(_ name: String) -> String {
        switch name {
        case "get_ios_version":
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return #"{"model":"\#(machine)","ios_version":"\#(UIDevice.current.systemVersion)"}"#
        default:
            return "error: \(name) is not a phone tool"
        }
    }
}
