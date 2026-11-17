import SwiftUI

/// Every action Poki ran on this iPhone and every approval it asked for, for the owner's own record:
/// kept on this device, with no way to delete an entry from the app. Each entry names the session it
/// came from (Poki's chat or an outside agent's), so a tap opens that run. The log keeps its latest
/// `keep` entries: older ones are dropped when the file is trimmed.
@MainActor
@Observable
final class ActionLog {
    static let shared = ActionLog()
    /// How many entries stay. The file is trimmed back to this once it runs `slack` over.
    static let keep = 5000
    static let slack = 500

    struct Entry: Codable, Identifiable, Hashable {
        enum Kind: String, Codable { case approval }
        var id = UUID()
        var at: Date
        var text: String
        var app: String?
        var ok: Bool
        var session: String?
        /// The outside agent that asked for it; nil for Poki's own chat.
        var caller: String? = nil
        /// nil for an action; an approval's entry says how it was answered in `detail`.
        var kind: Kind? = nil
        var detail: String? = nil
        /// Why the step needed an answer, from PokiCore's rules.
        var why: String? = nil

        /// One line of text for a copied log.
        var line: String {
            let time = at.formatted(Date.FormatStyle(date: .omitted, time: .standard).locale(AppLocalization.locale))
            let mark = kind == .approval ? (ok ? "approval allowed" : "approval refused") : (ok ? "ok" : "failed")
            let place = AppName.display(app).map { " in \($0)" } ?? ""
            let more = [detail, why.map(ActivityWords.reason)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
            return "\(time)  [\(mark)] \(ActivityWords.label(text))\(place)\(more.isEmpty ? "" : " (\(more))")"
        }
    }

    /// Entries that follow one another from the same run on the same day, newest first.
    struct Run: Identifiable, Hashable {
        var id: UUID
        var session: String?
        var caller: String?
        var entries: [Entry]
        var failed: Int { entries.filter { !$0.ok && $0.kind == nil }.count }
        var approvals: Int { entries.filter { $0.kind == .approval }.count }
    }

    private(set) var entries: [Entry] = []
    private let file: URL
    private var loaded = false

    private init() {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        file = folder.appendingPathComponent("action-log.jsonl")
    }

    func add(_ text: String, app: String?, ok: Bool, session: String?, caller: String? = nil,
             kind: Entry.Kind? = nil, detail: String? = nil, why: String? = nil) {
        load()
        let entry = Entry(at: Date(), text: text, app: app, ok: ok, session: session, caller: caller, kind: kind, detail: detail, why: why)
        entries.append(entry)
        if entries.count > Self.keep + Self.slack { trim(); return }
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file, options: .atomic)
        }
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        entries = data.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        if entries.count > Self.keep + Self.slack { trim() }
    }

    /// Drops the oldest entries and writes the file again, whole.
    private func trim() {
        entries = Array(entries.suffix(Self.keep))
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            guard let line = try? encoder.encode(entry) else { continue }
            data.append(line); data.append(0x0A)
        }
        try? data.write(to: file, options: .atomic)
    }

    /// The entries of one run between two moments, oldest first (a chat's task, for its details).
    func entries(session: String?, from: Date, to: Date) -> [Entry] {
        load()
        return entries.filter { $0.at >= from && $0.at <= to && (session == nil || $0.session == session) }
    }

    /// `entries` (newest first) by day, each day's entries gathered into runs.
    static func days(_ entries: [Entry]) -> [(day: Date, runs: [Run])] {
        var days: [(day: Date, runs: [Run])] = []
        let calendar = Calendar.current
        for entry in entries {
            let day = calendar.startOfDay(for: entry.at)
            if days.last?.day != day { days.append((day, [])) }
            let d = days.count - 1
            if let last = days[d].runs.last, last.session == entry.session, last.caller == entry.caller, entry.session != nil {
                days[d].runs[days[d].runs.count - 1].entries.append(entry)
            } else {
                days[d].runs.append(Run(id: entry.id, session: entry.session, caller: entry.caller, entries: [entry]))
            }
        }
        return days
    }
}

