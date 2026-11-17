import SwiftUI
import VisionKit

/// Scans the pairing code Poki Setup shows on the computer (a `poki://pairing?…` QR code) with the
/// system's data scanner, so the pairing file arrives without the Camera app or AirDrop.
struct PairingScanner: UIViewControllerRepresentable {
    var found: (URL) -> Void

    @MainActor static var available: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: UIViewControllerRepresentableContext<Self>) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: UIViewControllerRepresentableContext<Self>) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) { scanner.stopScanning() }

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (URL) -> Void
        private var done = false
        init(found: @escaping (URL) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let code) in items {
                guard !done, let text = code.payloadStringValue, let url = URL(string: text), url.scheme == "poki", url.host() == "pairing" else { continue }
                done = true
                scanner.stopScanning()
                found(url)
                return
            }
        }
    }
}

/// The scanner in a sheet, with Cancel.
struct PairingScannerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PairingScanner { url in
                _ = model.open(link: url)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle(AppLocalization.text("Scan Pairing Code"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("Point the camera at the code Poki Setup shows on your computer.")
                    .font(.footnote).foregroundStyle(Color(.secondaryLabel))
                    .multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity).background(.bar)
            }
        }
    }
}
