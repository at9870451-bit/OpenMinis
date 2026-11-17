import Foundation
import Observation
import WebKit

/// One step Poki took in its browser, as the panel lists it.
struct BrowserStep: Identifiable, Equatable {
    enum State: Equatable { case working, done, failed, waiting }
    let id = UUID()
    var text: String
    var state: State
    var ms: Int = 0
}

/// Poki's own browser (ESP-145): a WKWebView of its own, apart from Safari and the phone's screen, so the
/// agent can work a website while the owner keeps the phone. Its website data store is the app's
/// persistent one, so a sign-in done here stays for the next task. It shows as a panel in the chat;
/// the owner can take it over at any time, and the agent hands it over for sign-ins, human checks and
/// payment. Works while Poki is in front.
@MainActor
@Observable
final class PokiBrowser: NSObject {
    static let shared = PokiBrowser()

    enum Owner: Equatable {
        case poki
        /// The owner has the page: they took it over, or the agent asked them (`reason`).
        case person(reason: String?)
    }

    /// The panel shows while this is true.
    private(set) var isOpen = false
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var steps: [BrowserStep] = []
    private(set) var owner: Owner = .poki
    /// The take-over sheet is up (the page moves into it).
    var sheetShown = false

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let world = WKContentWorld.world(name: "PokiBrowser")
    /// The page under way has replaced the last one (its document is the one scripts see).
    @ObservationIgnored private var committed = true
    @ObservationIgnored private var activeNavigation: WKNavigation?
    @ObservationIgnored private let supersededNavigations = NSHashTable<WKNavigation>.weakObjects()
    @ObservationIgnored private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var ownerWaiters: [CheckedContinuation<Bool, Never>] = []

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    var host: String { url?.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "" }
    var ownerHasIt: Bool { if case .person = owner { true } else { false } }

    // MARK: Steps

    @discardableResult
    func begin(_ text: String) -> UUID {
        // The first step of a browsing session opens the panel with an empty list.
        if !isOpen { isOpen = true; steps = [] }
        let step = BrowserStep(text: text, state: .working)
        steps.append(step)
        if steps.count > 60 { steps.removeFirst(steps.count - 60) }
        return step.id
    }

    func end(_ id: UUID, ok: Bool, started: Date) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = ok ? .done : .failed
        steps[i].ms = Int(Date().timeIntervalSince(started) * 1000)
    }

    // MARK: Page

    func open(_ url: URL) async {
        isOpen = true
        trackNavigation(webView.load(URLRequest(url: url)))
        await waitForLoad()
        _ = await settle()
    }

    /// Runs `action`, then waits for a navigation it started and for the page to be still.
    func act<T>(_ action: () async -> T) async -> T {
        let value = await action()
        try? await Task.sleep(for: .milliseconds(250))
        await waitForLoad()
        _ = await settle()
        return value
    }

    /// Until the page under way has loaded, at most `seconds`; at once when nothing is loading. A page
    /// whose document is parsed is readable before its last image or ad arrives, so that ends it too.
    private func waitForLoad(seconds: Double = 12) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { c in
                    if self.isLoading || !self.committed { self.loadWaiters.append(c) } else { c.resume() }
                }
            }
            group.addTask { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(300))
                    if self.committed, let state = try? await self.webView.evaluateJavaScript("document.readyState") as? String, state != "loading" { return }
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
            self.finishLoads()
        }
    }

    private func finishLoads() {
        let waiters = loadWaiters
        loadWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func trackNavigation(_ navigation: WKNavigation?) {
        guard let navigation, navigation !== activeNavigation else { return }
        if let activeNavigation { supersededNavigations.add(activeNavigation) }
        activeNavigation = navigation
        committed = false
        isLoading = true
    }

    /// Calls one of the page reader's functions in Poki's content world, loading the reader first.
    func call(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(PageReader.source + "\n" + body, arguments: arguments, in: nil, contentWorld: world)
    }

    private func settle() async -> Int {
        (try? await call("return await window.__pokiReader.settle(400, 3000)")) as? Int ?? 0
    }

    // MARK: Owner

    /// The owner takes the page: the sheet comes up and the agent's next step waits for them.
    func takeOver(reason: String? = nil) {
        owner = .person(reason: reason)
        // The owner starts from a page with nothing focused, and its fields get their keyboard back
        // (the reader keeps it down while Poki types).
        webView.endEditing(true)
        sheetShown = true
        if isOpen { Task { _ = try? await call("window.__pokiReader.drive(false)") } }
    }

    /// The owner gives the page back to Poki (Done in the sheet, or the sheet swiped away).
    func handBack() {
        guard ownerHasIt else { return }
        owner = .poki
        // A field the owner left focused would bring the keyboard up over the chat.
        webView.endEditing(true)
        sheetShown = false
        let waiters = ownerWaiters
        ownerWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }

    /// Waits while the owner has the page. False when the task was stopped meanwhile.
    func waitForPoki() async -> Bool {
        guard ownerHasIt else { return true }
        return await withCheckedContinuation { c in ownerWaiters.append(c) }
    }

    /// The chat's Stop: whatever waits ends, loading stops, the page stays for the owner to see.
    func taskStopped() {
        webView.stopLoading()
        finishLoads()
        let waiters = ownerWaiters
        ownerWaiters = []
        waiters.forEach { $0.resume(returning: false) }
        for i in steps.indices where steps[i].state == .working || steps[i].state == .waiting { steps[i].state = .failed }
    }

    /// The panel's close button: the page goes, the website data (sign-ins) stays.
    func close() {
        taskStopped()
        owner = .poki
        sheetShown = false
        isOpen = false
        steps = []
        url = nil
        title = ""
        trackNavigation(webView.load(URLRequest(url: URL(string: "about:blank")!)))
    }

    func markWaiting(_ id: UUID) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].state = .waiting
    }
}

extension PokiBrowser: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, !supersededNavigations.contains(navigation) else { return }
        trackNavigation(navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        committed = true
        url = webView.url
        title = webView.title ?? ""
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        isLoading = false
        url = webView.url
        title = webView.title ?? ""
        finishLoads()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        isLoading = false
        finishLoads()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        committed = true
        isLoading = false
        finishLoads()
    }

    /// A page cannot send the browser to this iPhone or its local network (a link, a redirect or a
    /// frame), whoever is driving. `web_open` refuses such an address itself, with words for the model.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url, BrowserAddress.refusal(target) != nil else { return .allow }
        AppLog.shared.add("browser", "refused a navigation to a local address")
        return .cancel
    }

    /// Links that open a new window open here instead: the panel has one page.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { trackNavigation(webView.load(navigationAction.request)) }
        return nil
    }

    /// Pages' own alerts would wait for a tap nobody sees: they are answered at once and the answer is
    /// the page's default.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {}
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool { false }
}
