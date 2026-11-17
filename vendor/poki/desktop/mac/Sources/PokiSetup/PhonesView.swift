import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PhonesView: View {
    @EnvironmentObject var model: AppModel
    @State private var forgetting: Record?

    var body: some View {
        Group {
            if model.records.isEmpty {
                EmptyState(symbol: "iphone.gen3", title: "No iPhones Yet", message: "iPhones you set up with Poki Setup appear here, with how long Poki stays signed.")
            } else {
                Form {
                    HeroSection {
                        PageHero(symbol: "iphone.gen3", title: "iPhones", subtitle: "Poki Setup renews Poki before it stops opening, every few hours while this Mac is on.")
                    }
                    ForEach(model.records) { r in section(r) }
                }
                .pokiPage()
            }
        }
        .confirmationDialog("Forget \(forgetting?.phoneName ?? "this iPhone")?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), presenting: forgetting) { r in
            Button("Forget", role: .destructive) { Task { await model.forget(udid: r.udid) } }
        } message: { _ in
            Text("Poki stays on the iPhone, but Poki Setup stops renewing it.")
        }
        .task { await model.refreshRecords() }
    }

    @ViewBuilder private func section(_ r: Record) -> some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3").font(.system(size: 28, weight: .light)).foregroundStyle(Color.pokiBlue).frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.phoneName).font(.headline)
                    Text("iOS \(r.ios) · Poki \(r.version) (\(r.build))").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                ExpiryBadge(record: r)
            }
            .padding(.vertical, 4)
            LabeledContent("Signed") { Text(Date(timeIntervalSince1970: TimeInterval(r.signedAt)).formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
            LabeledContent("Stays Signed Until") { Text(r.expires.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
            LabeledContent("Team") { Text(r.teamIsFree ? "\(r.teamName), free" : r.teamName).foregroundStyle(.secondary) }
            LabeledContent("Bundle ID") { Text(r.bundleId).foregroundStyle(.secondary).textSelection(.enabled) }
            if let e = r.lastError {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            if let steps = model.steps["renew"], !steps.isEmpty, model.busyJobs.contains("renew") {
                StepsView(steps: steps)
            }
            LabeledContent("Agent Memory") {
                HStack {
                    Button("Back Up…") { Task { await backup(r) } }
                    Button("Restore…") { Task { await restore(r) } }
                }
            }
            HStack {
                Button("Forget…", role: .destructive) { forgetting = r }
                Spacer()
                Button("Renew Now") {
                    Task {
                        do { try await model.renew(udid: r.udid) } catch { model.report(error) }
                    }
                }
                .pokiProminentButton()
                .disabled(model.busyJobs.contains("renew"))
            }
        }
    }
}

extension PhonesView {
    struct Saved: Decodable { var path: String; var bytes: Int }

    func backup(_ r: Record) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Save Backup Here"
        panel.message = "Poki Setup copies the agent's routines, notes and settings (no passwords) from \(r.phoneName)."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            let saved: Saved = try await model.bridge.call("backup_agent", ["udid": r.udid, "out_dir": dir.path])
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: saved.path)])
        } catch { model.report(error) }
    }

    func restore(_ r: Record) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Restore"
        panel.message = "Choose a Poki agent backup. Poki imports it the next time it opens."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            try await model.bridge.run("restore_agent", ["udid": r.udid, "file": file.path])
            model.banner = "The backup is on \(r.phoneName). Open Poki to import it."
        } catch { model.report(error) }
    }
}

struct ExpiryBadge: View {
    var record: Record

    var body: some View {
        let color: Color = record.isExpired ? .red : (record.daysLeft <= 2 ? .orange : .green)
        Text(relativeDays(record))
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}
