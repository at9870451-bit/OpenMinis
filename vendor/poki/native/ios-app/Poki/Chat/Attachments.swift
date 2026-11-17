import ImageIO
import PDFKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo or a PDF added to a message from the message field's plus menu. The model reads `images`;
/// the strip over the message field and the sent message show `thumbnail`.
struct ChatAttachment: Identifiable, Equatable {
    enum Kind: Equatable { case photo, pdf(name: String), text(name: String) }
    let id = UUID()
    var kind: Kind
    /// JPEG, a small square-ish picture for the field and the bubble.
    var thumbnail: Data
    /// JPEG for the model: the photo, or the PDF's first pages, one picture each.
    var images: [Data]
    var textContent: String? = nil

    var isPDF: Bool {
        if case .pdf = kind { return true }
        return false
    }
}

struct ChatTextDocument: Codable, Equatable {
    let name: String
    let content: String

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file)
    }

    var modelText: String {
        let filename = name.components(separatedBy: .newlines).joined(separator: " ")
        let longestRun = content.split(whereSeparator: { $0 != "~" }).map(\.count).max() ?? 0
        let fence = String(repeating: "~", count: max(3, longestRun + 1))
        return "Attached file: \(filename)\n\(fence)\n\(content)\n\(fence)"
    }
}

struct ChatTextDocumentChip: View {
    let document: ChatTextDocument

    var body: some View {
        DisclosureGroup {
            Text(verbatim: document.content)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(verbatim: document.name).lineLimit(1)
                    Text(verbatim: document.sizeLabel).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "doc.text")
            }
        }
        .padding(10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Turns what the owner picked into an attachment. Pictures go to the model as JPEG at most 1568
/// pixels on the longer side (larger ones are scaled down by the providers anyway); a PDF goes as
/// pictures of its first four pages, so every model that reads screenshots reads it.
enum AttachmentReader {
    enum Failure: Error { case unsupported, unreadable, tooLarge, invalidUTF8 }

    static let modelSide = 1568
    static let thumbnailSide = 240
    static let pdfPages = 4
    static let maxTextBytes = 100_000
    static let fileTypes: [UTType] = [.image, .pdf, .json, .plainText]
        + ["md", "markdown"].compactMap { UTType(filenameExtension: $0) }

    static func photo(_ data: Data) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let full = jpeg(source, side: modelSide, quality: 0.82),
              let small = jpeg(source, side: thumbnailSide, quality: 0.7) else { throw Failure.unreadable }
        return ChatAttachment(kind: .photo, thumbnail: small, images: [full])
    }

    static func photo(_ image: UIImage) throws -> ChatAttachment {
        guard let data = image.jpegData(compressionQuality: 0.9) else { throw Failure.unreadable }
        return try photo(data)
    }

    /// Reads a picture, PDF, or a bounded UTF-8 document from Files.
    static func file(_ url: URL) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if ["json", "md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bytes = Data()
            while bytes.count <= maxTextBytes,
                  let chunk = try handle.read(upToCount: maxTextBytes + 1 - bytes.count),
                  !chunk.isEmpty {
                bytes.append(chunk)
            }
            guard bytes.count <= maxTextBytes else { throw Failure.tooLarge }
            guard let text = String(data: bytes, encoding: .utf8) else { throw Failure.invalidUTF8 }
            return ChatAttachment(kind: .text(name: url.lastPathComponent), thumbnail: Data(), images: [], textContent: text)
        }
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) { return try pdf(url) }
        guard type.conforms(to: .image) else { throw Failure.unsupported }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return try photo(data)
    }

    private static func pdf(_ url: URL) throws -> ChatAttachment {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw Failure.unreadable }
        let pages = (0..<min(pdfPages, document.pageCount)).compactMap { document.page(at: $0) }
        let images = pages.compactMap { page -> Data? in
            let box = page.bounds(for: .mediaBox).size
            let scale = CGFloat(modelSide) / max(box.width, box.height, 1)
            return page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox).jpegData(compressionQuality: 0.8)
        }
        guard let first = images.first, let source = CGImageSourceCreateWithData(first as CFData, nil),
              let small = jpeg(source, side: thumbnailSide, quality: 0.7) else { throw Failure.unreadable }
        return ChatAttachment(kind: .pdf(name: url.deletingPathExtension().lastPathComponent), thumbnail: small, images: images)
    }

    private static func jpeg(_ source: CGImageSource, side: Int, quality: Double) -> Data? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Simulator test runs only: `SIMCTL_CHILD_POKI_TEST_ATTACHMENT=<file>` names a picture or a PDF that
