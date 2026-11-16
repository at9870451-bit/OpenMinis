import Foundation
import SwiftUI
import os.log

private let logger = AppLogger(category: "BrowserHistory")

// MARK: - History Entry

struct BrowserHistoryEntry: Identifiable, Codable {
    let id: UUID
    let url: String
    let title: String
    let timestamp: Date

    init(url: String, title: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.timestamp = timestamp
    }

    /// Display domain extracted from the URL.
    var domain: String {
        URL(string: url).flatMap(\.host) ?? url
    }
}

// MARK: - History Store

@MainActor
final class BrowserHistoryStore: ObservableObject {
    static let shared = BrowserHistoryStore()

    @Published private(set) var entries: [BrowserHistoryEntry] = []

    /// How many days of history to retain.
    private static let retentionDays = 7

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MinisChat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("browser_history.json")
    }

    private init() {
        load()
    }

    /// Record a page visit. Deduplicates consecutive visits to the same URL.
    func record(url: String, title: String) {
        // Skip blank/empty URLs
        guard !url.isEmpty, url != "about:blank" else { return }

        // Deduplicate: don't add if the most recent entry has the same URL
        if let last = entries.first, last.url == url { return }

        let entry = BrowserHistoryEntry(url: url, title: title)
        entries.insert(entry, at: 0)
        prune()
        save()
    }

    /// Remove all history.
    func clearAll() {
        entries.removeAll()
        save()
        logger.info("Browser history cleared")
    }

    /// Entries grouped by day (most recent first), filtered to retention window.
    var groupedByDay: [(date: Date, entries: [BrowserHistoryEntry])] {
        let calendar = Calendar.current
        let cutoff = calendar.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        let recent = entries.filter { $0.timestamp >= cutoff }
        let grouped = Dictionary(grouping: recent) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }
        return grouped.sorted { $0.key > $1.key }
            .map { (date: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: Self.storeURL, options: .atomic)
        } catch {
            logger.error("Failed to save browser history: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: Self.storeURL.path) else { return }
        do {
            let data = try Data(contentsOf: Self.storeURL)
            let decoder = JSONDecoder()
            entries = try decoder.decode([BrowserHistoryEntry].self, from: data)
            let before = entries.count
            prune()
            if entries.count != before { save() }
            logger.info("Loaded \(self.entries.count) history entries")
        } catch {
            logger.error("Failed to load browser history: \(error.localizedDescription)")
        }
    }

    /// Remove entries older than retention window.
    private func prune() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -Self.retentionDays, to: Date()) ?? Date()
        entries.removeAll { $0.timestamp < cutoff }
    }
}

// MARK: - History View

struct BrowserHistoryView: View {
    @ObservedObject var historyStore: BrowserHistoryStore
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            Group {
                if historyStore.entries.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .pokiScreen()
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !historyStore.entries.isEmpty {
                        Button("Clear", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Clear Browsing History?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("Clear All History", role: .destructive) {
                    historyStore.clearAll()
                }
            } message: {
                Text("This will remove all browsing history from the past 7 days.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(PokiTheme.secondaryText.opacity(0.75))
            Text("No History")
                .font(.headline)
                .foregroundStyle(PokiTheme.primaryText)
            Text("Pages you visit will appear here for 7 days.")
                .font(.subheadline)
                .foregroundStyle(PokiTheme.secondaryText.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var historyList: some View {
        List {
            ForEach(historyStore.groupedByDay, id: \.date) { group in
                Section {
                    ForEach(group.entries) { entry in
                        Button {
                            onSelect(entry.url)
                            dismiss()
                        } label: {
                            historyRow(entry)
                        }
                        .listRowBackground(PokiTheme.surface)
                        .listRowSeparatorTint(PokiTheme.divider)
                    }
                } header: {
                    Text(dayLabel(group.date))
                        .foregroundStyle(PokiTheme.secondaryText)
                }
            }
        }
        .listStyle(.insetGrouped)
        .pokiScreen()
    }

    private func historyRow(_ entry: BrowserHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 14))
                .foregroundStyle(PokiTheme.secondaryText)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title.isEmpty ? entry.domain : entry.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PokiTheme.primaryText)
                    .lineLimit(1)

                Text(entry.url)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PokiTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer()

            Text(timeLabel(entry.timestamp))
                .font(.system(size: 11))
                .foregroundStyle(PokiTheme.secondaryText.opacity(0.75))
        }
        .contentShape(Rectangle())
    }

    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
