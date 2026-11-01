import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// UIKit document picker in copy mode: the system copies the file into our sandbox before
/// handing over the URL, which sidesteps both the security-scope dance and the SwiftUI
/// `.fileImporter` modifier that refuses to present inside complex navigation hierarchies.
struct DocumentPicker: UIViewControllerRepresentable {
    var onPick: ([URL]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        controller.allowsMultipleSelection = true
        controller.shouldShowFileExtensions = true
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            AppLog.shared.log("UIKit 选择器返回 \(urls.count) 个文件")
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            AppLog.shared.log("UIKit 选择器被取消")
        }
    }
}
