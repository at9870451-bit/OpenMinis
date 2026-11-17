import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var centre: (x: Double, y: Double) { (x + width / 2, y + height / 2) }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var area: Double { max(0, width) * max(0, height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func contains(_ p: (x: Double, y: Double)) -> Bool { x <= p.x && p.x <= maxX && y <= p.y && p.y <= maxY }
    public func intersection(_ o: Rect) -> Rect {
        let left = max(x, o.x), top = max(y, o.y), right = min(maxX, o.maxX), bottom = min(maxY, o.maxY)
        return Rect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
    }
    public func intersects(_ o: Rect) -> Bool { !intersection(o).isEmpty }
    /// x, y, width and height rounded to whole points.
    var described: String { "[\([x, y, width, height].map { String(Int($0.rounded())) }.joined(separator: ","))]" }
}

/// One element of the accessibility tree, flattened.
public struct Element: Equatable, Sendable {
    public var type: String
    public var label: String?
    public var value: String?
    public var identifier: String?
    public var frame: Rect
    public var depth: Int
    /// The element's place in the tree, in document order, and the last place inside it: an element
    /// whose `node` is in `node+1...end` is inside this one.
    public var node = 0
    public var end = 0
    /// Not in the tree: text read from the screenshot.
    public var fromPicture = false

    public init(type: String, label: String?, value: String?, identifier: String?, frame: Rect, depth: Int, node: Int = 0, end: Int = 0, fromPicture: Bool = false) {
        self.type = type
        self.label = label
        self.value = value
        self.identifier = identifier
        self.frame = frame
        self.depth = depth
        self.node = node
        self.end = end
        self.fromPicture = fromPicture
    }

    func contains(_ other: Element) -> Bool { node < other.node && other.node <= end }

    /// What the element says: its label, and its value when it has one.
    public var text: String { [label, value].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " = ") }
    /// The same element across two reads.
    public var key: String { "\(type)|\(text)" }
    public var isSecure: Bool { type == "SecureTextField" }
}

public struct Foreground: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?
    public var describe: String {
        if bundleID == "com.apple.springboard" { return "Home screen (SpringBoard: the home screen, the App Switcher, a banner or a system alert)" }
        if let name, !name.isEmpty { return name }
        return bundleID ?? "unknown"
    }
}

public struct ScreenSize: Equatable, Sendable { public var width, height: Double }

/// One read of the screen. Either part may be missing; `notes` says why.
public struct Reading: Sendable {
    public var elements: [Element] = []
    public var foreground: Foreground?
    public var png: Data?
    public var notes: [String] = []
    public var ms = 0
}

/// WDA's JSON source as a flat list of the elements worth listing: not the application root, with a
/// frame and something to say.
func flatten(_ root: JSON) -> [Element] {
    var out: [Element] = []
    var counter = 0
    func walk(_ node: JSON, _ depth: Int) {
        guard case .object = node else { return }
        counter += 1
        let place = counter
        let r = node["rect"]
        let frame = Rect(x: r?["x"]?.double ?? 0, y: r?["y"]?.double ?? 0, width: r?["width"]?.double ?? 0, height: r?["height"]?.double ?? 0)
        let visible = node["isVisible"]?.bool ?? true
        var index: Int?
        if depth > 0, visible, frame.width > 0, frame.height > 0 {
            let type = (node["type"]?.string ?? "Other").replacingOccurrences(of: "XCUIElementType", with: "")
            let name = node["name"]?.text
            index = out.count
            out.append(Element(type: type, label: node["label"]?.text ?? name, value: node["value"]?.text, identifier: name, frame: frame, depth: depth, node: place, end: place))
        }
        for child in node["children"]?.array ?? [] { walk(child, depth + 1) }
        if let index { out[index].end = counter }
    }
    walk(root, 0)
    return out
}

