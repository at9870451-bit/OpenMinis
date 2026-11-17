import Foundation
import PiSwiftAI
import PokiCore
import SwiftUI

/// One thing in the conversation, in the order it is drawn.
struct ChatEntry: Identifiable, Equatable, Codable {
    enum Kind: Equatable, Codable {
        /// "Today 9:41 AM" above a conversation.
        case time(Date)
        case you(String, delivered: Bool)
        case poki(String)
        /// The steps of a task, in one Poki bubble.
        case plan([PlanStep])
        /// One grey line, centred: waiting for, or the result of, an approval.
        case note(ChatNote)
        /// An outside agent's own look or do, as one grey line (`ok` nil while it runs).
        case step(String, ok: Bool?)
        /// An outside agent's request to Poki (`ask_poki`), on the requester's side.
        case request(String, from: String)
        /// Poki's browser, where a task began using it: above the answer the task gives. The live page
        /// while it is this conversation's page in use, then the site it showed.
        case browser(BrowserVisit)
    }
    let id: UUID
    var kind: Kind
    var at: Date = Date()
    /// A task's short name from the model ("Text Mom"), on its plan entry. Absent in conversations
    /// saved before it existed and when the model gave none: the card then shows what was asked.
    var title: String?
    /// How a task ended, on its plan entry, for the folded card's second line: the app it was in,
    /// when it ended and how many steps the model had planned. Absent while it runs and in
    /// conversations saved before these existed: the card then counts the steps, as it did.
    var app: String?
    var ended: Date?
    var total: Int?
    /// The small pictures of the photos and PDFs sent with your message (`ChatAttachment.thumbnail`).
    var attachments: [Data]?
    var textDocuments: [ChatTextDocument]?
    var continuationChoices: [String]?
    var continuedTask: String?
    init(_ kind: Kind) { id = UUID(); self.kind = kind }

