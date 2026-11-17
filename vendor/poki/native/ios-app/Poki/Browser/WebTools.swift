import Foundation
import PokiCore

/// The chat agent's tools for Poki's own browser (ESP-145): open an address, read the page's elements,
/// tap one, type into one, and hand the page to the owner. They work on `PokiBrowser`, never on the
/// phone's screen, so the owner keeps the phone while the agent works a website.
enum WebTools {
    static let names: Set<String> = ["web_open", "web_read", "web_click", "web_type", "web_handoff"]

    private static func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    static let specs: [ToolSpec] = [
        ToolSpec(name: "web_open",
                 description: "Open a website in Poki's sandbox browser. For a pure website task, use web tools only: do not also call look or do, launch Safari, or start phone controls. Answers with the page's elements, as web_read does.",
                 schema: object(["url": ["type": "string", "description": "A full address, such as https://www.fandango.com"]], ["url"])),
        ToolSpec(name: "web_read",
                 description: "Read the page in Poki's browser: links, buttons and fields with refs such as [e12], headings and text, in page order. find keeps the lines containing that text. A long page comes in parts: pass offset to read on.",
                 schema: object(["find": ["type": "string"], "offset": ["type": "integer", "minimum": 0]], [])),
        ToolSpec(name: "web_click",
                 description: "Tap an element of the page by its ref from the latest page read. Answers with the page after the tap.",
                 schema: object(["ref": ["type": "string"], "element": ["type": "string", "description": "What the element is, for the owner watching."]], ["ref"])),
        ToolSpec(name: "web_type",
                 description: "Type text into a field by its ref (replacing what is there), or choose an option of a select by its label. submit presses Enter. Answers with the page after typing.",
                 schema: object(["ref": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean"]], ["ref", "text"])),
        ToolSpec(name: "web_handoff",
                 description: "Give the page in Poki's browser to the owner and wait until they hand it back: for signing in, a human check or captcha, a payment, or anything only they should do. reason is shown to them.",
                 schema: object(["reason": ["type": "string"]], ["reason"])),
    ]

    static let instructions = """
    Poki has its own browser for websites, apart from Safari and the phone's screen. For a task on a website (showtimes, prices, opening hours, anything read from a site), use web_open, web_read, web_click and web_type instead of opening Safari with look and do: the owner keeps using the phone meanwhile. Start with web_open on the site's main address. A pure website task, including a Wikipedia lookup, must not also call look or do, launch Safari, or start phone controls. Finish with finish_task, never a do call. Use phone controls alongside the browser only for a separate app part explicitly requested by the owner, with its own report_plan step naming that app. A failed webpage is not permission to switch to phone controls. Pages answer as lines; act on the refs in brackets from the latest answer, since refs change when the page changes. Prefer find over reading a long page twice. Never delete, send, post, transfer or cancel anything of the owner's on a site: that is theirs, so call web_handoff. Never sign in, pay, buy, book or submit the owner's personal details: when the site needs a sign-in, shows a human check or captcha, or asks for payment, call web_handoff with a short reason and continue after it returns. Banners and pop-ups come in two kinds. A notice that only informs and covers the page (a cookie or privacy banner, or a site-use notice such as "by continuing to use this site you agree to our terms") is yours to dismiss: tap its reject or necessary-only choice (such as Reject all, Decline, Only necessary) when it has one, otherwise Continue, Close or Accept. Anything that would give the owner an obligation or an identity is the owner's, so call web_handoff: signing up or in, subscribing or paying, a free trial, entering an age or birthday, a human check, a form that needs "I agree to the terms" ticked before it can be sent, and any pop-up with an email or password field. When unsure which kind it is, treat it as the owner's. A notice you dismiss shows as its own step; you need not mention it in your answer. If the owner did not name a place and the site needs one, use the place the site suggests and say which one you used. Report only what the pages showed, with the date and place it applies to; when a list was cut short, say so rather than filling it in. Finish with finish_task: for an answer read from a website use answer.kind field or list with the facts in details, and leave answer.items empty.
    """

    /// A short button or link label that pays or orders.
    @MainActor static let paying = try! Regex(#"(?i)\b(pay|purchase|buy|checkout|check out|(place|submit|complete|confirm) (your |my |the )?(order|purchase|booking|payment|reservation)|order now|book now|reserve now|donate|subscribe|start (a |your )?(free )?trial|free trial)\b|付款|支付|下单|下單|购买|購買|结账|結帳|結賬|订阅|訂閱|试用|試用|提交订单|提交訂單|立即预订|立即預訂|捐款|捐赠|捐贈"#)

    /// A short button or link label for a step only the owner takes: signing in or up, an age check,
    /// agreeing to terms.
    @MainActor static let ownersStep = try! Regex(#"(?i)\b(sign ?in|log ?in|sign ?up|register|create (an |your )?account|join (for free|now)|continue with (google|apple|facebook|microsoft|email|phone))\b|\b(i am|i'm|im) (over |at least )?(1[3-9]|2[01])\b|\b(1[3-9]|2[01]) ?(\+|or older|and over|years or older)|\b(verify|confirm) (my |your )?age\b|\b(agree|accept|consent)\b.*\b(terms|conditions|eula|license agreement)\b|登录|登錄|登入|注册|註冊|年满|年滿|同意.*(条款|條款|协议|協議)"#)

    /// A short button or link label that changes something of the owner's on a site they are signed in
    /// to, or speaks for them: deleting, sending, posting, moving money, cancelling what they hold.
    /// Poki's browser keeps the owner's sign-ins between tasks, so these taps are real. The verb opens
    /// the label ("Send message", "Delete"): inside a longer one it is a name, such as a newspaper's.
    @MainActor static let ownersChange = try! Regex(#"(?i)^\W*(delete|erase|send|transfer|withdraw|post|publish|tweet|unsubscribe)\b|\b((cancel|end) (my |your |the )?(subscription|membership|order|booking|reservation|plan|account)|(close|deactivate|delete|remove) (my |your |the )?account)\b"#)
    /// The same in Chinese, for a label short enough to be a button: in a headline these are ordinary words.
    @MainActor static let ownersChangeShort = try! Regex(#"删除|刪除|发送|發送|传送|傳送|转账|轉賬|轉帳|汇款|匯款|提现|提現|发布|發佈|發布|发表|發表|退订|退訂|取消(订单|訂單|订阅|訂閱|预订|預訂)|注销|註銷"#)

    /// Why a tap on this label is the owner's, as the model is told, or nil when Poki may tap it.
    @MainActor static func ownersTap(_ label: String) -> String? {
        if label.count <= 40, label.contains(paying) {
            return "“\(label)” looks like paying or ordering. That is the owner's to do: call web_handoff."
        }
        if label.count <= 60, label.contains(ownersStep) {
            return "“\(label)” is a sign-in, sign-up, age or terms step. That is the owner's to do: call web_handoff with a short reason."
        }
        if label.count <= 40 && label.contains(ownersChange) || label.count <= 8 && label.contains(ownersChangeShort) {
            return "“\(label)” deletes, sends, posts, moves money or cancels something of the owner's. That is the owner's to do: call web_handoff with a short reason."
        }
        return nil
    }

    @MainActor static func perform(_ name: String, arguments: String) async -> PokiCore.ToolAnswer {
        let args = (arguments.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        let browser = PokiBrowser.shared
        guard await browser.waitForPoki() else { return answer("Task stopped. Action not executed.", error: true) }
        let started = Date()
        let result: PokiCore.ToolAnswer
        switch name {
        case "web_open":
            guard let url = address(args["url"] as? String) else {
                return answer("web_open needs a full web address, such as https://www.example.com.", error: true)
            }
            if BrowserAddress.refusal(url) == .local {
                return answer("Poki's browser opens public websites only. \(url.host(percentEncoded: false) ?? "That address") is on this iPhone or its local network, so it was not opened.", error: true)
            }
            let step = browser.begin(AppLocalization.text(LocalizedStringResource("Open \(url.host(percentEncoded: false) ?? url.absoluteString)")))
            await browser.open(url)
            result = await page(browser, budget: 7000)
            browser.end(step, ok: !result.isError, started: started)
        case "web_read":
            let find = (args["find"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard browser.isOpen else { return answer("Nothing is open in Poki's browser. Call web_open first.", error: true) }
            let step = browser.begin(find.isEmpty ? AppLocalization.text(LocalizedStringResource("Read the page")) : AppLocalization.text(LocalizedStringResource("Look for “\(find)”")))
            result = await page(browser, find: find, offset: args["offset"] as? Int ?? 0, budget: 9000)
            browser.end(step, ok: !result.isError, started: started)
        case "web_click":
            guard let ref = args["ref"] as? String else { return answer("web_click needs a ref from the latest page read.", error: true) }
            let label = await label(browser, ref) ?? (args["element"] as? String) ?? ref
            if let owners = ownersTap(label) { return answer(owners, error: true) }
            let banner = (try? await browser.call("return window.__pokiReader.consent(ref)", ["ref": ref])) as? [String: Any] ?? [:]
            if banner["owner"] as? Bool == true {
                return answer("“\(label)” goes ahead in a sign-in, subscription, age or terms prompt. That is the owner's to do: call web_handoff with a short reason.", error: true)
            }
            if banner["accept"] as? Bool == true, let reject = banner["reject"] as? String {
                return answer("This notice has “\(banner["rejectName"] as? String ?? "")” [\(reject)]: tap that instead. Accept, continue or close a notice only when it has no reject or necessary-only choice.", error: true)
            }
            // A notice Poki dismisses is named in its step, so the owner sees what Poki closed.
            let notice = banner["banner"] as? Bool == true && banner["dismiss"] as? Bool == true ? banner["kind"] as? String ?? "" : ""
            let site = browser.host, button = short(label)
            let title = switch notice {
            case "cookie": AppLocalization.text(LocalizedStringResource("Dismissed \(site)’s cookie banner: “\(button)”"))
            case "terms": AppLocalization.text(LocalizedStringResource("Dismissed \(site)’s terms notice: “\(button)”"))
            case "privacy": AppLocalization.text(LocalizedStringResource("Dismissed \(site)’s privacy notice: “\(button)”"))
            default: AppLocalization.text(LocalizedStringResource("Tap “\(button)”"))
            }
            let step = browser.begin(title)
            let tapped = await browser.act { (try? await browser.call("return window.__pokiReader.click(ref)", ["ref": ref])) as? [String: Any] }
            result = await after(browser, tapped, ref: ref, did: notice.isEmpty ? "Tapped “\(label)”." : "Dismissed the notice with “\(label)”.")
            browser.end(step, ok: !result.isError, started: started)
        case "web_type":
            guard let ref = args["ref"] as? String, let text = args["text"] as? String else {
                return answer("web_type needs a ref and the text.", error: true)
            }
            let label = await label(browser, ref) ?? ref
            let step = browser.begin(AppLocalization.text(LocalizedStringResource("Type “\(short(text))” in “\(short(label))”")))
            let typed = await browser.act {
                (try? await browser.call("return window.__pokiReader.type(ref, text, submit)", ["ref": ref, "text": text, "submit": args["submit"] as? Bool ?? false])) as? [String: Any]
            }
            result = await after(browser, typed, ref: ref, did: "Typed into “\(label)”: \(typed?["value"] as? String ?? text).")
            browser.end(step, ok: !result.isError, started: started)
        case "web_handoff":
            guard browser.isOpen else { return answer("Nothing is open in Poki's browser to hand over.", error: true) }
            let reason = (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let step = browser.begin(AppLocalization.text(LocalizedStringResource("Waiting for you: \(reason)")))
            browser.markWaiting(step)
            browser.takeOver(reason: reason)
            guard await browser.waitForPoki() else { return answer("Task stopped while the owner had the page.", error: true) }
            let now = await page(browser, budget: 6000)
            result = answer("The owner handed the page back.\n" + now.text, error: now.isError)
            browser.end(step, ok: true, started: started)
        default:
            return answer("Unknown tool \(name).", error: true)
        }
        AppLog.shared.add("browser", "\(name) \(result.isError ? "failed" : "ok") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return result
    }

    // MARK: Answers

    private static func answer(_ text: String, error: Bool) -> PokiCore.ToolAnswer {
        PokiCore.ToolAnswer(text: text, jpeg: nil, isError: error)
    }

    /// An address as typed by a model: a bare domain gets https, and so does an `http` address of a
    /// public site (a local test page keeps `http`). Sign-in details in the address are not accepted.
    static func address(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        if scheme == "http", !BrowserAddress.isLocal(host) { parts.scheme = "https" }
        return parts.url
    }

    private static func short(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 40 ? String(flat.prefix(39)) + "…" : flat
    }

    @MainActor private static func label(_ browser: PokiBrowser, _ ref: String) async -> String? {
        (try? await browser.call("return window.__pokiReader.label(ref)", ["ref": ref])) as? String
    }

    /// The page as the model reads it: title, address, then the lines.
    @MainActor private static func page(_ browser: PokiBrowser, find: String = "", offset: Int = 0, budget: Int, changes: Bool = false) async -> PokiCore.ToolAnswer {
        let read: [String: Any]
        do {
            read = try await browser.call("return window.__pokiReader.read({find, offset, budget, changes})",
                                          ["find": find, "offset": offset, "budget": budget, "changes": changes]) as? [String: Any] ?? [:]
        } catch {
            return answer("The page could not be read: \(error.localizedDescription)", error: true)
        }
        let lines = read["lines"] as? [String] ?? []
        let url = read["url"] as? String ?? browser.url?.absoluteString ?? ""
        if lines.isEmpty && find.isEmpty && (url.isEmpty || url == "about:blank") {
            return answer("The page did not load. Check the address, or try again.", error: true)
        }
        var text = "Page: \(read["title"] as? String ?? "")\nURL: \(url)\n"
        if !find.isEmpty && lines.isEmpty { text += "Nothing on the page contains “\(find)”.\n" }
        if let changed = read["changed"] as? [String], !changed.isEmpty {
            text += "New on the page since the last read:\n" + changed.joined(separator: "\n") + "\n\nThe page from the top:\n"
        }
        text += lines.joined(separator: "\n")
        let total = read["total"] as? Int ?? lines.count
        if let next = read["next"] as? Int {
            text += "\n(lines \(offset + 1) to \(next) of \(total); call web_read with offset \(next) for more)"
        }
        if let banner = read["consent"] as? [String: Any], let choice = banner["choice"] as? String {
            text += banner["reject"] as? Bool == true
                ? "\nA notice banner is open (cookie, privacy or site terms): dismiss it with its reject choice \(choice)."
                : "\nA notice banner is open (cookie, privacy or site terms) and has no reject choice: dismiss it with \(choice)."
        }
        if read["humanCheck"] as? Bool == true {
            text += "\nThis page shows a human check. Do not try to pass it: call web_handoff so the owner can."
        }
        return answer(text, error: false)
    }

    /// The answer to a tap or typing: what happened, then the page as it is now.
    @MainActor private static func after(_ browser: PokiBrowser, _ result: [String: Any]?, ref: String, did: String) async -> PokiCore.ToolAnswer {
        guard let result else { return answer("The page did not answer. Read it again with web_read.", error: true) }
        if result["ok"] as? Bool != true {
            switch result["error"] as? String {
            case "stale": return answer("[\(ref)] is not on the page any more. Read the page again and use a current ref.", error: true)
            case "disabled": return answer("[\(ref)] is disabled.", error: true)
            case "owner": return answer("That field is for the owner (a password, card or one-time code): call web_handoff.", error: true)
            case "ownerform": return answer("The text is typed, but this form also holds the owner's details, so it was not sent. Sending it is the owner's to do: call web_handoff.", error: true)
            case "option": return answer("No such option. The options are: \((result["options"] as? [String] ?? []).joined(separator: " | "))", error: true)
            default: return answer("[\(ref)] is not a field Poki can type into.", error: true)
            }
        }
        var text = did
        if let covered = result["covered"] as? String { text += " Something covered it on the page (\(covered)); if nothing changed, dismiss that first as the instructions say." }
        let now = await page(browser, budget: 6000, changes: true)
        return answer(text + "\n" + now.text, error: now.isError)
    }
}
