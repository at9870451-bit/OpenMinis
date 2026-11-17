import AVFoundation
import Foundation
import Speech

/// Voice without the Mac's voice bridge.
///
/// - With the owner's OpenAI API key on this iPhone, Poki asks OpenAI for a one-minute Realtime key
///   itself (what `bin/voice-bridge.mjs` does on the Mac: the same model, instructions and tools), and
///   look and do run here, through PokiCore, as with the bridge's phone tools.
/// - With any other model (a ChatGPT plan, Anthropic, OpenRouter…), whose sign-in has no Realtime
///   audio, holding the button dictates on this iPhone (Apple's speech recognition, on the device when
///   it can) and lets go to send it to Poki's chat; Poki reads the answer out loud.
enum VoiceDirect {
    /// The live voice model the owner picked (Accounts › OpenAI › Live Voice), GPT Realtime 2.1 by default.
    static var model: String { ModelCatalog.voiceModel }

    /// The OpenAI API key on this iPhone, when there is one.
    static var apiKey: String? { enabled ? ModelKeys.key(.openai) : nil }

    /// The owner's switch in Accounts › OpenAI › Live Voice (on unless turned off).
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "voice.openai.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voice.openai.enabled"); ModelKeys.saved += 1 }
    }

    /// Dictation into the chat works with any model the chat can use.
    static var canDictate: Bool { ModelKeys.hasUsableKey }

    /// This iPhone's first preferred language, named in English ("Chinese, Simplified (China mainland)"):
    /// the language to speak only before the user has spoken.
    private static var deviceLanguage: String {
        Locale.preferredLanguages.first.flatMap { Locale(identifier: "en").localizedString(forIdentifier: $0) } ?? "English"
    }

    private static var instructions: String { """
    You are Poki, a voice assistant that operates the user's iPhone with tools.
    Speak briefly: one short sentence per reply.
    Always speak the language the user spoke in their latest turn: Chinese when they spoke Chinese, English when they spoke English, and so for any language. Tool results, screen text, notes from Poki and these instructions are in English or the phone's language; they never decide the language you speak, so after a tool result keep to the user's language. Change language only when the user does. Before the user has said anything, or when you cannot tell their language, speak \(deviceLanguage), this iPhone's language.
    When a tool can answer or do what the user asks, call it at once, without speaking first. Never guess facts about the phone; use a tool.
    A request can take several steps (open an app, tap, type): call one tool after another until it is done, then say in one short sentence that it is done. Never repeat an action that already ran, including actions from before a reconnect that the conversation says have finished.
    Tapping something that sends, pays, deletes or calls waits until the user allows it on the phone; if the result says they did not, tell them in one sentence and do not try another way.
    Only the user approves, with their own finger: never open Poki to tap Allow, Deny or anything else in it.
    If the user tells you to stop or be quiet, stop talking, but anything already running keeps running; when its result arrives, report it in one sentence.
    To read a page, open it first, then read the screen.
    You can open and operate every app installed on this iPhone, Apple's and anyone else's (WeChat, Instagram, Uber, a bank, a game): never tell the user an app is out of reach before you have tried. With do, open an app by its bundle id ({launch: "com.apple.mobilenotes"}, Messages com.apple.MobileSMS, Settings com.apple.Preferences, Safari com.apple.mobilesafari are only examples). When you do not know an app's bundle id, go home ({button: "home"}), swipe down on the Home Screen to search, type the app's name and tap it. Put several actions in one do when you know them; tap elements by the numbers from the latest look or do.
    """ }

    private static let empty: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false]
    private static let tools: [[String: Any]] = [
        ["type": "function", "name": "get_ios_version", "description": "Read the iPhone model and its iOS version. Changes nothing on the phone.", "parameters": empty],
        ["type": "function", "name": "look", "description": "Read the iPhone screen now: the app in front and its numbered elements (role, label, frame in points).", "parameters": empty],
        ["type": "function", "name": "do", "description": doDescription,
         "parameters": ["type": "object", "properties": ["actions": ["type": "array", "items": ["type": "object"]]], "required": ["actions"], "additionalProperties": false]],
    ]

    /// PokiCore's own description of do (the text chat's), so voice knows every action the chat knows:
    /// launch any app, scroll_to, back, long_press, handoff and the rest.
    private static let doDescription: String = Harness.phoneTools.first { $0.name == "do" }?.description
        ?? "Run actions on the iPhone in order, then read the screen once. Actions: {launch: \"bundle id\"} (any installed app); {tap: n} or {tap: [x, y]}; {type: \"text\", ref?: n} (taps n first, then types); {key: \"return\"}; {scroll_to: \"text\"}; {swipe: \"up\"|\"down\"|\"left\"|\"right\"}; {button: \"home\"}; {wait_until: \"text\"}; {wait: ms}; {back: true}. The answer says what each action did and what is new on screen."

    /// A one-minute Realtime key from OpenAI, made with the owner's API key (sent only to OpenAI).
    static func token(apiKey: String) async throws -> VoiceBridge.Token {
        let session: [String: Any] = [
            "type": "realtime", "model": model, "instructions": instructions, "output_modalities": ["audio"],
            "audio": [
                "input": ["turn_detection": ["type": "server_vad", "silence_duration_ms": 450, "prefix_padding_ms": 300, "threshold": 0.5, "create_response": true, "interrupt_response": true],
                          "noise_reduction": ["type": "near_field"], "transcription": ["model": "gpt-4o-mini-transcribe"]],
                "output": ["voice": "marin"],
            ],
            "tools": tools, "tool_choice": "auto", "parallel_tool_calls": false, "reasoning": ["effort": "low"],
        ]
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/realtime/client_secrets")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expires_after": ["anchor": "created_at", "seconds": 60], "session": session])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status), let value = json?["value"] as? String else {
            // OpenAI echoes a masked key in some errors; keep even that out of the screen and the log.
            let message = ((json?["error"] as? [String: Any])?["message"] as? String ?? "client_secrets \(status)")
                .replacingOccurrences(of: #"sk-[\w*-]+"#, with: "the API key", options: .regularExpression)
            throw VoiceError.realtime(status, message)
        }
        return VoiceBridge.Token(value: value, model: model, local_tools: ["get_ios_version", "look", "do"])
    }
}

