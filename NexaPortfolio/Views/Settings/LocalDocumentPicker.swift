import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Uses the native UIKit document picker in copy mode. This is more reliable
/// than SwiftUI's fileImporter with some Files providers and keeps selected
/// documents readable after the picker is dismissed.
struct LocalDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let allowsMultipleSelection: Bool
    let onSelection: ([URL]) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: contentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: LocalDocumentPicker

        init(parent: LocalDocumentPicker) {
            self.parent = parent
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            parent.onSelection(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

struct StagedDocuments {
    let directory: URL
    let urls: [URL]
}

enum LocalDocumentStager {
    static func stage(_ sourceURLs: [URL]) throws -> StagedDocuments {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NexaPortfolioImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            let copiedURLs = try sourceURLs.enumerated().map { index, sourceURL in
                let hasSecurityAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                let fileName = sourceURL.lastPathComponent.isEmpty
                    ? "document-\(index + 1)"
                    : sourceURL.lastPathComponent
                let destinationURL = directory
                    .appendingPathComponent("\(index)-\(fileName)")
                let data = try Data(contentsOf: sourceURL)
                try data.write(to: destinationURL, options: .atomic)
                return destinationURL
            }
            return StagedDocuments(directory: directory, urls: copiedURLs)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    static func remove(_ documents: StagedDocuments) {
        try? FileManager.default.removeItem(at: documents.directory)
    }
}