    /// The same delimited owner request for the model, consent evidence and task routing.
    var requestText: String {
        let caption: String
        switch kind { case .you(let text, _), .request(let text, _): caption = text; default: return "" }
        return ([caption] + (textDocuments ?? []).map(\.modelText)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Browser visits belong to the request around this card, including after restoring a conversation.
    static func taskUsedBrowser(in entries: [ChatEntry], at index: Int) -> Bool {
        func isRequest(_ entry: ChatEntry) -> Bool {
            switch entry.kind { case .you, .request: true; default: false }
        }
        let start = entries[..<index].lastIndex(where: isRequest) ?? entries.startIndex
        let end = entries[(index + 1)...].firstIndex(where: isRequest) ?? entries.endIndex
        return entries[start..<end].contains { if case .browser = $0.kind { true } else { false } }
    }

    var isPoki: Bool { switch kind { case .poki, .plan: true; default: false } }
}

struct PlanStep: Identifiable, Equatable, Codable {
    enum State: String, Equatable, Codable { case current, waiting, done, failed }
    let id: UUID
    var text: String
    var state: State
    init(_ text: String, state: State = .current) { id = UUID(); self.text = text; self.state = state }
}

enum ChatNote: Equatable, Codable {
    case waiting
    case approved(Date)
    case declined
    case expired
    case problem(String)
    /// The auto-classifier (testing): the chat model is deciding, or decided, with its reason.
    case modelChecking
    case modelApproved(String)
    case modelDeclined(String)
    /// An approval with what was asked and how it was answered, drawn as a card.
    case approval(ApprovalNote)
}

/// What Poki's browser showed in a task, for its card once the live page is no longer this card's.
struct BrowserVisit: Equatable, Codable {
    var host = ""
    var title = ""
}

/// One approval in the chat: the step, why it needed an answer, who answered and what they said.
struct ApprovalNote: Equatable, Codable {
    enum State: String, Codable { case asking, allowed, refused, expired }
    var id: String
    var summary: String
    var app: String
    /// PokiCore's reason for asking: `sending a message ("send")`.
    var why: String
    /// The auto-classifier answers; false when the owner does.
    var byModel: Bool
    var state: State
    /// The model's reason, when it answered.
    var reason = ""
    /// A refusal the owner can lift by saying yes in the chat (With Message Reply).
    var reply = false
    var answered: Date?
}

/// The chat: the owner's messages, Poki's answers and the steps it takes, and the model loop that runs
/// on this iPhone with the owner's own key (ESP-174). Its prompt and tools are the Mac Poki Agent's
/// (`Harness`): PokiCore's `look` and `do`, with the same approval rules as an agent on a computer, and
/// the agent's `report_plan` and `finish_task`, which drive the plan bubble.
@MainActor
@Observable
final class ChatModel {
    private(set) var entries: [ChatEntry] = [] { didSet { persist() } }
    /// The browser card that shows the live page: the one this conversation's latest browsing task added.
    private(set) var liveBrowser: UUID?
    private(set) var running = false
    /// The model has the turn: nothing from it yet since the owner's message or the last tool answer
    /// (the chat shows the typing bubble).
    private(set) var awaitingModel = false
    /// This conversation in the Sessions list.
    private(set) var sessionID = UUID().uuidString.lowercased()
    /// An in-app chat, or a task an outside agent handed to Poki (`ask_poki`).
    let kind: SavedSession.Kind
    /// The agent that handed the task over, for `.handoff`.
    let requester: String?
    /// The tool calls of this conversation, for "save a routine from this session" (SessionStore.record).
    private(set) var calls: [CallRecord] = []
    /// Told when a task ends, with its calls and finish_task's verdict.
    static var afterTask: (@MainActor (TaskRecord) -> Void)?
    /// A board's sample conversation, for screenshots.
    let isSample = UserDefaults.standard.string(forKey: "amore.original.pokiChat.sample") != nil
    private let app: AppModel
    private let store: SessionStore
    /// The model's side of the conversation: pi's loop (ESP-177), or for Anthropic and OpenAI with
    /// `-chatEngine direct`, the provider's own API in its own form.
    private var loop: PiLoop?
    /// For the log's line at the end of each task: when it began, the tool calls, finish_task's verdict.
    private var taskStart = Date()
    private var toolCalls = 0
    private var taskCalls: [CallRecord] = []
    private var taskResult: TaskResult?
    private var client: ModelClient?
    private var restoredContext: String?
    /// The plan the model published with report_plan; the bubble shows its steps up to the current one.
    private var modelPlan: [String]?

    /// The app this task is for (`TaskApps`), for its card and its conversation's row. A task that has
    /// opened or acted in no app has none: its card never shows the app the task before it ended in.
    private(set) var taskApp: String?
    /// What the task under way opened and acted in, and what it was asked, for `taskApp`.
    private var taskApps = TaskApps()
    private var taskRequest = ""
    private enum ToolRoute { case app, web }
    private var toolRoute: ToolRoute?
    private var usesSplitView = false
    private var splitViewSession: String?
    var isRunningInSplitView: Bool { running && usesSplitView }
    private var hasSplitViewRead = false
    private var lastSplitViewSide: String?
    private var lastSplitViewLayout: String?
    private(set) var waitingForSplitView = false
    private var expectedSplitViewApps: Set<String>?
    /// The whole plan the model published, for the task card's steps still to come.
    var planSteps: [String]? { modelPlan }
    private var task: Task<Void, Never>?
    private var stopAsked = false
    /// Counts tasks. Stop moves it on, so what a stopped task still does while its last step ends is
    /// not written into the chat or over the next task.
    private var runToken = 0
    /// The plan bubble of the task under way.
    private var planID: UUID?
    private var noteID: UUID?

    /// A ceiling for a runaway model's quota use. On an unchanged screen, PiLoop stops after
    /// `stallSteps` identical calls or `stallPairs` repetitions of a call pair. Waiting for the owner
    /// or runner startup resets that history, but does not remove this ceiling.
    static let maxTurns = 500

    init(app: AppModel, kind: SavedSession.Kind = .poki, requester: String? = nil, sessionID: String? = nil, store: SessionStore? = nil) {
        let store = store ?? .shared
        self.app = app
        self.store = store
        if let sessionID { self.sessionID = sessionID }
        self.kind = kind
        self.requester = requester
        app.addShellObserver { [weak self] event in self?.observe(event) }
        app.addApprovalObserver { [weak self] id in self?.waitsForOwner(id) }
        if kind == .handoff { return }
        app.addApprovalModeObserver { [weak self] in self?.approvalsChanged() }
        app.addStopAskingObserver { [weak self] in self?.approvalsStopped() }
        // A live voice conversation is part of this chat: what was said and done stays in its history.
        if requester == nil { app.voice.onConversationEnded = { [weak self] lines, started in self?.appendVoice(lines, started: started) } }
        if let scene = UserDefaults.standard.string(forKey: "amore.original.pokiChat.sample") { loadSample(scene); return }
        // The last in-app conversation comes back at launch, as in Messages.
        if store.isInitialReady {
            if let last = store.latestPoki(), Date().timeIntervalSince(last.updated) < 12 * 3600 {
                restore(last)
            } else {
                greet()
            }
        } else {
            greet()
            store.whenInitialReady { [weak self] in
                self?.restoreLatestIfUntouched()
            }
        }
    }

    private var userChoseConversation = false
    private(set) var hasDraft = false

    func setDraftActivity(_ active: Bool) {
        hasDraft = active
    }

    private var hasUserMessages: Bool {
        entries.contains {
            if case .you = $0.kind { return true }
            if case .request = $0.kind { return true }
            return false
        }
    }

    private func restoreLatestIfUntouched() {
        guard !running, !isSample, kind == .poki, !userChoseConversation, !hasDraft, !hasUserMessages else { return }
        guard let last = store.latestPoki(), Date().timeIntervalSince(last.updated) < 12 * 3600 else { return }
        restore(last)
    }

    private var greeting: [ChatEntry] {
        [ChatEntry(.time(Date())),
         ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Hi, I’m Poki. Tell me what to do on this iPhone.")))),
         ChatEntry(.poki(app.asksBeforeSensitiveSteps ? AppLocalization.text(LocalizedStringResource("I’ll ask before anything you can’t undo."))
                         : AppLocalization.text(LocalizedStringResource("Payments, deletions, and Wallet actions always require your confirmation; other sensitive steps go ahead without asking."))))]
    }

    private var greetingIDs: [UUID] = []

    private func greet() {
        entries = greeting
        greetingIDs = entries.map(\.id)
    }

    /// Only the untouched, in-memory introduction is UI copy. Saved/user/model messages stay as
    /// written; changing language must not replace a conversation or its entries' identities.
    func languageChanged() {
        guard !running, !isSample, !greetingIDs.isEmpty, entries.map(\.id) == greetingIDs else { return }
        let translated = greeting
        for index in entries.indices.dropFirst() { entries[index].kind = translated[index].kind }
    }


    /// Asking was turned on or off: a conversation that holds only the greeting says what holds now.
    private func approvalsChanged() {
        guard !running, !isSample, !entries.contains(where: { if case .you = $0.kind { return true }; if case .request = $0.kind { return true }; return false }) else { return }
        greet()
    }

    /// Don’t Ask Again turned approvals off: one line in the chat, with the way back.
    private func approvalsStopped() {
        guard !isSample else { return }
        add(.poki(AppLocalization.text(LocalizedStringResource("Approvals are off. Turn them back on in [Settings › Approvals](poki://approvals)."))))
    }

    /// A live voice conversation that just ended, into this chat's history (and its saved session).
    func appendVoice(_ lines: [VoiceLine], started: Date) {
        entries.append(contentsOf: SessionStore.entries(voice: lines, started: started))
    }

    func newConversation() {
        userChoseConversation = true
        stop()
        if isDemo { entries = [ChatEntry(.time(Date()))] + greeting.dropFirst(); return }
        loop = nil
        client = nil
        restoredContext = nil
        calls = []
        planID = nil; noteID = nil; modelPlan = nil
        sessionID = UUID().uuidString.lowercased()
        greet()
    }

    private func applyRestoredSession(_ session: SavedSession) {
        userChoseConversation = true
        loop = nil
        client = nil
        planID = nil; noteID = nil; modelPlan = nil
        sessionID = session.id
        calls = session.calls
        restoredContext = session.modelContext
        entries = session.entries.isEmpty ? greeting : session.entries
    }

    /// Opens a saved in-app conversation again. The words come back; the model starts with what is on
    /// screen as context only from the next message on (pi's messages are not kept on disk).
    func restore(_ session: SavedSession) {
        guard session.kind == .poki, !running else { return }
        applyRestoredSession(session)
    }

    /// The conversation as the Sessions list keeps it. Greeting-only conversations are not saved.
    private func persist() {
        guard !isSample, hasUserMessages else { return }
        store.save(chat: self)
    }

    var savedCalls: [CallRecord] { calls }

    /// The first thing asked, for the Sessions row.
    var title: String {
        for entry in entries {
            switch entry.kind {
            case .you(let text, _), .request(let text, _): return text
            default: continue
            }
        }
        return AppLocalization.text(LocalizedStringResource("New conversation"))
    }

    // MARK: Sending

    func send(_ text: String, inSplitView: Bool = false) { send(text, again: false, inSplitView: inSplitView) }

    /// A message with photos or PDFs from the plus menu: the model reads their pictures with the words.
    /// The words may be left out.
    func send(_ text: String, attachments: [ChatAttachment]) {
        lastImages = attachments.flatMap(\.images)
        let documents = attachments.compactMap { attachment in
            attachment.textContent.map { ChatTextDocument(name: attachment.label, content: $0) }
        }
        send(text, again: false, thumbnails: attachments.filter { !$0.thumbnail.isEmpty }.map(\.thumbnail), documents: documents, chooseWorkspace: true)
    }

    /// The last message again, after a problem (the Retry button under it).
    func retry() {
        guard !running, let last = entries.last(where: { if case .you = $0.kind { return true }; return false }), case .you(let text, _) = last.kind else { return }
        while let tail = entries.last, case .note(.problem) = tail.kind { entries.removeLast() }
        send(text, again: true, documents: last.textDocuments ?? [], inSplitView: usesSplitView && expectedSplitViewApps == nil, chooseWorkspace: true)
    }

    /// The conversation ended on a problem the owner can try again.
    var canRetry: Bool {
        guard !running, let tail = entries.last, case .note(.problem) = tail.kind else { return false }
        return entries.contains { if case .you = $0.kind { return true }; return false }
    }

    /// What the model reads when the owner sent pictures without words.
    private static let picturesOnly = "(The owner sent the attached pictures without a message.)"
    /// The pictures of the owner's last message, sent again with it by Try Again.
    private var lastImages: [Data] = []

    /// Keep captions and file contents separate until the approval context is packed.
    var ownerContext: [ApprovalClassifier.ContextTurn] {
        entries.suffix(30).compactMap { entry in
            switch entry.kind {
            case .you(let text, _):
                .init(text: "Owner: \(text)", documents: entry.textDocuments ?? [])
            case .request(let text, let from):
                .init(text: "Request from \(from): \(text)", documents: entry.textDocuments ?? [])
            case .poki(let text):
                .init(text: "Assistant: \(String(text.prefix(400)))")
            default: nil
            }
        }
    }

    private struct PreparedSend {
        enum Engine {
            case direct(ModelClient, String)
            case pi(Model)
        }
        let text: String
        let you: ChatEntry
        let message: String
        let runSession: String
        let provider: ModelProvider
        let model: String
        let resumedTask: String?
        let inSplitView: Bool
        let images: [Data]
        let namedApps: [String]
        let engine: Engine
    }

    private func send(_ text: String, again: Bool, thumbnails: [Data] = [], documents: [ChatTextDocument] = [], inSplitView: Bool = false, chooseWorkspace: Bool = false) {
        if let message = app.signer.installMessage {
            add(.note(.problem(message)))
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pictures may go without words, and Try Again sends them again.
        guard !text.isEmpty || !documents.isEmpty || !thumbnails.isEmpty || (again && !lastImages.isEmpty), !running else { return }
        if isDemo { playDemo(text); return }
        // Another conversation (an outside agent's hand-off) is working the phone: one task at a time.
        if kind == .poki, let busy = ChatModel.delegatedBusy {
            var entry = ChatEntry(.you(text, delivered: false))
            if !documents.isEmpty { entry.textDocuments = documents }
            entries.append(entry)
            add(.note(.problem(AppLocalization.text(LocalizedStringResource("Poki is working on a task for \(busy). Try again when it’s done.")))))
            return
        }
        let isContinuation = kind == .poki && thumbnails.isEmpty && lastImages.isEmpty
            && (ChatContinuation.isRequest(text) || entries.last?.continuationChoices != nil)
        if kind == .poki, !store.isInitialReady || (isContinuation && !store.isLoaded) {
            running = true
            awaitingModel = true
            stopAsked = false
            runToken += 1
            let token = runToken
            let previous = task
            let capturedImages = lastImages
            task = Task { [weak self] in
                await previous?.value
                guard let self, !Task.isCancelled, self.runToken == token else { return }
                if !self.store.isInitialReady {
                    await self.store.waitUntilInitialReady()
                    guard !Task.isCancelled, self.runToken == token else { return }
                    if !again, !self.userChoseConversation, !self.hasUserMessages,
                       let last = self.store.latestPoki(), Date().timeIntervalSince(last.updated) < 12 * 3600 {
                        self.applyRestoredSession(last)
                    }
                }
                if isContinuation, !self.store.isLoaded {
                    await self.store.waitUntilLoaded()
                    guard !Task.isCancelled, self.runToken == token else { return }
                }
                self.lastImages = capturedImages
                guard let prepared = self.prepareSend(text, again: again, thumbnails: thumbnails, documents: documents,
                                                      inSplitView: inSplitView, chooseWorkspace: chooseWorkspace) else {
                    self.running = false
                    self.awaitingModel = false
                    return
                }
                await self.executePreparedSend(prepared, token: token)
            }
            return
        }
        guard let prepared = prepareSend(text, again: again, thumbnails: thumbnails, documents: documents,
                                         inSplitView: inSplitView, chooseWorkspace: chooseWorkspace) else { return }
        running = true
        awaitingModel = true
        stopAsked = false
        runToken += 1
        let token = runToken
        let previous = task
        task = Task { [weak self] in
            // A stopped task may still be ending its last step: this one starts after it.
            await previous?.value
            guard let self, self.runToken == token else { return }
            await self.executePreparedSend(prepared, token: token)
        }
    }

    private func prepareSend(_ text: String, again: Bool, thumbnails: [Data], documents: [ChatTextDocument],
                             inSplitView: Bool, chooseWorkspace: Bool) -> PreparedSend? {
        var resumedTask: String?
        if kind == .poki, thumbnails.isEmpty, lastImages.isEmpty {
            switch ChatContinuation.resolve(text, current: sessionID, choices: entries.last?.continuationChoices,
                                            sessions: store.sessions) {
            case .newTask: break
            case .resume(let session):
                resumedTask = session.continuationTask
                if session.id != sessionID { applyRestoredSession(session) }
            case .clarify(let sessions):
                entries.append(ChatEntry(.you(text, delivered: true)))
                let question = AppLocalization.text(LocalizedStringResource("Which task would you like to continue?"))
                let explanation: String
                if sessions.isEmpty {
                    explanation = AppLocalization.text(LocalizedStringResource("I couldn't find a matching task. Tell me what you wanted to do and where it stopped."))
                } else {
                    explanation = AppLocalization.text(LocalizedStringResource("Here are your recent tasks. Reply with a number or the task's name."))
                }
                let options = sessions.enumerated().map {
                    "\($0.offset + 1). \(String(($0.element.continuationTask ?? $0.element.title).prefix(160)))"
                }.joined(separator: "\n")
                var reply = ChatEntry(.poki([question, explanation, options].filter { !$0.isEmpty }.joined(separator: "\n\n")))
                reply.continuationChoices = sessions.map(\.id)
                entries.append(reply)
                return nil
            }
        }
        // A pause of half an hour or more gets its own time line, as in Messages.
        if !again, let lastAt = entries.last?.at, Date().timeIntervalSince(lastAt) > 1800 { entries.append(ChatEntry(.time(Date()))) }
        let you: ChatEntry
        if again, let last = entries.last(where: { if case .you = $0.kind { return true }; return false }) {
            you = last
        } else {
            var entry = ChatEntry(kind == .handoff ? .request(text, from: requester ?? "") : .you(text, delivered: false))
            entry.continuedTask = resumedTask
            if !thumbnails.isEmpty { entry.attachments = thumbnails } else { lastImages = [] }
            if !documents.isEmpty { entry.textDocuments = documents }
            you = entry
            entries.append(you)
        }
        let message = you.requestText
        usesSplitView = inSplitView
        splitViewSession = inSplitView ? UUID().uuidString : nil
        expectedSplitViewApps = nil
        hasSplitViewRead = false
        lastSplitViewSide = nil
        lastSplitViewLayout = nil
        waitingForSplitView = false
        if kind == .poki { Haptics.sent() }
        let provider = ModelKeys.selectedProvider
        guard provider.wired, let key = ModelKeys.key(provider) ?? (provider == .custom && ModelKeys.hasUsableKey ? "none" : nil) else {
            add(.poki(provider.signsIn ? AppLocalization.text(LocalizedStringResource("Sign in to ChatGPT first. Open Settings, then Models."))
                                       : AppLocalization.text(LocalizedStringResource("Add a model key first. Open Settings, then Models."))))
            return nil
        }
        let runSession = sessionID
        let model = ModelKeys.selectedModel
        // The first message names the chat: a few words from the chat's own model, in the background.
        if kind == .poki, !again, entries.filter({ if case .you = $0.kind { return true }; return false }).count == 1,
           let piModel = provider.piModel(model) {
            let id = sessionID
            let store = self.store
            Task { if let name = await SessionNamer.name(for: message, provider: provider, model: piModel) { store.setAutoName(id, name) } }
        }
        planID = nil; noteID = nil; modelPlan = nil
        taskApp = nil
        taskApps = TaskApps(); taskRequest = resumedTask ?? text; toolRoute = nil
        let continuation = resumedTask.map { "The owner selected this saved task to resume: \($0). Recheck the current screen and continue from the saved progress; do not substitute a task from long-term memory." }
        let images = lastImages
        let namedApps = chooseWorkspace && kind == .poki && app.canPlanSplitView
            ? AppIconStore.bundleIDs(namedIn: text) : []
        if !inSplitView, namedApps.count < 2, Self.direct, provider == .anthropic || provider == .openai {
            let instructions = [Harness.instructions(for: resumedTask ?? text), restoredContext, continuation].compactMap { $0 }.joined(separator: "\n\n")
            // Another model starts a new conversation on the model's side; the chat on screen stays.
            if client?.signature != "\(provider.rawValue)/\(model)" {
                client = provider == .openai ? OpenAIClient(key: key, model: model) : AnthropicClient(key: key, model: model)
            }
            guard let client else { return nil }
            return PreparedSend(text: text, you: you, message: message, runSession: runSession, provider: provider, model: model,
                                resumedTask: resumedTask, inSplitView: inSplitView, images: images, namedApps: namedApps,
                                engine: .direct(client, instructions))
        }
        guard let piModel = provider.piModel(model) else {
            add(.note(.problem(AppLocalization.text(LocalizedStringResource("pi has no model \(model) for \(provider.name).")))))
            return nil
        }
        return PreparedSend(text: text, you: you, message: message, runSession: runSession, provider: provider, model: model,
                            resumedTask: resumedTask, inSplitView: inSplitView, images: images, namedApps: namedApps,
                            engine: .pi(piModel))
    }

    private func executePreparedSend(_ prepared: PreparedSend, token: Int) async {
        switch prepared.engine {
        case .direct(let client, let instructions):
            client.say(prepared.message)
            began("direct", prepared.provider, prepared.model)
            await run(client, instructions: instructions, delivered: prepared.you.id, token: token)
            let current = runToken == token
            if !current { app.finishTask() }
            logEnd("direct", outcome: nil, session: prepared.runSession, text: prepared.text, stopped: !current)
            if current { running = false; awaitingModel = false }
        case .pi(let piModel):
            var pair: [String] = []
            if !prepared.inSplitView, prepared.namedApps.count >= 2 {
                let plannedAt = ContinuousClock.now
                let choice = await chooseSplitView(text: prepared.text, apps: prepared.namedApps, provider: prepared.provider, model: piModel)
                guard runToken == token else { return }
                AppLog.shared.add("chat", "workspace planning took \(plannedAt.duration(to: .now))")
                switch choice {
                case .split(let apps):
                    pair = apps
                    usesSplitView = true
                    splitViewSession = UUID().uuidString
                    expectedSplitViewApps = Set(apps)
                    AppLog.shared.add("chat", "workspace planning selected Split View")
                case .normal:
                    AppLog.shared.add("chat", "workspace planning selected normal chat")
                case .failed(let words):
                    AppLog.shared.add("chat", "workspace planning failed before any phone action")
                    add(.note(.problem(words)))
                    running = false
                    awaitingModel = false
                    lastOutcome = .failed(words)
                    return
                }
            }
            let splitSession = splitViewSession
            began("pi", prepared.provider, prepared.model, splitViewSession: splitSession)
            if let splitSession, pair.count == 2 {
                phoneStepUnderWay = true
                let confirmed = await openSplitViewPair(pair, session: splitSession, token: token)
                phoneStepUnderWay = false
                guard runToken == token, confirmed else {
                    await app.finishSplitViewTask(localSession: splitSession, pairConfirmed: false) {
                        self.runToken != token || Task.isCancelled
                    }
                    if runToken == token {
                        AppLog.shared.add("chat", "workspace planning could not confirm the requested Split View apps")
                        let words = Self.splitViewSetupMessage(pair[0], pair[1])
                        let outcome = PiLoop.Outcome.failed(words)
                        ended(outcome, delivered: prepared.you.id)
                        logEnd("pi", outcome: outcome, session: prepared.runSession, text: prepared.text, stopped: false)
                        running = false
                        awaitingModel = false
                        lastOutcome = outcome
                    }
                    return
                }
                AppLog.shared.add("chat", "workspace planning confirmed the requested Split View apps")
            }
            let loop = modelLoop(provider: prepared.provider, model: piModel, inSplitView: splitSession != nil)
            let continuation = prepared.resumedTask.map { "The owner selected this saved task to resume: \($0). Recheck the current screen and continue from the saved progress; do not substitute a task from long-term memory." }
            let instructions = [Harness.instructions(for: prepared.resumedTask ?? prepared.message, inSplitView: splitSession != nil), restoredContext, continuation].compactMap { $0 }.joined(separator: "\n\n")
            let outcome = await loop.run(prepared.message.isEmpty ? Self.picturesOnly : prepared.message, images: prepared.images, instructions: instructions, maxTurns: Self.maxTurns) { [weak self] text in
                guard let self, self.runToken == token else { return }
                self.markDelivered(prepared.you.id)
                self.awaitingModel = false
                self.add(.poki(text))
            }
            if let splitSession {
                await app.finishSplitViewTask(localSession: splitSession) {
                    self.runToken != token || Task.isCancelled || outcome == .stopped
                }
            }
            let current = runToken == token
            if current { ended(outcome, delivered: prepared.you.id) } else if splitSession == nil { app.finishTask() }
            logEnd("pi", outcome: outcome, session: prepared.runSession, text: prepared.text, stopped: !current)
            guard current else { return }
            running = false
            awaitingModel = false
            lastOutcome = outcome
        }
    }

    private enum WorkspaceChoice { case split([String]), normal, failed(String) }

    private enum PairCheck { case confirmed, unavailable, differentPair, stopped }

    private func openSplitViewPair(_ pair: [String], session: String, token: Int) async -> Bool {
        guard await app.reserveSplitViewWorkspace(session: session), !Task.isCancelled else { return false }
        let currentTask = task
        let background = UIApplication.shared.beginBackgroundTask(withName: "Open Poki Split View") { currentTask?.cancel() }
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let expected = Set(pair)
        // Opening one member can restore an existing pair. Anchor a new workspace with the
        // destination, then open the source beside it, preserving the destination's last window.
        let anchor = pair[1]
        let source = pair[0]
        await activateForSplitView(anchor, session: session)
        switch await confirmSplitViewPair(expected, session: session, token: token, seconds: 12) {
        case .confirmed: return true
        case .stopped: return false
        case .unavailable, .differentPair: break
        }
        guard runToken == token, !Task.isCancelled, let target = KnownApps.find(anchor) else { return false }
        guard await app.clearSplitViewPaneForSetup(session: session), runToken == token, !Task.isCancelled else { return false }
        AppLog.shared.add("chat", "opening the requested apps through the system Split View menu")
        await activateForSplitView("com.apple.springboard", session: session)
        do {
            guard try await selectLauncherItem([target.english, target.simplified, target.traditional], menu: false, session: session) else { return false }
            guard try await selectLauncherItem(["Open in Split View", "以分屏浏览打开", "以分割顯示方式打開", "以分割顯示打開"], menu: true, session: session) else { return false }
            try await Task.sleep(for: .seconds(1))
        } catch { return false }
        guard runToken == token, !Task.isCancelled else { return false }
        await activateForSplitView(source, session: session)
        return await confirmSplitViewPair(expected, session: session, token: token, seconds: 35) == .confirmed
    }

    private func activateForSplitView(_ bundle: String, session: String) async {
        let request: JSON = ["actions": [["launch": .string(bundle)]]]
        _ = await app.runTool("do", arguments: request.serialized(), localSession: session)
    }

    private func selectLauncherItem(_ labels: [String], menu: Bool, session: String) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        repeat {
            try Task.checkCancellation()
            do {
                if try await app.openSplitViewLauncherItem(labels: labels, menu: menu, session: session) { return true }
            } catch let error as RunnerError where error.delivery == .notSent && error.message.contains("nothing lands late") {
                // The earlier system activation is still draining. This step sent no input.
            }
            try await Task.sleep(for: .milliseconds(550))
        } while ContinuousClock.now < deadline
        return false
    }

    private func confirmSplitViewPair(_ pair: Set<String>, session: String, token: Int, seconds: Int) async -> PairCheck {
        let deadline = ContinuousClock.now + .seconds(seconds)
        var pane = "left"
        while runToken == token, !Task.isCancelled, ContinuousClock.now < deadline {
            let read = await app.runTool("look", arguments: "{\"pane\":\"\(pane)\"}", localSession: session, expectedApps: pair)
            if read.text.contains("screen: locked") { return .stopped }
            if read.text.contains("do not match the planned Split View pair") { return .differentPair }
            // Keep the initial layout so a rotation before the model's first read also triggers recovery.
            if !read.isError, read.jpeg != nil, let observed = read.splitView {
                lastSplitViewSide = observed.side
                lastSplitViewLayout = observed.layout
                return .confirmed
            }
            // Either pane verifies both app identities. Try the other if the first cannot be read.
            pane = pane == "left" ? "right" : "left"
            try? await Task.sleep(for: .seconds(1))
        }
        return Task.isCancelled || runToken != token ? .stopped : .unavailable
    }

    private func chooseSplitView(text: String, apps: [String], provider: ModelProvider, model: Model) async -> WorkspaceChoice {
        let names = apps.enumerated().map { "\($0.offset + 1). \(AppIconStore.name($0.element) ?? $0.element)" }.joined(separator: "\n")
        let instructions = "Choose whether two candidate iPhone apps should work side by side for the owner's request. A word may describe an item and just happen to match an app name (for example 写一封邮件 can describe a message, or 照片 can mean an image in Safari). Select only the two apps actually requested. For a side-by-side task such as dragging, comparing, or transferring between two apps, output SPLIT followed by their two numbers separated by spaces, source first if there is a source. Otherwise output NORMAL. Output only that line."
        let planner = PiLoop(provider: provider, model: model, tools: []) { _ in
            PokiCore.ToolAnswer(text: "Planning only.", jpeg: nil, isError: true)
        }
        var answer = ""
        let outcome = await withTaskCancellationHandler {
            await planner.run("Apps: \(names)\nRequest: \(text)", instructions: instructions, maxTurns: 1) { answer += $0 }
        } onCancel: {
            Task { @MainActor in planner.stop() }
        }
        if case .failed(let words) = outcome { return .failed(words) }
        let words = answer.split(whereSeparator: \.isWhitespace)
        if outcome == .done {
            if words == ["NORMAL"] { return .normal }
            if words.count == 3, words[0] == "SPLIT", let first = Int(words[1]), let second = Int(words[2]),
               first != second, (1...apps.count).contains(first), (1...apps.count).contains(second) {
                return .split([apps[first - 1], apps[second - 1]])
            }
        }
        return .failed(Self.splitViewPlanningMessage)
    }

    static func splitViewSetupMessage(_ source: String, _ destination: String) -> String {
        let sourceName = AppName.display(source) ?? source
        let destinationName = AppName.display(destination) ?? destination
        return AppLocalization.text(LocalizedStringResource("Open \(sourceName) and \(destinationName) together on the unfolded iPhone, then return to Poki and retry. Pair them with the divider to open them together next time."))
    }

    static var splitViewPlanningMessage: String {
        AppLocalization.text(LocalizedStringResource("Poki couldn't determine whether to use Split View. Try sending the task again."))
    }

    private func modelLoop(provider: ModelProvider, model: Model, inSplitView: Bool) -> PiLoop {
        let changedWorkspace = loop.map { $0.inSplitView != inSplitView } ?? false
        if let loop, loop.provider == provider, loop.model.id == model.id,
           loop.model.baseUrl == model.baseUrl, !changedWorkspace { return loop }
        // A different workspace starts without old screen evidence.
        let next = PiLoop(provider: provider, model: model, tools: inSplitView ? Harness.splitViewTools : Harness.tools,
                          inSplitView: inSplitView, carrying: changedWorkspace ? [] : loop?.messages ?? []) { [weak self] call in
            guard let self else { return PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true) }
            return await self.perform(call)
        }
        loop = next
        return next
    }

    /// Every provider runs on pi. `-chatEngine direct` sends Anthropic and OpenAI through their own APIs
    /// instead; that code goes once the phone acceptance with the owner's OpenAI key has passed on pi.
    private static var direct: Bool { UserDefaults.standard.string(forKey: "chatEngine") == "direct" }

    private func began(_ engine: String, _ provider: ModelProvider, _ model: String, splitViewSession: String? = nil) {
        taskStart = Date(); toolCalls = 0; taskResult = nil
        taskCalls.removeAll()
        app.prepareForTask()
        app.chatTaskBegan(splitViewSession: splitViewSession)
        AppLog.shared.add("chat", "task started: \(engine), \(provider.rawValue)/\(model)")
    }

    private func logEnd(_ engine: String, outcome: PiLoop.Outcome?, session: String, text: String, stopped: Bool) {
        let stopAsked = stopped || self.stopAsked
        let seconds = String(format: "%.1f", Date().timeIntervalSince(taskStart))
        let verdict = taskResult.map { $0.success ? "success" : "failure" } ?? "not called"
        let ending = outcome.map { if case .failed = $0 { "failed" } else { "\($0)" } } ?? (stopAsked ? "stopped" : "ended")
        AppLog.shared.add("chat", "task ended: \(engine), \(ending) after \(seconds) s, \(toolCalls) tool calls, finish_task \(verdict)")
        let record = TaskRecord(session: session, task: text, calls: taskCalls, result: taskResult,
                                seconds: Date().timeIntervalSince(taskStart))
        Self.afterTask?(record)
        store.taskEnded(session, success: taskResult?.success, stopped: stopAsked)
        if kind == .poki, taskResult?.success == true { Haptics.done() }
    }

    private var lastOutcome: PiLoop.Outcome?

    /// Runs a task an outside agent handed over (`ask_poki`) and answers with Poki's last words, how the
    /// task ended, and finish_task's summary and answer.
    func runDelegated(_ task: String) async -> (text: String, success: Bool?) {
        if let message = app.signer.installMessage { return (message, false) }
        guard !Task.isCancelled else { return ("Poki's task was cancelled.", false) }
        guard !running, ChatModel.delegatedBusy == nil else { return ("Poki is already running a task.", false) }
        ChatModel.delegatedBusy = requester ?? AppLocalization.text(LocalizedStringResource("an agent"))
        defer { ChatModel.delegatedBusy = nil }
        lastOutcome = nil
        send(task)
        if running, let started = self.task {
            let token = runToken
            await withTaskCancellationHandler {
                await started.value
            } onCancel: {
                Task { @MainActor in
                    guard self.runToken == token, self.running else { return }
                    self.stop()
                }
            }
            if Task.isCancelled {
                return ("Stopped. Poki's task was cancelled.", false)
            }
        }
        let replies = entries.compactMap { entry -> String? in if case .poki(let text) = entry.kind { return text }; return nil }
        var lines: [String] = []
        if let taskResult {
            lines.append("result: \(taskResult.success ? "done" : "not done"): \(taskResult.summary)")
            if let answer = taskResult.answerLine { lines.append(answer) }
        }
        if let last = replies.last { lines.append("Poki said: \(last)") }
        if case .failed(let why)? = lastOutcome { lines.append("error: \(why)") }
        if lastOutcome == nil, let tail = entries.last, case .note(.problem(let why)) = tail.kind { lines.append("error: \(why)") }
        if lines.isEmpty { lines.append("Poki ended without an answer.") }
        return (lines.joined(separator: "\n"), taskResult?.success)
    }

    /// The display name of the agent whose hand-off is running, while one runs.
    static var delegatedBusy: String?

    private func ended(_ outcome: PiLoop.Outcome, delivered youID: UUID) {
        finishPlan()
        // The turn is over: the phone goes back to the app the task began in (Poki's chat, where the
        // reply is), or stays where it is and the reply goes out as a notification that can be answered
        // there (Advanced › When a Task Ends).
        var reply: String?
        switch outcome {
        case .done:
            markDelivered(youID)
            reply = entries.reversed().lazy.compactMap { entry -> String? in if case .poki(let text) = entry.kind { return text }; return nil }.first
        case .stopped: add(.poki(AppLocalization.text(LocalizedStringResource("Stopped."))))
        case .overTurns:
            reply = AppLocalization.text(LocalizedStringResource("I stopped after \(Self.maxTurns) steps. Tell me how to go on."))
            add(.poki(reply ?? ""))
        case .stuck:
            reply = stuckWords()
            add(.poki(reply ?? ""))
        case .failed(let words):
            reply = words
            add(.note(.problem(words)))
        }
        if case .stopped = outcome {
            if !usesSplitView { app.finishTask() }
        } else {
            app.chatTaskEnded(reply: reply, session: sessionID, acted: toolCalls > 0, inSplitView: usesSplitView)
        }
    }

    /// Where the task is stuck: the app it was working in, when it is one Poki can name.
    private func stuckWords() -> String {
        guard let name = AppName.display(taskApp) else {
            return AppLocalization.text(LocalizedStringResource("I’m stuck on the same screen. Tell me how to go on."))
        }
        return AppLocalization.text(LocalizedStringResource("I’m stuck on the same screen in \(name). Tell me how to go on."))
    }

    /// Ends the task now, as far as the chat goes: it takes the next message at once, and nothing more
    /// is sent to the model or the phone. A step under way stops before its next action; the action
    /// the phone is doing finishes, and until then the chat says Stopping, not Stopped. The next task
    /// waits for it.
    func stop() {
        if isDemo { stopDemo(); return }
        guard running else { return }
        stopAsked = true
        waitingForSplitView = false
        loop?.stop()
        task?.cancel()
        // A browser step waiting for a page or for the owner ends too.
        PokiBrowser.shared.taskStopped()
        // A step waiting for an approval would hold the task until the approval ran out.
        if kind == .poki, ChatModel.delegatedBusy == nil { for approval in app.approvals { app.resolve(approval, approved: false) } }
        finishPlan()
        runToken += 1
        running = false
        awaitingModel = false
        guard phoneStepUnderWay else { add(.poki(AppLocalization.text(LocalizedStringResource("Stopped.")))); return }
        let stopping = ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Stopping…"))))
        entries.append(stopping)
        let session = sessionID
        let stopped = task
        Task { [weak self] in
            await stopped?.value
            _ = await self?.app.phoneSettles(within: 30)
            let text = AppLocalization.text(LocalizedStringResource("Stopped."))
            guard let self, self.sessionID == session else {
                self?.store.finishStopping(stopping.id, in: session, text: text)
                return
            }
            guard let i = self.entries.firstIndex(where: { $0.id == stopping.id }) else { return }
            self.entries[i].kind = .poki(text)
            self.persist()
        }
    }

    /// A look or do of this chat is on its way to the phone.
    private var phoneStepUnderWay = false

    private func run(_ client: ModelClient, instructions: String, delivered youID: UUID, token: Int) async {
        // Stop has moved the token on (and said Stopped): this task writes nothing more.
        var stopped: Bool { runToken != token || Task.isCancelled }
        for _ in 0..<Self.maxTurns {
            let turn: ModelTurn
            do {
                turn = try await client.next(instructions: instructions, tools: Harness.tools)
            } catch {
                client.forgetUnansweredQuestion()
                if stopped { return }
                add(.note(.problem(error.localizedDescription)))
                return
            }
            if stopped { client.forgetUnansweredQuestion(); return }
            markDelivered(youID)
            for text in turn.texts { add(.poki(text)) }
            switch turn.ending {
            case .tools:
                for call in turn.calls {
                    if stopped {
                        client.answer(call, PokiCore.ToolAnswer(text: "Task stopped. Action not executed.", jpeg: nil, isError: true))
                        continue
                    }
                    client.answer(call, await perform(call))
                }
                if stopped { return }
            case .again:
                continue
            case .refused:
                finishPlan()
                add(.poki(AppLocalization.text(LocalizedStringResource("The model declined this request."))))
                return
            case .cutOff:
                finishPlan()
                add(.note(.problem(AppLocalization.text(LocalizedStringResource("The answer was cut off.")))))
                return
            case .done:
                // A reply without tools ends the turn, as a chat does: the model may be asking the owner something.
                finishPlan()
                return
            }
        }
        finishPlan()
        add(.poki(AppLocalization.text(LocalizedStringResource("I stopped after \(Self.maxTurns) steps. Tell me how to go on."))))
    }

    /// The phone's tools go to PokiCore; the harness's two are answered here, as task-runner.mjs answers them.
    private func perform(_ call: ToolCall) async -> PokiCore.ToolAnswer {
        let session = sessionID
        let token = runToken
        awaitingModel = false
        let started = Date()
        let answer = await performCall(call)
        let record = CallRecord(name: call.name, arguments: call.arguments, answer: String(answer.text.prefix(2000)), ms: Int(Date().timeIntervalSince(started) * 1000), ok: !answer.isError)
        taskCalls.append(record)
        guard sessionID == session else {
            store.appendCall(record, to: session)
            return answer
        }
        // A launch that went through says which app the task is for; a refused one says nothing.
        if runToken == token, call.name == "do", !answer.isError {
            for app in TaskApps.launches(inArguments: call.arguments) { taskApps.launch(app) }
            taskApp = taskApps.target(request: taskRequest)
        }
        calls.append(record)
        if runToken == token, !stopAsked, running { awaitingModel = true }
        persist()
        return answer
    }

    private func performCall(_ call: ToolCall) async -> PokiCore.ToolAnswer {
        toolCalls += 1
        let args = (call.arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        if usesSplitView {
            switch call.name {
            case "look":
                if let pane = args["pane"] as? String {
                    hasSplitViewRead = false
                    guard pane == "left" || pane == "right" else {
                        return splitViewRefusal("Choose left or right with look. This task keeps both apps in Split View.")
                    }
                } else if !hasSplitViewRead {
                    return splitViewRefusal("Use look with pane left or right to confirm the two visible apps first.")
                }
            case "do":
                guard hasSplitViewRead else {
                    return splitViewRefusal("Use look with pane left or right to confirm the two visible apps first.")
                }
                let actions = args["actions"] as? [[String: Any]] ?? []
                if args["finish"] as? Bool == true || actions.contains(where: { $0["launch"] != nil || $0["run"] != nil || $0["button"] != nil }) {
                    return splitViewRefusal("Keep both apps in place. Do not launch apps, use hardware buttons, or run routines. Finish with finish_task.")
                }
            case "report_plan", "finish_task", "status": break
            default:
                return splitViewRefusal("Use the two visible apps with look and do for this task.")
            }
        }
        switch call.name {
        case "report_plan":
            guard let steps = args["steps"] as? [String], (1...8).contains(steps.count), let current = args["currentStep"] as? Int, (1...steps.count).contains(current) else {
                return PokiCore.ToolAnswer(text: Harness.invalidPlan, jpeg: nil, isError: true)
            }
            let title = Self.shortTitle(args["title"]), to = Self.shortTitle(args["to"])
            showPlan(steps, current: current, title: title, to: to)
            if let title { nameTask(title) }
            return PokiCore.ToolAnswer(text: Harness.planPublished, jpeg: nil, isError: false)
        case "finish_task":
            guard let result = try? JSONDecoder().decode(TaskResult.self, from: Data(call.arguments.utf8)) else {
                return PokiCore.ToolAnswer(text: Harness.invalidResult, jpeg: nil, isError: true)
            }
            taskResult = result
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .current || steps[i].state == .waiting { steps[i].state = result.success ? .done : .failed }
            }
            return PokiCore.ToolAnswer(text: Harness.resultRecorded, jpeg: nil, isError: false)
        case let name where WebTools.names.contains(name):
            if let refusal = selectRoute(.web) { return refusal }
            showBrowser(opening: name == "web_open")
            return await WebTools.perform(name, arguments: call.arguments)
        case "look", "do":
            if let refusal = selectRoute(.app) { return refusal }
            phoneStepUnderWay = true
            defer { phoneStepUnderWay = false }
            let taskToken = runToken
            let response = await app.runTool(call.name, arguments: call.arguments, localSession: splitViewSession, expectedApps: expectedSplitViewApps)
            guard taskToken == runToken, usesSplitView else { return response }
            let changedLayout = call.name == "look" && lastSplitViewLayout != nil &&
                response.splitView.map { $0.layout != lastSplitViewLayout } == true
            if let previous = lastSplitViewSide, response.splitViewNeedsRead || changedLayout {
                hasSplitViewRead = false
                let side = (args["pane"] as? String) ?? previous
                return await recoverSplitView(side: side, token: taskToken,
                                              layoutSeen: changedLayout,
                                              action: call.name == "do" ? response : nil)
            }
            if call.name == "look", let read = response.splitView, response.jpeg != nil {
                recordSplitViewRead(read)
            }
            return response
        default:
            return await app.runTool(call.name, arguments: call.arguments)
        }
    }

    private func recordSplitViewRead(_ read: PokiCore.SplitViewRead) {
        hasSplitViewRead = true
        lastSplitViewSide = read.side
        lastSplitViewLayout = read.layout
        if expectedSplitViewApps == nil { expectedSplitViewApps = Set([read.app, read.otherApp]) }
    }

    /// Keep the model call suspended while the owner restores the workspace. Every retry only reads.
    private func recoverSplitView(side: String, token: Int, layoutSeen: Bool,
                                  action: PokiCore.ToolAnswer?) async -> PokiCore.ToolAnswer {
        waitingForSplitView = true
        app.chatWaitingForSplitView(true)
        AppLog.shared.add("chat", "Split View changed; waiting to read the workspace again")
        defer {
            if runToken == token {
                waitingForSplitView = false
                app.chatWaitingForSplitView(false)
            }
        }
        let session = splitViewSession
        let expected = expectedSplitViewApps
        let otherSide = side == "left" ? "right" : "left"
        var otherRead: PokiCore.SplitViewRead?
        var wait = layoutSeen ? Duration.milliseconds(350) : .seconds(2)
        while runToken == token, !Task.isCancelled {
            do { try await Task.sleep(for: wait) } catch { break }
            guard runToken == token, !Task.isCancelled else { break }
            // End on the pane expected by the original call, so the model's next action uses
            // the same side as the fresh screenshot it receives here.
            let pane = otherRead == nil ? otherSide : side
            let read = await app.runTool("look", arguments: #"{"pane":"\#(pane)","full":true}"#,
                                         localSession: session, expectedApps: expected)
            guard runToken == token, !Task.isCancelled else { break }
            guard !read.isError, read.jpeg != nil, let observed = read.splitView, observed.side == pane else {
                otherRead = nil
                wait = .seconds(2)
                app.chatWaitingForSplitView(true)
                continue
            }
            if pane == otherSide {
                otherRead = observed
                wait = .milliseconds(350)
                continue
            }
            guard let otherRead, otherRead.layout == observed.layout,
                  otherRead.app == observed.otherApp, otherRead.otherApp == observed.app else {
                otherRead = nil
                continue
            }
            recordSplitViewRead(observed)
            AppLog.shared.add("chat", "Split View restored; the model received a fresh pane read")
            let previous = action.map { "\nPrevious action result. Check what actually happened before attempting any remaining step.\n\($0.text)\n" } ?? ""
            return PokiCore.ToolAnswer(text: "Split View was restored. Replan the remaining steps from the fresh layout. Old coordinates, element numbers, and pending gestures are invalid.\n\(previous)\n\(read.text)",
                                       jpeg: read.jpeg, isError: action != nil, splitView: observed)
        }
        return splitViewRefusal("Task stopped while waiting for Split View.")
    }

    private func splitViewRefusal(_ message: String) -> PokiCore.ToolAnswer {
        PokiCore.ToolAnswer(text: "not_sent: " + message, jpeg: nil, isError: true)
    }

    private func selectRoute(_ next: ToolRoute) -> PokiCore.ToolAnswer? {
        let hasExplicitApp = !AppIconStore.bundleIDs(namedIn: taskRequest).isEmpty
        let mixed = hasExplicitApp && (modelPlan?.count ?? 0) > 1
        if let toolRoute, toolRoute != next, !mixed {
            let text = toolRoute == .web
                ? "This task is using the sandbox browser. Phone controls were not started. Continue with web tools, or stop and ask the owner if a separate app task is needed."
                : "This task is using phone controls. The sandbox browser was not opened. Continue in the requested app, or stop and ask the owner if a separate website task is needed."
            return PokiCore.ToolAnswer(text: text, jpeg: nil, isError: true)
        }
        toolRoute = next
        return nil
    }

    /// The bubble shows the model's steps up to the current one: those before it done, it under way. A step
    /// appears when the model reaches it, as the board draws them.
    private func showPlan(_ plan: [String], current: Int, title: String?, to: String?) {
        modelPlan = plan
        app.chatPlan(steps: plan, current: current, title: title, to: to)
        updatePlan { steps in
            if steps.count > current { steps.removeLast(steps.count - current) }
            for i in 0..<current {
                let state: PlanStep.State = i < current - 1 ? .done : (steps.indices.contains(i) && steps[i].state == .waiting ? .waiting : .current)
                if steps.indices.contains(i) { steps[i].text = plan[i]; steps[i].state = state } else { steps.append(PlanStep(plan[i], state: state)) }
            }
        }
    }

    /// The model's name for the task, kept on the task's plan entry: the card's title.
    private func nameTask(_ title: String) {
        guard let id = planID, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].title = title
    }

