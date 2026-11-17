import SwiftUI

// Backtape's page (issue 356): the library of tiles (BacktapeLibrary.swift) behind the lock, with
// recording and settings in the bar. This file holds the grouping the tiles are built from, the
// page itself and Backtape Settings.

// MARK: Grouping

/// A stretch of the timeline: a part of a day, or a block of 10 minutes.
struct HistorySpan: Identifiable, Hashable {
    let start: Date
    let end: Date
    /// Newest first, with only the start of each text.
    let entries: [HistoryEntry]
    var id: Date { start }

    /// Apps used in it, the most read first.
    var apps: [String] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.app.isEmpty { counts[entry.app, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    @MainActor var title: String {
        let names = apps.prefix(3).map(HistoryNames.app)
        return names.isEmpty ? AppLocalization.text("Screen Text") : names.joined(separator: ", ")
    }

    /// Screen titles seen, oldest first, and when the tree gave none, the first line read.
    var summary: String {
        var seen: [String] = []
        for entry in entries.reversed() {
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !seen.contains(title) { seen.append(title) }
            if seen.count == 5 { break }
        }
        if !seen.isEmpty { return seen.joined(separator: ", ") }
        return entries.last?.text.split(separator: "\n").prefix(2).joined(separator: " ") ?? ""
    }
}

@MainActor
enum HistoryNames {
    static func app(_ id: String) -> String { AppIconStore.name(id) ?? id }

    static func status(_ status: HistoryCapture.Status) -> String {
        switch status {
        case .off: "Off"
        case .waiting: "Waiting to Read"
        case .reading: "Reading"
        case .finished: "Finished"
        case .stopped: "Stopped"
        case .locked: "iPhone Locked"
        case .task: "Waiting for an Agent's Task"
        case .noConnection: "No Local Connection"
        case .notPaired: "Not Paired"
        }
    }

    static func record(_ kind: String) -> String {
        if let status = HistoryCapture.Status(rawValue: kind) { return self.status(status) }
        switch kind {
        case "leftOut": return "Left Out an App"
        case "cleared": return "History Cleared"
        default: return kind
        }
    }
}

// MARK: The page

struct HistoryPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @ObservedObject private var lock = HistoryLock.shared
    @State private var layout = BacktapeLayout()
    @State private var loaded = false

    var body: some View {
        Group {
            // The whole page opens only after Face ID, Touch ID or Poki's PIN.
            if !lock.unlocked {
                BacktapeLockScreen()
            } else if layout.isEmpty {
                List {
                    if loaded {
                        Section {
                            Text("Nothing is kept yet. Start a read in Testing Options, use another app, then come back.").foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                BacktapeLibrary(layout: layout)
            }
        }
        .navigationTitle(AppLocalization.text("Screen History"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if lock.unlocked {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { HistoryGate { BacktapeSettingsPage().settingsPage() } } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel(Text("Screen History Settings"))
                }
            }
        }
        .task(id: capture.changes) { await load() }
    }

    private func load() async {
        let entries = await HistoryStore.shared.recent()
        layout = BacktapeLayout.build(entries)
        loaded = true
    }
}

// MARK: Settings

/// Everything that sets Backtape up, on a page of its own: the switch, pause, access times, apps,
/// how long tape is kept, the reminder, the lock and the record.
struct BacktapeSettingsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var size: (entries: Int, bytes: Int64) = (0, 0)
    @State private var clearing = false

    var body: some View {
        List {
            Section {
                NavigationLink { HistoryGate { HistoryPermissionsPage().settingsPage() } } label: {
                    LabeledContent("Permissions") {
                        Text(LocalizedStringKey(capture.listMode == .exclude ? "Exclude These Apps" : "Include Only These Apps"))
                    }
                }
            }
            Section {
                Picker("Keep History For", selection: $capture.retentionDays) {
                    Text("3 Days").tag(3)
                    Text("1 Week").tag(7)
                    Text("2 Weeks").tag(14)
                    Text("1 Month").tag(30)
                }
                Picker("Keep Summaries For", selection: $capture.summaryDays) {
                    Text("As Long as History").tag(0)
                    Text("1 Month").tag(30)
                    Text("3 Months").tag(90)
                    Text("1 Year").tag(365)
                }
                Picker("Storage Limit", selection: $capture.storageMegabytes) {
                    Text(verbatim: "100 MB").tag(100)
                    Text(verbatim: "200 MB").tag(200)
                    Text(verbatim: "500 MB").tag(500)
                    Text(verbatim: "1 GB").tag(1024)
                    Text(verbatim: "2 GB").tag(2048)
                }
            } footer: {
                Text("Whichever limit is reached first starts erasing the oldest history in layers. Screen structure goes first, then screen text, and the summaries last.")
            }
            Section {
                NavigationLink { HistoryGate { HistoryLockSettings().settingsPage() } } label: { Text("Screen History Lock") }
                NavigationLink { HistoryGate { HistoryRecordPage().settingsPage() } } label: { Text("Observing Record") }
                LabeledContent("Storage Used") {
                    Text(verbatim: "\(ByteCountFormatter.string(fromByteCount: size.bytes, countStyle: .file))")
                }
                LabeledContent("Reads Kept") { Text(verbatim: "\(size.entries)").monospacedDigit() }
            }
            Section {
                Button("Clear History", role: .destructive) { clearing = true }
            }
        }
        .navigationTitle(AppLocalization.text("Screen History Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: capture.changes) { size = await HistoryStore.shared.size() }
        .confirmationDialog("Clear History", isPresented: $clearing, titleVisibility: .visible) {
            Button("Last 10 Minutes", role: .destructive) { Task { await capture.clear(last: 600) } }
            Button("Last Hour", role: .destructive) { Task { await capture.clear(last: 3600) } }
            Button("Last Day", role: .destructive) { Task { await capture.clear(last: 86_400) } }
            Button("Everything", role: .destructive) { Task { await capture.clearEverything() } }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: Privacy controls

/// Which apps are read: every app but the ones listed, or only the ones listed.
private struct HistoryPermissionsPage: View {
    @ObservedObject private var capture = HistoryCapture.shared
    @State private var seen: [String] = []
    @State private var search = ""

    /// Poki's own screens are always left out, so Poki is never listed.
    private var chosen: [String] { (capture.listMode == .exclude ? capture.excluded : capture.included).filter { !HistoryCapture.isPoki($0) } }

    /// Apps that can be added: the ones read so far, the suggested ones, then every app Poki knows.
    private var candidates: [String] {
        var all: [String] = []
        let suggested = capture.listMode == .exclude ? HistoryCapture.suggested : []
        for app in suggested + seen + KnownApps.all.map(\.id) where !all.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            all.append(app)
        }
        let open = all.filter { app in !HistoryCapture.isPoki(app) && !chosen.contains { $0.caseInsensitiveCompare(app) == .orderedSame } }
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return open }
        return open.filter { $0.localizedCaseInsensitiveContains(wanted) || HistoryNames.app($0).localizedCaseInsensitiveContains(wanted) }
    }

    private func add(_ app: String) {
        if capture.listMode == .exclude { capture.excluded.append(app) } else { capture.included.append(app) }
    }

    private func remove(_ app: String) {
        if capture.listMode == .exclude { capture.excluded.removeAll { $0 == app } } else { capture.included.removeAll { $0 == app } }
    }

    var body: some View {
        List {
            Section {
                Picker("Apps", selection: $capture.listMode) {
                    Text("Exclude These Apps").tag(HistoryCapture.ListMode.exclude)
                    Text("Include Only These Apps").tag(HistoryCapture.ListMode.include)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(LocalizedStringKey(capture.listMode == .exclude
                    ? "Poki never keeps what these apps show. A read of one is dropped before anything is stored."
                    : "Poki keeps only what these apps show. Every other app is left out."))
            }
            Section {
                ForEach(chosen, id: \.self) { app in
                    HStack(spacing: 12) {
                        AppIconView(app: app, size: 28)
                        Text(verbatim: HistoryNames.app(app))
                    }
                    .swipeActions { Button("Remove", role: .destructive) { remove(app) } }
                }
                if chosen.isEmpty { Text("No Apps").foregroundStyle(.secondary) }
            } header: {
                Text(LocalizedStringKey(capture.listMode == .exclude ? "Excluded" : "Included"))
            }
            Section {
                ForEach(candidates.prefix(60), id: \.self) { app in
                    Button { add(app) } label: {
                        HStack(spacing: 12) {
                            AppIconView(app: app, size: 28)
                            Text(verbatim: HistoryNames.app(app)).foregroundStyle(Color(.label))
                            Spacer()
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
            } header: {
                Text("Add App")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always))
        .navigationTitle(AppLocalization.text("Permissions"))
        .navigationBarTitleDisplayMode(.inline)
        .task { seen = await HistoryStore.shared.apps() }
    }
}

/// When reading was on, paused, blocked or left an app out.
private struct HistoryRecordPage: View {
    @State private var records: [HistoryRecord] = []

    private func detail(_ record: HistoryRecord) -> String {
        switch record.kind {
        case "leftOut": HistoryNames.app(record.detail)
        default: ""
        }
    }

    var body: some View {
        List {
            ForEach(records) { record in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(HistoryNames.record(record.kind)))
                        if !detail(record).isEmpty { Text(verbatim: detail(record)).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(verbatim: record.at.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(AppLocalization.locale)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if records.isEmpty { Text("Nothing Yet").foregroundStyle(.secondary) }
        }
        .navigationTitle(AppLocalization.text("Observing Record"))
        .navigationBarTitleDisplayMode(.inline)
        .task { records = await HistoryStore.shared.records() }
    }
}

// MARK: Testing Options

/// General › Testing Options › Screen History: the only place a read starts.
struct HistoryTestingSection: View {
    @ObservedObject var capture = HistoryCapture.shared
    @Environment(AppModel.self) private var model
    @State private var minutes = HistoryCapture.runMinutes[0]

    var body: some View {
        Section {
            NavigationLink { HistoryPage().settingsPage() } label: { Text("Open Screen History") }
            LabeledContent("Status") {
                if let ends = capture.ends, capture.isRunning {
                    Text(timerInterval: Date()...max(Date(), ends), countsDown: true).monospacedDigit()
                } else {
                    Text(LocalizedStringKey(HistoryNames.status(capture.status)))
                }
            }
            Button("Read in 10 Seconds") { capture.start(model: model) }
                .disabled(capture.isRunning)
            Picker("Short Run", selection: $minutes) {
                ForEach(HistoryCapture.runMinutes, id: \.self) { Text("\($0) min").tag($0) }
            }
            .disabled(capture.isRunning)
            Button("Start Short Run") { capture.start(minutes: minutes, model: model) }
                .disabled(capture.isRunning)
            Button("Stop", role: .destructive) { capture.stop() }
                .disabled(!capture.isRunning)
        } header: {
            Text("Screen History")
        } footer: {
            Text("An experiment. Poki reads the text of the app in front only after you start here, and keeps it on this iPhone. Leave Poki after starting. A run ends when its time is up, when the iPhone locks, or when iOS ends Poki's time in the background. Password fields are left out, and nothing is sent anywhere.")
        }
    }
}