/// WDA's XML source (`<AppiumAUT><XCUIElementTypeApplication …><XCUIElementTypeButton name label
/// value x y width height …/>…`) as the same flat list. The wrapper element is not counted.
func flattenXML(_ data: Data) -> (elements: [Element], root: (label: String?, name: String?))? {
    final class Walker: NSObject, XMLParserDelegate {
        var out: [Element] = []
        var counter = 0
        var open: [Int?] = []
        var depth = -1
        var root: (label: String?, name: String?) = (nil, nil)
        var failed = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            guard name != "AppiumAUT" else { return }
            depth += 1
            counter += 1
            let place = counter
            let frame = Rect(x: Double(attributes["x"] ?? "") ?? 0, y: Double(attributes["y"] ?? "") ?? 0, width: Double(attributes["width"] ?? "") ?? 0, height: Double(attributes["height"] ?? "") ?? 0)
            let visible = attributes["visible"].map { $0 == "true" } ?? true
            if depth == 0 { root = (attributes["label"], attributes["name"]) }
            var index: Int?
            if depth > 0, visible, frame.width > 0, frame.height > 0 {
                let type = name.replacingOccurrences(of: "XCUIElementType", with: "")
                let id = attributes["name"]
                index = out.count
                out.append(Element(type: type, label: attributes["label"] ?? id, value: attributes["value"], identifier: id, frame: frame, depth: depth, node: place, end: place))
            }
            open.append(index)
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name != "AppiumAUT" else { return }
            if let index = open.removeLast() { out[index].end = counter }
            depth -= 1
        }
        func parser(_ parser: XMLParser, parseErrorOccurred error: Error) { failed = true }
    }
    let walker = Walker()
    let parser = XMLParser(data: data)
    parser.delegate = walker
    parser.parse()
    guard !walker.failed || !walker.out.isEmpty else { return nil }
    return (walker.out, walker.root)
}

func listable(_ elements: [Element], _ size: ScreenSize, includeUnlabeledImages: Bool = false) -> [Element] {
    // The same element twice (an app that mirrors a control into a second accessibility element at
    // the same place with the same text, seen in WeChat) is listed once.
    var seen = Set<String>()
    return elements.filter { e in
        let key = "\(e.type)|\(e.text)|\(Int(e.frame.x))|\(Int(e.frame.y))|\(Int(e.frame.width))|\(Int(e.frame.height))"
        guard seen.insert(key).inserted else { return false }
        // A web view is listed even with nothing in it: its page is what the model is after, and
        // WebKit's parts reach the tree late, or not at all under a reduced depth (seen in the gym:
        // three looks at a WKWebView listed the nav bar and nothing of the page). Listed as
        // [collapsed], its text is read from the picture.
        let image = includeUnlabeledImages && e.type == "Image" && e.frame.width >= 44 && e.frame.height >= 44
        guard !e.text.isEmpty || image || (e.type == "WebView" && e.frame.height >= 40) else { return false }
        let f = e.frame
        guard f.x + f.width > 0 && f.y + f.height > 0 && f.x < size.width && f.y < size.height else { return false }
        // The Dynamic Island (and Poki's Live Activity in it) is never listed: a tap there opens Poki.
        // It is the top 64 points of the screen in the middle half of the width; no app content
        // lies there (the status bar ends at 62 on an iPhone 17 Pro).
        let centre = f.x + f.width / 2
        if f.y + f.height <= 64, centre > size.width / 4, centre < size.width * 3 / 4, size.width < 1000 { return false }
        return true
    }
}

extension Runner {
    /// The source without visible, accessible, enabled and index: `visible` alone costs 2 s against 0.6 s
    /// for Settings; what is on screen is decided from the frames instead. `format` is "json" or "xml"
    /// (WDA's JSON adds each element's custom actions, one accessibility round trip per element).
    /// Read without a session: WDA serves `/source` and `/wda/activeAppInfo` outside one (queued on
    /// its main thread all the same), so a look never waits on a session open and a session ended
    /// after a slow action does not cost the next read anything. The settings (deadline, detection
    /// point, depth) live in WDA's process, set by the first session of the runner's life.
    func tree(timeout: Double, format: String = "json", workspace: Bool = false) async throws -> (elements: [Element], foreground: Foreground) {
        let xml = format.lowercased() == "xml"
        await ensureSettings(timeout: min(timeout, 3))
        async let source = raw("GET", "/source?format=\(xml ? "xml" : "json")&excluded_attributes=visible,accessible,enabled,index", timeout: timeout)
        // /activeAppInfo queues behind /source, which confirms the selected pane before reading it.
        async let app = try? raw("GET", "/wda/activeAppInfo", timeout: workspace ? timeout : min(timeout, 2))
        let appValue = await app
        let bundleID = appValue?["bundleId"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let appName = appValue?["name"]?.string.flatMap { $0.isEmpty ? nil : $0 }
        let sourceValue: JSON
        do { sourceValue = try await source } catch var error as RunnerError {
            // An app whose tree cannot be read is still the app in front (on the phone, WeChat's in-process
            // read: "Error getting main window kAXError"); without it the app read before stays in front.
            if bundleID != nil || appName != nil { error.foreground = Foreground(bundleID: bundleID, name: appName) }
            throw error
        }
        if xml {
            guard let text = sourceValue.string, let parsed = flattenXML(Data(text.utf8)) else {
                throw RunnerError(message: "the runner's XML tree could not be read", delivery: .notSent)
            }
            return (parsed.elements, Foreground(bundleID: bundleID, name: appName ?? parsed.root.label ?? parsed.root.name))
        }
        let root = (try? sourceValue.string.map(JSON.parse)) ?? sourceValue
        let name = appName ?? root["label"]?.text ?? root["name"]?.text
        return (flatten(root), Foreground(bundleID: bundleID, name: name))
    }

    func screenshot(timeout: Double) async throws -> Data {
        let value = try await raw("GET", "/screenshot", timeout: timeout)
        guard let base64 = value.string, let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            throw RunnerError(message: "the runner sent no screenshot", delivery: .notSent)
        }
        return data
    }

