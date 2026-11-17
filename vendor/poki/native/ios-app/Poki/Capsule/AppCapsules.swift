import UIKit

/// An app that shows as a capsule wherever one of its names is written (ESP-377): its icon and its
/// name, as on the home page's pills. The names are the words that turn into the capsule; the plain
/// text keeps exactly what was written. Every app Poki knows by name (`KnownApps`) is one.
struct AppCapsule: Hashable, Identifiable {
    let id: String
    let names: [String]

    /// The name this iPhone shows the app by.
    var name: String { KnownApps.byID[id.lowercased()]?.name(in: .current) ?? names[0] }

    /// How the capsule spells the name, whatever case it was typed in.
    func label(for typed: String) -> String {
        names.first { $0.caseInsensitiveCompare(typed) == .orderedSame } ?? typed
    }

    static let catalog: [AppCapsule] = KnownApps.all.map { AppCapsule(id: $0.id, names: $0.names) }

    /// App names that are also everyday English words. These turn into a capsule only when written
    /// with a capital first letter, as a name; every other Latin name turns into one in any case,
    /// because people typing fast often write "uber" or "slack". "X" counts only as a capital alone.
    static let everydayWords: Set<String> = [
        "Messages", "Notes", "Mail", "Maps", "Phone", "Photos", "Music", "Clock", "Calendar",
        "Camera", "Weather", "Reminders", "Contacts", "Files", "Health", "Wallet", "News", "Books",
        "Podcasts", "Calculator", "Compass", "Measure", "Shortcuts", "Settings", "Translate",
        "Freeform", "Journal", "Passwords", "Games", "Home", "Fitness", "Stocks", "Tips", "Find My",
        "X", "Threads", "Messenger", "Teams", "Zoom", "Outlook", "Chrome", "Amazon",
        "RED", "Podcast", "Lark",
    ]

    /// Apple's apps whose Chinese names are everyday words: 发信息, 打电话, 拍照片 and 看地图 are not
    /// the apps. These turn into a capsule only where an app goes: at the start of the message, or
    /// right after 打开, 用, 在 or 去 ("打开设置", "用信息发给妈妈").
    static let everydayChinese: Set<String> = [
        "信息", "訊息", "电话", "電話", "照片", "相机", "相機", "地图", "地圖", "日历", "邮件", "郵件",
        "设置", "設定", "文件", "檔案", "音乐", "音樂", "天气", "天氣", "时钟", "時鐘", "健康", "钱包",
        "錢包", "查找", "尋找", "翻译", "翻譯", "家庭", "健身", "股市", "播客", "密码", "密碼", "通讯录",
    ]
}

/// The plain text, cut where the apps' names are. Plain text is the only source: the field's capsules
/// are this function's output, and reading the capsules back gives the same text.
enum CapsuleText {
    enum Segment: Equatable {
        case text(String)
        /// The app and the words exactly as written.
        case app(AppCapsule, String)
    }

    /// The longest name wins where one name starts another. A Latin name counts only as a whole word,
    /// so "Slacker" stays text; an everyday word must also start with its capital ("Messages", not
    /// "messages"); a Chinese name counts anywhere, except an everyday one (`everydayChinese`),
    /// which counts only where an app goes.
    static func segments(_ plain: String) -> [Segment] {
        let text = plain as NSString
        var out: [Segment] = []
        var run = 0
        var i = 0
        while i < text.length {
            let hit = Names.starting(with: text.character(at: i)).first { name in
                i + name.text.length <= text.length
                    && text.compare(name.text as String, options: name.options, range: NSRange(location: i, length: name.text.length)) == .orderedSame
                    && wholeWord(name.text, at: i, in: text)
                    && (!name.onlyAsApp || appGoes(at: i, in: text))
            }
            if let hit {
                if run < i { out.append(.text(text.substring(with: NSRange(location: run, length: i - run)))) }
                out.append(.app(hit.app, text.substring(with: NSRange(location: i, length: hit.text.length))))
                i += hit.text.length
                run = i
            } else {
                i += 1
            }
        }
        if run < text.length { out.append(.text(text.substring(from: run))) }
        return out
    }

    /// Every app's names, by their first letter (lower-cased), longest first.
    private enum Names {
        struct Name {
            let app: AppCapsule
            let text: NSString
            let options: NSString.CompareOptions
            let onlyAsApp: Bool
        }

        static func starting(with unit: unichar) -> [Name] { table[fold(unit)] ?? [] }

        private static let table: [unichar: [Name]] = {
            var table: [unichar: [Name]] = [:]
            for app in AppCapsule.catalog {
                for name in app.names {
                    let options: NSString.CompareOptions = AppCapsule.everydayWords.contains(name) ? .literal : .caseInsensitive
                    let entry = Name(app: app, text: name as NSString, options: options, onlyAsApp: AppCapsule.everydayChinese.contains(name))
                    table[fold((name as NSString).character(at: 0)), default: []].append(entry)
                }
            }
            return table.mapValues { $0.sorted { $0.text.length > $1.text.length } }
        }()

        private static func fold(_ unit: unichar) -> unichar {
            (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
        }
    }

    /// Where an app's name goes in a request: the start of the message, or right after a word that
    /// opens or uses an app.
    private static func appGoes(at i: Int, in text: NSString) -> Bool {
        let before = text.substring(to: i).trimmingCharacters(in: .whitespaces)
        return before.isEmpty || ["打开", "打開", "用", "在", "去"].contains { before.hasSuffix($0) }
    }

    /// The text a recommendation puts in the field: the app's name as the idea is written, then the
    /// sentence, whatever language the iPhone names the app in.
    static func prefill(app name: String, sentence: String) -> String {
        "\(name) \(sentence)"
    }

    private static func wholeWord(_ name: NSString, at i: Int, in text: NSString) -> Bool {
        let wordy = CharacterSet.alphanumerics
        func isLatinWordChar(_ unit: unichar) -> Bool {
            unit < 0x80 && UnicodeScalar(unit).map(wordy.contains) == true
        }
        if isLatinWordChar(name.character(at: 0)), i > 0, isLatinWordChar(text.character(at: i - 1)) { return false }
        let end = i + name.length
        if isLatinWordChar(name.character(at: name.length - 1)), end < text.length, isLatinWordChar(text.character(at: end)) { return false }
        return true
    }
}