/// Agents › Activity Log: every action and approval, newest first, by day and by run. A run opens to
/// its steps; the filters narrow it to approvals, failures or one agent; a tap opens the run's chat.
struct ActionLogView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var openSession: (String) -> Void
    private var log: ActionLog { ActionLog.shared }

    enum Show: String, CaseIterable, Identifiable {
        case all, approvals, failed
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .all: "All"
            case .approvals: "Approvals"
            case .failed: "Failed"
            }
        }
    }

    @State private var show = Show.all
    /// nil: everyone. "": Poki's own chat. Otherwise an outside agent's name.
    @State private var who: String?
    @State private var search = ""
    @State private var shownDays = 7
    @State private var open: Set<UUID> = []

    private var filtering: Bool { show != .all || who != nil || !search.isEmpty }

    private var matching: [ActionLog.Entry] {
        let words = search.trimmingCharacters(in: .whitespaces)
        return log.entries.reversed().filter { entry in
            switch show {
            case .all: break
            case .approvals: if entry.kind != .approval { return false }
            case .failed: if entry.ok { return false }
            }
            if let who, (entry.caller ?? "") != who { return false }
            if words.isEmpty { return true }
            return [entry.text, ActivityWords.label(entry.text), entry.app, entry.detail, entry.caller].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    private var agents: [String] {
        var seen: Set<String> = []
        return log.entries.reversed().compactMap { $0.caller }.filter { seen.insert($0).inserted }
    }

    var body: some View {
        let days = ActionLog.days(matching)
        List {
            if !log.entries.isEmpty {
                Section {
                    Picker("Show", selection: $show) {
                        ForEach(Show.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            if log.entries.isEmpty {
                ContentUnavailableView("No Actions Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Every tap, swipe and keystroke Poki makes on this iPhone is listed here, whoever asked for it."))
                    .listRowBackground(Color.clear)
            } else if days.isEmpty {
                ContentUnavailableView("Nothing Matches", systemImage: "line.3.horizontal.decrease.circle",
                                       description: Text("No entry fits these filters."))
                    .listRowBackground(Color.clear)
            }
            ForEach(days.prefix(shownDays), id: \.day) { day, runs in
                Section(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(AppLocalization.locale))) {
                    ForEach(runs) { run in
                        // A filtered log is a plain list; otherwise a run of several steps folds into one row.
                        if filtering || run.entries.count == 1 {
                            ForEach(run.entries) { entry in line(entry, in: run) }
                        } else {
                            DisclosureGroup(isExpanded: Binding(get: { open.contains(run.id) },
                                                                set: { if $0 { open.insert(run.id) } else { open.remove(run.id) } })) {
                                ForEach(run.entries) { entry in line(entry, in: run) }
                            } label: {
                                header(run)
                            }
                            .contextMenu { menu(run) }
                        }
                    }
                }
            }
            if days.count > shownDays {
                Section {
                    Button("Show Earlier", systemImage: "clock.arrow.circlepath") { shownDays += 14 }
                }
            }
            if !log.entries.isEmpty {
                Section {} footer: {
                    Text("Poki keeps its latest \(ActionLog.keep) entries on this iPhone. Entries can’t be deleted by hand.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(AppLocalization.text("Activity Log"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: Text("Search"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Asked By", selection: $who) {
                        Text("Everyone").tag(String?.none)
                        Text("Poki").tag(String?.some(""))
                        ForEach(agents, id: \.self) { Text(verbatim: $0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filter", systemImage: who == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .onAppear { log.load() }
    }

    private func title(_ run: ActionLog.Run) -> String {
        run.session.flatMap { SessionStore.shared.session($0)?.name } ?? run.caller ?? "Poki"
    }

    @ViewBuilder private func menu(_ run: ActionLog.Run) -> some View {
        if let id = run.session, SessionStore.shared.session(id) != nil {
            Button("Open Chat", systemImage: "bubble.left") { openSession(id) }
        }
        Button("Copy", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = run.entries.reversed().map(\.line).joined(separator: "\n")
        }
    }

    @ViewBuilder private func line(_ entry: ActionLog.Entry, in run: ActionLog.Run) -> some View {
        // A row whose run is gone is plain text, not a disabled button: iOS fades a disabled
        // button's whole label, which left most of the log close to invisible.
        Group {
            if let id = entry.session, SessionStore.shared.session(id) != nil {
                Button { openSession(id) } label: { row(entry) }.foregroundStyle(Color(.label))
            } else {
                row(entry)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.line }
        }
    }

    private func badge(_ caller: String?, ok: Bool, approval: Bool) -> some View {
        // Who asked for it: the agent's badge, or Poki's own.
        Group {
            if let caller { CallerBadge(name: caller, size: 28) } else { PokiAvatar(size: 28) }
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: approval ? (ok ? "checkmark.shield.fill" : "xmark.shield.fill") : (ok ? "checkmark.circle.fill" : "xmark.circle.fill"))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ok ? Color.green : Color.red)
                .background(Circle().fill(Color(.systemBackground)).padding(-1))
                .offset(x: 3, y: 3)
        }
    }

    private func header(_ run: ActionLog.Run) -> some View {
        let count = run.entries.count
        var parts = [AppLocalization.text(LocalizedStringResource("\(count) entries"))]
        if run.failed > 0 { parts.append(AppLocalization.text(LocalizedStringResource("\(run.failed) failed"))) }
        if run.approvals > 0 { parts.append(AppLocalization.text(LocalizedStringResource("\(run.approvals) approvals"))) }
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            badge(run.caller, ok: run.failed == 0, approval: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title(run)).foregroundStyle(Color(.label)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                Text(verbatim: parts.joined(separator: ", ")).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 4)
            if let first = run.entries.first {
                Text(first.at, style: .time).font(.footnote).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
            }
        }
    }

    private func row(_ entry: ActionLog.Entry) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            badge(entry.caller, ok: entry.ok, approval: entry.kind == .approval)
            VStack(alignment: .leading, spacing: 2) {
                Text(ActivityWords.label(entry.text)).foregroundStyle(Color(.label)).lineLimit(typeSize.isAccessibilitySize || !entry.ok ? nil : 2)
                if let detail = entry.detail {
                    Text(verbatim: detail).font(.footnote).foregroundStyle(entry.ok ? Color(.secondaryLabel) : Color.orange).lineLimit(typeSize.isAccessibilitySize || !entry.ok ? nil : 2)
                }
                let context = [AppName.display(entry.app), entry.session.flatMap { SessionStore.shared.session($0)?.name }].compactMap { $0 }.joined(separator: ", ")
                if !context.isEmpty {
                    Text(context).font(.footnote).foregroundStyle(Color(.secondaryLabel)).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                }
            }
            Spacer(minLength: 4)
            Text(entry.at, style: .time).font(.footnote).monospacedDigit().foregroundStyle(Color(.secondaryLabel))
        }
    }
}