    /// /wda/screen needs no session; a session's window size fails once the app it was opened on is gone.
    func screenSize(timeout: Double = 3) async throws -> ScreenSize {
        let value = try await raw("GET", "/wda/screen", timeout: timeout)
        guard let w = value["screenSize"]?["width"]?.double, let h = value["screenSize"]?["height"]?.double else {
            throw RunnerError(message: "the runner did not say the screen size", delivery: .notSent)
        }
        return ScreenSize(width: w, height: h)
    }

    /// The screenshot and the tree at the same time; each has its own deadline, and a part that fails
    /// is reported in `notes` instead of failing the read.
    /// `extra`: time past `timeout` that a shallow re-read may take when the full-depth read timed
    /// out (seen in the gym: a 1,500-cell screen timed out twice at 4 s and answered nothing, while
    /// the depth-12 read after came in 0.2 s; a shallow tree now beats 4 s of nothing).
    func read(timeout: Double, extra: Double = 0, wantPicture: Bool = true, format: String = "json", callEnds: Double? = nil, allowHostPicture: Bool = true, workspace: Bool = false) async -> Reading {
        let started = now()
        let pictureAt = LockedBox<Double?>(nil)
        // After a read that timed out, the next asks for half the tree's depth (a huge tree is what
        // takes long); a read that came fast restores the full depth for the one after it.
        let wanted = nextLimits.value
        if wanted != limits.value { await useLimits(wanted) }
        let readLimits = limits.value
        async let treePart: Result<(elements: [Element], foreground: Foreground), Error> = {
            do { return .success(try await self.tree(timeout: timeout, format: format, workspace: workspace)) } catch { return .failure(error) }
        }()
        async let picturePart: Result<Data, Error>? = wantPicture ? {
            defer { pictureAt.value = now() }
            do { return .success(try await self.screenshot(timeout: timeout)) } catch { return .failure(error) }
        }() : nil
        // A runner already busy when the read starts is likely to give no picture in time: the
        // host's own path starts now, beside the runner's, so the two are not in series (gym: a
        // wedged runner's call spent 4 s on the runner's screenshot and then 10 s on simctl).
        // Up to 6 s: a look under a wedged runner waited 18 s for it in the gym, and an answer at
        // 6 s with the picture and the runner's state keeps the model moving.
        let hostTimeNow = callEnds.map { Swift.max(1.5, Swift.min(6, $0 - now() - 0.5)) } ?? 6
        let hostEarly: Task<Data?, Never>? = wantPicture && allowHostPicture && busyWith != nil && screenshotFallback != nil
            ? Task { [fallback = screenshotFallback!] in (try? await withDeadline(hostTimeNow, "the host's screenshot") { await fallback() }) ?? nil }
            : nil
        var reading = Reading()
        var treeCame = false
        switch await treePart {
        case .success(let t): reading.elements = t.elements; reading.foreground = t.foreground; treeCame = true
        case .failure(let e):
            reading.foreground = (e as? RunnerError)?.foreground
            // A snapshot the runner refused at once (the app's main loop was busy for the moment:
            // "did not confirm its main run loop is responsive", a transition still running) is
            // asked for once more within the read's time. A timed-out one is not: the runner is
            // still serving it, and a second request would only queue behind it.
            let left = started + timeout - now()
            if (e as? RunnerError)?.delivery == .notSent, left > 1.2 {
                await sleep(seconds: 0.3)
                if let again = try? await self.tree(timeout: left - 0.4, format: format, workspace: workspace) {
                    reading.elements = again.elements; reading.foreground = again.foreground; treeCame = true
                    reading.notes.append("the element tree came on the second try (the first was refused: \(e))")
                } else {
                    reading.notes.append("no element tree: \(e); a second try within the read's time was refused too")
                }
            } else if extra > 2, readLimits.smaller != readLimits, "\(e)".contains("did not finish within") || "\(e)".contains("did not answer") {
                // Timed out: a smaller re-read within this call, once the runner is through with the
                // slow one (nothing is sent to a busy runner). Fewer children per element first: a
                // dense screen (1,500 cells side by side in the gym) is wide, not deep.
                let smaller = readLimits.smaller
                let retryUntil = now() + extra
                reading.notes.append("no element tree (\(readLimits.isFull ? "full" : readLimits.described)): \(e)")
                if await waitUntilFree(timeout: min(3, retryUntil - now() - 1.5)) {
                    await useLimits(smaller)
                    if limits.value == smaller, let again = try? await self.tree(timeout: max(0.5, min(2, retryUntil - now() - 0.2)), format: format, workspace: workspace) {
                        reading.elements = again.elements; reading.foreground = again.foreground; treeCame = true
                        reading.notes.removeLast()
                        reading.notes.append("the full tree timed out (\(e)), so it was read again with \(smaller.described) within this call; \(smaller.caveat)")
                    }
                }
                if !treeCame { nextLimits.value = smaller }
            } else {
                reading.notes.append("no element tree: \(e)")
            }
        }
        let treeAt = now()
        if treeCame {
            let noteSaysLimits = reading.notes.last?.contains("within this call") ?? false
            let read = limits.value
            if !read.isFull, !noteSaysLimits { reading.notes.append("the tree was read with \(read.described) (the read before timed out with more); \(read.caveat)") }
            if treeAt - started < 1.5, !read.isFull { nextLimits.value = read.larger }
        } else if let last = reading.notes.last, last.contains("did not finish within") || last.contains("did not answer") {
            nextLimits.value = readLimits.smaller
        }
        switch await picturePart {
        case .success(let png)?: reading.png = png
        case .failure(let e)?:
            // The tree came (on a second try, from a runner that was busy or new) but the picture
            // taken beside the first try did not: the runner gives it now (seen in the gym). Else
            // the host's own path, apart from the runner, with up to 6 s of its own (simctl on a CI
            // simulator took over 2 s).
            let readLeft = started + timeout + extra - now()
            if treeCame, readLeft > 0.4, let again = try? await screenshot(timeout: min(1.5, readLeft)) {
                reading.png = again
                reading.notes.append("the screenshot came on the second try (the first: \(e))")
            } else if let early = hostEarly, let png = await early.value {
                reading.png = png
                reading.notes.append("screenshot: taken apart from the runner, started beside its own (the runner gave none: \(e))")
            } else if allowHostPicture, let fallback = screenshotFallback {
                // The answer says what became of the host's path, so a missing picture can be traced.
                // The host's path gets the call's remaining time (up to 15 s; simctl took 6.4 s on a
                // loaded CI runner and 14 s under a restart), 6 s when the call's end is not known.
                let began = now()
                let hostTime = callEnds.map { Swift.max(1.5, Swift.min(15, $0 - now() - 0.5)) } ?? 6
                let hostResult: Result<Data?, Error>
                do { hostResult = .success(try await withDeadline(hostTime, "the host's screenshot") { await fallback() }) } catch { hostResult = .failure(error) }
                switch hostResult {
                case .success(let png?):
                    reading.png = png
                    reading.notes.append("screenshot: taken apart from the runner (the runner gave none: \(e))")
                case .success(nil):
                    reading.notes.append("no screenshot: \(e); the host's own path gave none either (\(Int(((now() - began) * 1000).rounded())) ms)")
                case .failure(let hostError):
                    reading.notes.append("no screenshot: \(e); \(hostError)")
                }
            } else {
                reading.notes.append("no screenshot: \(e); the host has no path of its own to the screen")
            }
        case nil: break
        }
        // The tree and the picture are one moment: when the tree came well after the picture (a slow
        // snapshot while the screen moved on), the picture is taken again so the frames and the
        // pixels agree (seen on the phone: a tree of the inside of a chat with a picture of the list).
        if treeCame, reading.png != nil, let at = pictureAt.value, treeAt - at > 0.6, started + timeout - now() > 0.4 {
            if let first = reading.png, let again = try? await screenshot(timeout: min(1.5, started + timeout - now())) {
                reading.png = again
                reading.notes.append("the picture was taken again after the tree, which came \(Int(((treeAt - at) * 1000).rounded())) ms later than the first picture")
                // The two pictures differ: the screen moved while the tree was read, so its frames
                // may be off; the model should go by text (scroll_to, numbers) rather than points.
                let before = PictureSketch(png: first), after = PictureSketch(png: again)
                if after.differs(from: before) {
                    let share = after.change(from: before).map { " (\(Int(($0.share * 100).rounded())) % of it)" } ?? ""
                    reading.notes.append("screen: moving\(share): the picture changed while the tree was read, so frames and points may be off; prefer scroll_to, wait_until and element numbers over [x, y] taps")
                }
            }
        }
        reading.ms = Int(((now() - started) * 1000).rounded())
        return reading
    }
}