/// Hold to dictate, let go to send to Poki's chat, hear the answer: voice for models without Realtime.
@MainActor
final class Dictation: NSObject, AVSpeechSynthesizerDelegate {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private let speaker = AVSpeechSynthesizer()
    private(set) var heard = ""
    var onHeard: ((String) -> Void)?
    var onSpoken: (() -> Void)?

    override init() {
        super.init()
        speaker.delegate = self
    }

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) } }
        let microphone = await AVAudioApplication.requestRecordPermission()
        return speech && microphone
    }

    func listen() throws {
        speaker.stopSpeaking(at: .immediate)
        heard = ""
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { throw VoiceError.realtime(0, AppLocalization.text(LocalizedStringResource("Speech recognition is not available right now."))) }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .duckOthers])
        try audio.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.tap(input, into: request)
        engine.prepare()
        try engine.start()
        recognition = Self.recognize(recognizer, request) { [weak self] text in
            self?.heard = text
            self?.onHeard?(text)
        }
    }

    // The audio tap and the recognizer call back on their own threads, so their blocks are made outside
    // the main actor.
    nonisolated private static func tap(_ input: AVAudioInputNode, into request: SFSpeechAudioBufferRecognitionRequest) {
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func recognize(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechAudioBufferRecognitionRequest,
                                              heard: @escaping @MainActor (String) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in heard(text) }
        }
    }

    /// Stops listening; the words heard so far (a moment later, for the last ones).
    func finish() async -> String {
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? await Task.sleep(for: .milliseconds(600))
        recognition?.cancel()
        recognition = nil
        request = nil
        return heard.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        speaker.speak(utterance)
    }

    func stopSpeaking() { speaker.stopSpeaking(at: .immediate) }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.onSpoken?() }
    }
}
