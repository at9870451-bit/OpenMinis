import AppKit
import SwiftUI

/// CI only (`POKI_SETUP_SNAPSHOT_DIR`): walks every page in light and dark and saves a PNG of the
/// window, then quits. With `POKI_SETUP_DEMO=1` the pages show sample data instead of this Mac's.
@MainActor
enum Snapshots {
    static func run(into dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && !($0.className.contains("StatusBar")) }) else {
            print("snapshot: no window")
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 960, height: 680))
        window.center()
        guard let model = AppModel.current else {
            print("snapshot: no model")
            NSApp.terminate(nil)
            return
        }
        let tag = ProcessInfo.processInfo.environment["POKI_SETUP_DEMO"] == "1" ? "demo" : "live"
        for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: appearance)
            for page in Page.allCases {
                model.page = page
                try? await Task.sleep(for: .seconds(1.5))
                save(window, to: dir.appendingPathComponent("\(tag)-\(name)-\(page.rawValue).png"))
            }
        }
        print("snapshot: done")
        NSApp.terminate(nil)
    }

    private static func save(_ window: NSWindow, to url: URL) {
        // The real window, as the window server draws it (materials, title bar, shadows).
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {}
        if FileManager.default.fileExists(atPath: url.path) {
            print("snapshot: \(url.lastPathComponent)")
            return
        }
        // Fallback: AppKit's own drawing of the views (no window-server materials).
        if let view = window.contentView?.superview ?? window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: url)
                print("snapshot (drawn): \(url.lastPathComponent)")
            }
        }
    }
}
