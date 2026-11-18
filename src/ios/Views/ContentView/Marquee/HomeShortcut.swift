// SPDX-License-Identifier: AGPL-3.0-only
// HomeShortcut structure and normalization adapted from JosssphZhou/poki
// Chat/HomeShortcuts.swift, revision 69585293051fee03c7ad110f037d8f4dd2a4e96f.
// Amore action routes are explicit additions; Poki's original tap fills a prompt.
import Foundation

struct AmoreHomeShortcut: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable, Hashable { case prompt, page, link }
    struct Action: Codable, Equatable, Sendable {
        var kind: Kind
        /// Prompt text, supported minis settings route, or HTTPS link.
        var value: String
    }
    var id: String
    var appName: String
    var title: String
    var symbol: String
    var action: Action
    var edited: Bool = false
    var hidden: Bool = false
}

/// Original normalization / Dice-frecency rules, evaluated off the UI thread.
enum AmoreShortcutRanking {
    static func normalized(_ text: String) -> String {
        var s = text.lowercased()
        for pattern in [#"\d+([:./\-年月日号点时分]\d*)*"#,
                        #"(今天|明天|后天|昨天|今晚|明早|周[一二三四五六日天])"#,
                        #"\b(today|tomorrow|tonight|yesterday|morning|afternoon|evening)\b"#] {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        s = String(s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map(Character.init))
        for opening in ["please", "canyou", "couldyou", "helpme", "请帮我", "帮我", "麻烦", "请"] where s.hasPrefix(opening) {
            s.removeFirst(opening.count)
        }
        return s
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func pairs(_ s: String) -> [String] {
            let c = Array(s)
            return c.count < 2 ? c.map(String.init) : (0..<(c.count - 1)).map { String(c[$0...($0 + 1)]) }
        }
        let x = pairs(a), y = pairs(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        var rest = y, shared = 0
        for p in x { if let i = rest.firstIndex(of: p) { rest.remove(at: i); shared += 1 } }
        return Double(2 * shared) / Double(x.count + y.count) >= 0.8
    }
    static func frecency(_ count: Int, last: Date, now: Date) -> Double {
        let age = now.timeIntervalSince(last)
        return Double(count) * (age < 3600 ? 4 : age < 86400 ? 2 : age < 604800 ? 0.5 : 0.25)
    }
    static func isPrivate(_ text: String) -> Bool {
        let patterns = [#"[$¥€£₩]"#, #"\d{4,}"#,
            #"(付款|支付|转账|验证码|密码|口令|密钥|消息|短信|微信|回复|邮件|联系)"#,
            #"\b(password|passcode|pin|token|otp|payment|transfer|text|message|reply|email|send)\b"#,
            #"[“”\"「」『』‘’@]"#]
        return patterns.contains { text.lowercased().range(of: $0, options: .regularExpression) != nil }
    }
    static func valid(_ item: AmoreHomeShortcut) -> Bool {
        !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && item.title.count <= 100 && !item.symbol.isEmpty && item.symbol.count <= 100
            && validAction(item.action)
    }
    static func validAction(_ action: AmoreHomeShortcut.Action) -> Bool {
        guard action.value.count <= 8000 else { return false }
        switch action.kind {
        case .prompt: return !action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .page: return supportedPages.contains(AmoreShortcutRoutes.canonicalPage(action.value))
        case .link:
            guard let u = URL(string: action.value) else { return false }
            return u.scheme?.lowercased() == "https" && u.host?.isEmpty == false
                && u.user == nil && u.password == nil
        }
    }
    static let supportedPages = AmoreShortcutRoutes.pages
}

/// Only destinations wired by DeepLinkRouter / SettingsSheet, plus the local manager.
/// No guessed `views/*` paths; shortcuts is presented by the home source itself.
enum AmoreShortcutRoutes {
    static let pages = ["home", "providers", "model-groups", "usage", "skills", "soul", "tools",
                        "memory", "storage", "mount-external", "shared-folders", "logs", "appearance",
                        "background", "about", "permissions", "environments", "rootfs",
                        "developer-connection", "mcp", "shortcuts"]
    static func canonicalPage(_ page: String) -> String {
        switch page {
        case "developer": return "developer-connection"
        case "mirrors": return "rootfs"
        case "settings": return "home"
        default: return page
        }
    }
    static func settingsURL(for page: String) -> URL? {
        let page = canonicalPage(page)
        guard pages.contains(page), page != "shortcuts" else { return nil }
        return URL(string: page == "home" ? "minis://settings" : "minis://settings/\(page)")
    }
}

/// Pure presentation/data policy, independent of SwiftUI, storage and wall time.
enum AmoreHomeShortcutPolicy {
    static func shouldShow(messageCount: Int, input: String, attachmentCount: Int,
                           pastedTextCount: Int, loadingVideoCount: Int,
                           isLoading: Bool, isProcessing: Bool, isEditing: Bool) -> Bool {
        messageCount == 0 && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && attachmentCount == 0 && pastedTextCount == 0 && loadingVideoCount == 0
            && !isLoading && !isProcessing && !isEditing
    }
    static func rows(_ items: [AmoreHomeShortcut]) -> [[AmoreHomeShortcut]] {
        let split = (items.count + 1) / 2
        return [Array(items.prefix(split)), Array(items.dropFirst(split))]
    }
    static func sanitized(_ items: [AmoreHomeShortcut]) -> [AmoreHomeShortcut] {
        var seen = Set<String>()
        return items.compactMap { value in
            var item = value
            if item.action.kind == .page { item.action.value = AmoreShortcutRoutes.canonicalPage(item.action.value) }
            guard AmoreShortcutRanking.valid(item), seen.insert(item.id).inserted else { return nil }
            return item
        }
    }
    /// Upgrade the shipped four-item v1 catalog once. Respect edits, hides and deletions.
    static func upgrade(_ items: [AmoreHomeShortcut], defaults: [AmoreHomeShortcut],
                        previousDefaultIDs: Set<String>) -> [AmoreHomeShortcut] {
        var result = sanitized(items)
        for item in defaults {
            if let index = result.firstIndex(where: { $0.id == item.id }) {
                if previousDefaultIDs.contains(item.id), !result[index].edited {
                    let hidden = result[index].hidden
                    result[index] = item
                    result[index].hidden = hidden
                }
            } else if !previousDefaultIDs.contains(item.id) {
                result.append(item)
            }
        }
        return result
    }
}
