import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The steps of a long job, like Software Update's progress list.
struct StepsView: View {
    var steps: [StepItem]

    var body: some View {
        ForEach(steps) { s in
            HStack(alignment: .top, spacing: 10) {
                icon(s)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title)
                        .foregroundStyle(s.state == .done ? .secondary : .primary)
                    if let f = s.fraction, s.state == .running {
                        ProgressView(value: f).progressViewStyle(.linear).frame(maxWidth: 280)
                    }
                    if let d = s.detail, !d.isEmpty {
                        Text(d)
                            .font(.callout)
                            .foregroundStyle(s.state == .failed ? .red : .secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(s.notes.enumerated()), id: \.offset) { _, n in
                        Text(n).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder private func icon(_ s: StepItem) -> some View {
        switch s.state {
        case .running: ProgressView().controlSize(.small)
        case .waiting: Image(systemName: "hand.tap.fill").foregroundStyle(.orange)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

/// A crisp QR code from Core Image.
struct QRCode: View {
    var text: String
    var size: CGFloat = 180

    var body: some View {
        Group {
            if let image = Self.image(for: text) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .padding(10)
        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("QR code")
    }

    static func image(for text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A row with a status symbol on the right, for Forms.
struct StatusRow: View {
    enum Tone { case good, warn, bad, neutral }
    var title: String
    var value: String
    var tone: Tone = .neutral

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value).foregroundStyle(.secondary)
                switch tone {
                case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warn: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .neutral: EmptyView()
                }
            }
        }
    }
}

/// A big centered message for empty pages.
struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
    }
}

/// "0.2.2-320" as people read it, "0.2.2 (320)", the way Poki shows its own version. Update
/// checks keep comparing the plain form.
func displayVersion(_ v: String) -> String {
    guard let dash = v.lastIndex(of: "-") else { return v }
    let build = v[v.index(after: dash)...]
    guard !build.isEmpty, build.allSatisfy(\.isNumber) else { return v }
    return "\(v[..<dash]) (\(build))"
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

func relativeDays(_ r: Record) -> String {
    if r.isExpired { return "Expired" }
    let d = r.daysLeft
    switch d {
    case ..<1: return "Expires today"
    case 1: return "1 day left"
    default: return "\(d) days left"
    }
}
