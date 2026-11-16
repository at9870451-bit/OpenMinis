import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// File mode accepts any Files-provider item so a ZIP tagged as public.data is
/// not greyed out. The archive's bytes, not the provider's UTI, determine validity.
struct AmorePluginDocumentPicker: UIViewControllerRepresentable {
    let folder: Bool
    let onSelection: (Result<URL, Error>) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: folder ? [.folder] : [.item], asCopy: !folder)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelection: (Result<URL, Error>) -> Void
        let onCancel: () -> Void
        init(onSelection: @escaping (Result<URL, Error>) -> Void, onCancel: @escaping () -> Void) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let first = urls.first else { onCancel(); return }
            onSelection(.success(first))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