    /// A title is a few words on one line. A sentence is not one (over 40 characters): the card
    /// keeps what was asked.
    static func shortTitle(_ value: Any?) -> String? {
        guard let line = (value as? String)?.split(whereSeparator: \.isNewline).first else { return nil }
        let title = line.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title.count > 40 ? nil : title
    }

    // MARK: Steps and approvals from PokiCore

    private func observe(_ event: ShellEvent) {
        guard running else { return }
        switch event {
        case .toolStarted(let name, let summary, let session):
            guard session == nil else { return }
            guard name == "do", modelPlan == nil else { return }
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .current { steps[i].state = .done }
                steps.append(PlanStep(ActivityWords.label(summary)))
            }
        case .toolFinished(let summary, let delivery, let stepApp, _, _, let session):
            guard session == nil else { return }
            if summary != "Look at the screen" {
                taskApps.step(in: stepApp)
                taskApp = taskApps.target(request: taskRequest)
            }
            guard summary != "Look at the screen", modelPlan == nil else { return }
            let failed = delivery.hasPrefix("failed")
            let waiting = delivery.contains("approval_required")
            updatePlan { steps in
                guard let i = steps.lastIndex(where: { $0.state == .current || $0.state == .waiting }) else { return }
                steps[i].state = failed ? .failed : waiting ? .current : .done
            }
        case .approvalRequested(let approval):
            updatePlan { steps in
                if let i = steps.lastIndex(where: { $0.state == .current }) {
                    steps[i].state = .waiting
                } else {
                    steps.append(PlanStep(approval.summary, state: .waiting))
                }
            }
            let route = ApprovalClassifier.route(approval, voiceOn: app.voice.isOn)
            // Asking is off: the step goes straight through, with nothing to show.
            guard route != .allow else { break }
            // Each approval has its own card: it stays in the conversation with its answer.
            noteID = nil
            asked = ApprovalNote(id: approval.id, summary: approval.summary, app: approval.app, why: approval.reason,
                                 byModel: route != .owner, state: .asking)
            setNote(.approval(asked!))
        case .approvalEnded(let id, let approved):
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .waiting { steps[i].state = approved == true ? .current : .failed }
            }
            guard var note = asked, note.id == id else { break }
            note.state = approved == true ? .allowed : approved == false ? .refused : .expired
            note.byModel = ApprovalClassifier.modelAnswered(id)
            note.reason = note.byModel ? (ApprovalClassifier.verdicts[id]?.reason ?? "") : ""
            note.reply = note.byModel && ApprovalClassifier.mode == .reply
            note.answered = Date()
            asked = nil
            setNote(.approval(note))
            noteID = nil
        // The agent handed a screen to the person (a passcode, a payment): the current step waits for
        // them, as for an approval, until they tap Done on the Live Activity.
        case .handoffRequested:
            updatePlan { steps in
                if let i = steps.lastIndex(where: { $0.state == .current }) { steps[i].state = .waiting }
            }
        case .handoffEnded:
            updatePlan { steps in
                for i in steps.indices where steps[i].state == .waiting { steps[i].state = .current }
            }
        case .relay, .session: break
        }
    }

    private func updatePlan(_ change: (inout [PlanStep]) -> Void) {
        if let id = planID, let i = entries.firstIndex(where: { $0.id == id }), case .plan(var steps) = entries[i].kind {
            change(&steps)
            entries[i].kind = .plan(steps)
            return
        }
        var steps: [PlanStep] = []
        change(&steps)
        guard !steps.isEmpty else { return }
        let entry = ChatEntry(.plan(steps))
        planID = entry.id
        entries.append(entry)
    }

    /// The task's first browser step puts the browser's card in the conversation at that point, so it
    /// comes before the answer the browsing leads to. One card per task; the last task's card stops
    /// being the live one and keeps what it showed.
    private func showBrowser(opening: Bool) {
        guard opening || PokiBrowser.shared.isOpen else { return }
        let task = entries.lastIndex { switch $0.kind { case .you, .request: true; default: false } } ?? -1
        guard !entries[(task + 1)...].contains(where: { if case .browser = $0.kind { true } else { false } }) else { return }
        keepBrowserVisit()
        let card = ChatEntry(.browser(BrowserVisit()))
        entries.append(card)
        liveBrowser = card.id
    }

    /// The live card keeps the site and the page's title, for when it shows them in place of the page:
    /// in a later task, after Close and in the saved conversation.
    private func keepBrowserVisit() {
        let browser = PokiBrowser.shared
        guard let id = liveBrowser, let i = entries.firstIndex(where: { $0.id == id }), browser.isOpen else { return }
        entries[i].kind = .browser(BrowserVisit(host: browser.host, title: browser.title))
    }

    /// The task ended: a step still marked current was the last one done.
    private func finishPlan() {
        keepBrowserVisit()
        updatePlan { steps in for i in steps.indices where steps[i].state == .current { steps[i].state = .done } }
        guard let id = planID, let i = entries.firstIndex(where: { $0.id == id }), entries[i].ended == nil else { return }
        entries[i].ended = Date()
        entries[i].app = taskApp
        entries[i].total = modelPlan?.count
    }

    /// The approval the chat is showing as asked, until its answer comes.
    private var asked: ApprovalNote?

    /// The model would not allow it and the owner is asked on a card: the chat's card says so.
    private func waitsForOwner(_ id: String) {
        guard var note = asked, note.id == id else { return }
        note.byModel = false
        note.reason = ApprovalClassifier.verdicts[id]?.reason ?? ""
        asked = note
        setNote(.approval(note))
    }

    private func setNote(_ note: ChatNote) {
        if let id = noteID, let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].kind = .note(note)
        } else {
            let entry = ChatEntry(.note(note))
            noteID = entry.id
            entries.append(entry)
        }
    }

    private func add(_ kind: ChatEntry.Kind) {
        if case .poki = kind, self.kind == .poki, running { Haptics.received() }
        entries.append(ChatEntry(kind))
    }

    private func markDelivered(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), case .you(let text, false) = entries[i].kind else { return }
        entries[i].kind = .you(text, delivered: true)
    }

    // MARK: Screenshots

    /// The boards' stories (ESP-326), for the sample scenes and the demo.
    enum Sample {
        static var mom: String { AppLocalization.text(LocalizedStringResource("Text Mom I’m running 10 min late")) }
        static var momSteps: [String] {
            [AppLocalization.text(LocalizedStringResource("Open WhatsApp")), AppLocalization.text(LocalizedStringResource("Find the chat with Mom")),
             AppLocalization.text(LocalizedStringResource("Type “Running 10 min late. Save me a seat!”")), AppLocalization.text(LocalizedStringResource("Send it"))]
        }
        static var coffee: String { AppLocalization.text(LocalizedStringResource("Order my usual coffee")) }
        /// The tasks' short names, as the model gives them with its plan.
        static var momTitle: String { AppLocalization.text(LocalizedStringResource("Text Mom")) }
        static var coffeeTitle: String { AppLocalization.text(LocalizedStringResource("Order the usual")) }
        static var coffeeSteps: [String] {
            [AppLocalization.text(LocalizedStringResource("Open Blue Door Coffee")), AppLocalization.text(LocalizedStringResource("Reorder “Oat flat white, large”")),
             AppLocalization.text(LocalizedStringResource("Pay $5.40")), AppLocalization.text(LocalizedStringResource("Confirm pickup at 9:55"))]
        }
        /// The demo's own story, for the home page's suggestion "Messages Text Mom I’m on my way".
        static var demoSteps: [String] {
            [AppLocalization.text(LocalizedStringResource("Open Messages")), AppLocalization.text(LocalizedStringResource("Find the chat with Mom")),
             AppLocalization.text(LocalizedStringResource("Type “On my way!”")), AppLocalization.text(LocalizedStringResource("Send it"))]
        }
        static var demoApproval: PendingApproval {
            PendingApproval(id: "demo", app: "Messages", summary: AppLocalization.text(LocalizedStringResource("Send “On my way!” to Mom")),
                            reason: "sending a message (\"send\")", expires: Date().addingTimeInterval(48))
        }
        /// The app the scene's task is in, for the task card.
        static func app(_ scene: String?) -> String {
            switch scene {
            case "handoff": "Blue Door Coffee"
            case "demo": "Messages"
            default: "WhatsApp"
            }
        }
        /// The step a scene's approval card asks about. `-pokiApprovalReason 'a payment ("pay")'` gives
        /// it another of PokiCore's reasons, for the screenshots of each kind's question.
        static var approval: PendingApproval {
            PendingApproval(id: "sample", app: "WhatsApp", summary: AppLocalization.text(LocalizedStringResource("Send “Running 10 min late. Save me a seat!” to Mom")),
                            reason: reason, expires: Date().addingTimeInterval(48))
        }
        static var reason: String { UserDefaults.standard.string(forKey: "pokiApprovalReason") ?? "sending a message (\"send\")" }
    }

    /// `-pokiChat empty|working|approval|handoff|failed|approved|rested|demo`: the boards' conversations, for
    /// the build's screenshots only. Nothing is sent.
    private func loadSample(_ scene: String) {
        let start = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date()) ?? Date()
        entries = greeting
        entries[0] = ChatEntry(.time(start))
        guard scene != "empty", scene != "demo", scene != "backdrop" else { return }
        func steps(_ texts: [String], done: Int, then state: PlanStep.State?) -> ChatEntry {
            var steps = texts.prefix(done).map { PlanStep($0, state: .done) }
            if let state, texts.count > done { steps.append(PlanStep(texts[done], state: state)) }
            var plan = ChatEntry(.plan(steps))
            plan.at = Date().addingTimeInterval(-42)
            plan.title = texts == Sample.coffeeSteps ? Sample.coffeeTitle : Sample.momTitle
            // A finished one took the boards' 58 seconds in the scene's app.
            if state == nil { plan.at = Date().addingTimeInterval(-58); plan.ended = Date(); plan.app = Sample.app(scene); plan.total = texts.count }
            return plan
        }
        let onIt = ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("On it."))))
        switch scene {
        case "working":
            // Poki has the phone: two steps done, the third under way, the last still to come.
            modelPlan = Sample.momSteps
            entries = [ChatEntry(.time(start)), ChatEntry(.you(Sample.mom, delivered: true)), onIt, steps(Sample.momSteps, done: 2, then: .current)]
        case "approval", "setupHint":
            // The last step waits for your answer (the chat shows its card above the message field).
            modelPlan = Sample.momSteps
            entries = [ChatEntry(.time(start)), ChatEntry(.you(Sample.mom, delivered: true)), onIt, steps(Sample.momSteps, done: 3, then: .waiting)]
        case "handoff":
            // The phone is back with you for the passcode: the step waits, the card says it is your turn.
            modelPlan = Sample.coffeeSteps
            entries = [ChatEntry(.time(start)), ChatEntry(.you(Sample.coffee, delivered: true)), onIt, steps(Sample.coffeeSteps, done: 2, then: .waiting)]
        case "failed":
            var plan = ChatEntry(.plan([PlanStep(AppLocalization.text(LocalizedStringResource("Open Notification Center")), state: .done),
                                        PlanStep(AppLocalization.text(LocalizedStringResource("Tap Clear All")), state: .failed)]))
            plan.title = AppLocalization.text(LocalizedStringResource("Clear notifications"))
            plan.ended = Date(); plan.total = 3
            entries = [ChatEntry(.time(start)), ChatEntry(.you(AppLocalization.text(LocalizedStringResource("Clear my notifications")), delivered: true)), onIt, plan,
                       ChatEntry(.note(.problem(AppLocalization.text(LocalizedStringResource("I tripped. I lost my grip on your phone at step 2, so I stopped before touching anything else.")))))]
        default:
            entries = [ChatEntry(.time(start)), ChatEntry(.you(Sample.mom, delivered: true)), onIt, steps(Sample.momSteps, done: 4, then: nil),
                       ChatEntry(.note(.approved(start.addingTimeInterval(60)))),
                       ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Sent. Mom has it. Anything else?"))))]
        }
    }

    // MARK: Demo

    /// `-pokiChat demo`: the chat starts on the greeting and plays the boards' "Text Mom" story when a
    /// message is sent, with nothing behind it: no model, no phone, no Live Activity, no sound. It
    /// exists to record the main flow on a simulator, where no real task can run.
    let isDemo = UserDefaults.standard.string(forKey: "amore.original.pokiChat.sample") == "demo"
    /// The step the demo waits on your answer for.
    private(set) var demoAsk: PendingApproval?
    private var demoTask: Task<Void, Never>?

    private func playDemo(_ text: String) {
        entries.append(ChatEntry(.you(text, delivered: false)))
        let youID = entries[entries.count - 1].id
        running = true
        awaitingModel = true
        planID = nil
        taskApp = Sample.app("demo")
        demoTask = Task { [weak self] in
            func wait(_ seconds: Double) async -> Bool {
                try? await Task.sleep(for: .seconds(seconds))
                return !Task.isCancelled && self != nil
            }
            guard await wait(1.1), let self else { return }
            self.awaitingModel = false
            self.markDelivered(youID)
            self.entries.append(ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("On it.")))))
            self.modelPlan = Sample.demoSteps
            guard await wait(0.7) else { return }
            self.updatePlan { $0.append(PlanStep(Sample.demoSteps[0])) }
            self.nameTask(Sample.momTitle)
            for i in 1..<3 {
                guard await wait(1.5) else { return }
                self.updatePlan { steps in
                    for j in steps.indices where steps[j].state == .current { steps[j].state = .done }
                    steps.append(PlanStep(Sample.demoSteps[i]))
                }
            }
            guard await wait(1.9) else { return }
            self.updatePlan { steps in
                for j in steps.indices where steps[j].state == .current { steps[j].state = .done }
                steps.append(PlanStep(Sample.demoSteps[3], state: .waiting))
            }
            guard await wait(0.5) else { return }
            self.demoAsk = Sample.demoApproval
        }
    }

    /// Your answer to the demo's approval card.
    func answerDemo(_ approved: Bool) {
        guard demoAsk != nil else { return }
        demoAsk = nil
        updatePlan { steps in for j in steps.indices where steps[j].state == .waiting { steps[j].state = approved ? .current : .failed } }
        demoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(approved ? 1.3 : 0.5))
            guard !Task.isCancelled, let self else { return }
            self.finishPlan()
            self.running = false
            self.entries.append(ChatEntry(.poki(approved ? AppLocalization.text(LocalizedStringResource("Sent. Mom has it. Anything else?")) : AppLocalization.text(LocalizedStringResource("Okay, I didn’t send it.")))))
        }
    }

    private func stopDemo() {
        demoTask?.cancel()
        demoAsk = nil
        awaitingModel = false
        guard running else { return }
        finishPlan()
        running = false
        entries.append(ChatEntry(.poki(AppLocalization.text(LocalizedStringResource("Stopped.")))))
    }
}


