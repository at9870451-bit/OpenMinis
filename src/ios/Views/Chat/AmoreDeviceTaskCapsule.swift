import Foundation
import SwiftUI
import AmoreDeviceKit

/// Converts an ACTUAL assistant device_control tool block into a small step
/// card. It never infers execution from the shortcut text or a model promise.
@MainActor
struct AmoreDeviceTaskCapsule: View {
    @ObservedObject var block: AssistantBlock

    /// device_control is represented as .shellTool(command: "device_control")
    /// by the host's existing SSE and history conversion. Do not treat an
    /// arbitrary shell tool containing the word "launch" as a phone action.
    static func isDeviceTool(_ block: AssistantBlock) -> Bool {
        if case .shellTool(let command) = block.kind { return command == "device_control" }
        return false
    }

    private var call: [String: Any]? {
        guard let raw = block.toolInputArgs, let data = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private var action: String? { call?["action"] as? String }

    private var launched: [String] {
        guard #available(iOS 18.0, *) else { return [] }
        return AmoreCapsuleApps.requestedLaunches(deviceToolArguments: block.toolInputArgs)
    }

    /// A launch in JSON is only intent. The actual tool result may reject the
    /// request or stop awaiting the owner even if a launch was requested.
    private var completed: Bool {
        guard case .success = block.toolStatus, action == "do" else { return false }
        let reply = block.content.lowercased()
        return !reply.contains("not_sent:") && !reply.contains("no device action was executed")
            && !reply.contains("waiting for owner input")
            && !reply.contains("waiting for device execution/result")
    }

    private var state: String {
        switch block.toolStatus {
        case .streaming, .running: return "In progress"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        // A successful do response proves the device call returned, not that
        // SpringBoard/target app stayed foreground or the task is complete.
        case .success: return completed ? "Action returned" : "No confirmed launch"
        case nil: return "Pending"
        }
    }

    private var symbol: String {
        switch block.toolStatus {
        case .success: return completed ? "checkmark.circle.fill" : "questionmark.circle"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        default: return "circle.dotted.circle"
        }
    }

    var body: some View {
        // Fits inside the existing 36pt ToolCapsuleView row, retaining its
        // detail sheet, search highlights, stop button and folding behavior.
        HStack(spacing: 5) {
            if let id = launched.last {
                // Rendering a task must not synchronously ask UIKit for another
                // app's icon while the phone core is launching that app.
                AmoreFastAppIcon(appName: id, size: 20)
            } else {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 13)).frame(width: 20, height: 20)
            }
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(completed ? Color.green : Color.secondary)
        }
        .accessibilityLabel(state)
        .accessibilityIdentifier("device.task.step")
    }
}