/// the message field starts with, as if picked from the plus menu (the simulator has no camera and
/// an empty photo library).
@MainActor
enum TestAttachment {
    private static var taken = false

    static func take() -> ChatAttachment? {
        guard !taken, let path = ProcessInfo.processInfo.environment["POKI_TEST_ATTACHMENT"] else { return nil }
        taken = true
        do {
            let item = try AttachmentReader.file(URL(fileURLWithPath: path))
            AppLog.shared.add("chat", "test attachment: \(item.images.count) picture(s), \(item.images.map(\.count).reduce(0, +)) bytes")
            return item
        } catch {
            AppLog.shared.add("chat", "test attachment unreadable: \(error)")
            return nil
        }
    }
}
#endif

// MARK: Over the message field and in the conversation

/// The photos and PDFs picked for the next message, over the message field (board 定稿 06): each a
/// 72-point picture with rounded corners and a small dark button on its corner that takes it off.
struct AttachmentStrip: View {
    var attachments: [ChatAttachment]
    var remove: (ChatAttachment) -> Void
    @ScaledMetric(relativeTo: .body) private var thumbnailSide = 72.0
    @ScaledMetric(relativeTo: .caption2) private var removeMarkSide = 18.0

    private var markSide: CGFloat { min(30, removeMarkSide) }
    private var cornerOffset: CGFloat { (44 - markSide) / 2 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { item in
                    Group {
                        if case .text = item.kind {
                            VStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                Text(verbatim: item.label).font(.caption2).lineLimit(1)
                                if let content = item.textContent {
                                    Text(verbatim: ChatTextDocument(name: item.label, content: content).sizeLabel)
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(4)
                            .frame(width: min(104, thumbnailSide), height: min(104, thumbnailSide))
                            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                        } else {
                            AttachmentThumb(data: item.thumbnail, side: min(104, thumbnailSide), pdf: item.isPDF)
                        }
                    }
                        .overlay(alignment: .topTrailing) { removeButton(item) }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(Text(item.label))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 4).padding(.top, cornerOffset).padding(.bottom, 2)
            // Room for the corner buttons, which stand out of the pictures.
            .padding(.trailing, cornerOffset)
        }
        .scrollClipDisabled()
        .accessibilityIdentifier("composer.attachments")
    }

    private func removeButton(_ item: ChatAttachment) -> some View {
        Button { remove(item) } label: {
            Image(systemName: "xmark")
                .font(.system(size: markSide / 2, weight: .bold)).foregroundStyle(.white)
                .frame(width: markSide, height: markSide)
                .background(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.85), in: .circle)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2).padding(-2))
                // The touch is larger than the mark.
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .offset(x: cornerOffset, y: -cornerOffset)
        .accessibilityLabel(Text("Remove"))
        .accessibilityIdentifier("composer.attachment.remove")
        .accessibilityShowsLargeContentViewer {
            Label("Remove", systemImage: "xmark")
        }
    }
}

/// One attachment's small picture, over the message field and in a sent message.
struct AttachmentThumb: View {
    var data: Data
    var side: CGFloat
    var pdf = false
    @ScaledMetric(relativeTo: .caption2) private var pdfLabelSize = 9.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 16 / 72, style: .continuous)
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color(.secondarySystemFill)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.95), lineWidth: 1))
        .shadow(color: Color(red: 24 / 255, green: 56 / 255, blue: 120 / 255).opacity(0.12), radius: 6, y: 4)
        .overlay(alignment: .bottomLeading) {
            if pdf {
                Text(verbatim: "PDF").font(.system(size: min(18, pdfLabelSize), weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(.systemRed), in: .capsule)
                    .padding(6)
            }
        }
    }
}

extension ChatAttachment {
    /// What VoiceOver says for it.
    var label: String {
        switch kind {
        case .photo: AppLocalization.text(LocalizedStringResource("Photo"))
        case .pdf(let name), .text(let name): name
        }
    }
}

/// The camera, for Take Photo: UIKit's picker, the system camera SwiftUI can present.
struct CameraPicker: UIViewControllerRepresentable {
    var done: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }
    }
}