/// One tool call of a conversation, without its picture.
struct CallRecord: Codable, Equatable {
    var name: String
    var arguments: String
    var answer: String
    var ms: Int
    var ok: Bool
}

/// A finished task, for memory and routines.
struct TaskRecord {
    var session: String
    var task: String
    var calls: [CallRecord]
    /// What finish_task said; nil when the model never called it.
    var result: TaskResult?
    var seconds: Double
}

/// finish_task's arguments: the verdict, the summary, the requested facts, and the answer's kind with
/// the screen elements it read them from.
struct TaskResult: Decodable, Equatable {
    struct Detail: Decodable, Equatable {
        var label: String
        var value: String
    }
    struct Answer: Decodable, Equatable {
        enum Kind: String, Decodable { case action, field, list }
        struct Item: Decodable, Equatable {
            var ref: String
            var field: String
            var prefix: String?
            var suffix: String?
        }
        var kind: Kind
        var items: [Item]?
        var startRef: String?
        var endRef: String?
        enum CodingKeys: String, CodingKey { case kind, items, startRef = "start_ref", endRef = "end_ref" }
    }
    var success: Bool
    var summary: String
    var details: [Detail]
    var answer: Answer?

    private enum CodingKeys: String, CodingKey { case success, summary, details, answer }

    /// success and summary are required, as task-runner.mjs requires them; details and answer are kept
    /// when they are well formed.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decode(Bool.self, forKey: .success)
        summary = try c.decode(String.self, forKey: .summary)
        details = (try? c.decodeIfPresent([Detail].self, forKey: .details)) ?? []
        answer = (try? c.decodeIfPresent(Answer.self, forKey: .answer)) ?? nil
    }

    /// The requested facts for whoever handed the task over, such as "answer (field): Battery: 81%".
    var answerLine: String? {
        let facts = details.map { "\($0.label): \($0.value)" }.joined(separator: "; ")
        guard let kind = answer?.kind else { return facts.isEmpty ? nil : "details: \(facts)" }
        return "answer (\(kind.rawValue))" + (facts.isEmpty ? "" : ": \(facts)")
    }
}

/// Light taps for the chat, as Messages gives them.
@MainActor
enum Haptics {
    static func sent() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func received() { UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.6) }
    static func done() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
