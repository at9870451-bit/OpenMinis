import AppKit
import SwiftUI

@main
struct PokiSetupApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Poki Setup", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, idealWidth: 900, minHeight: 540, idealHeight: 640)
                .tint(.pokiBlue)
                .task { model.start() }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 900, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Poki") {
                Button("Set Up an iPhone") { model.page = .setup }.keyboardShortcut("1")
                Button("iPhones") { model.page = .phones }.keyboardShortcut("2")
                Button("Apple Account") { model.page = .account }.keyboardShortcut("3")
                Divider()
                Button("Renew Signatures Now") { Task { await model.renewDue() } }
                Divider()
                Button("Copy Prompt for Your Agent") { Task { await model.copyAgentPrompt() } }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .tint(.pokiBlue)
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: "iphone.gen3.badge.play")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps the app in the menu bar, so it can keep Poki signed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = ProcessInfo.processInfo.environment["POKI_SETUP_SNAPSHOT_DIR"], !dir.isEmpty {
            Task { @MainActor in await Snapshots.run(into: URL(fileURLWithPath: dir)) }
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.records.isEmpty {
            Text("No iPhones set up yet")
        } else {
            ForEach(model.records) { r in
                Text("\(r.phoneName): \(r.isExpired ? "expired" : "\(max(r.daysLeft, 0)) days left")")
            }
        }
        Divider()
        Button("Open Poki Setup") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Renew Now") { Task { await model.renewDue() } }
        Button("Copy Prompt for Your Agent") { Task { await model.copyAgentPrompt() } }
            .disabled(model.records.isEmpty)
        Divider()
        Button("Quit Poki Setup") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

extension Color {
    /// Poki's blue, as on poki.app and in the iPhone app.
    static let pokiBlue = Color(red: 0 / 255, green: 119 / 255, blue: 253 / 255)
}
