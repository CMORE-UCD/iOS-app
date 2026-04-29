//
//  VideoPicker.swift
//  HandDetectionDemo
//
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct VideoPicker: UIViewControllerRepresentable {
    /// Returns picked video URL copied into app temp dir.
    /// Returns nil on cancel/failure.
    var completion: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            // Use document picker on Mac
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie])
            picker.allowsMultipleSelection = false
            picker.delegate = context.coordinator
            return picker
        } else {
            // Use photo picker on iPad
            var config = PHPickerConfiguration(photoLibrary: .shared())
            config.filter = .videos
            config.selectionLimit = 1
            config.preferredAssetRepresentationMode = .current

            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
        private let completion: (URL?) -> Void

        init(completion: @escaping (URL?) -> Void) {
            self.completion = completion
        }

        // MARK: - PHPickerViewControllerDelegate (iPad)
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let result = results.first else {
                completion(nil) // user cancelled
                return
            }

            let provider = result.itemProvider
            let typeId = UTType.movie.identifier

            guard provider.hasItemConformingToTypeIdentifier(typeId) else {
                completion(nil)
                return
            }

            provider.loadFileRepresentation(forTypeIdentifier: typeId) { url, error in
                if let error {
                    #if DEBUG
                    print("VideoPicker load error: \(error.localizedDescription)")
                    #endif
                    DispatchQueue.main.async { self.completion(nil) }
                    return
                }

                guard let sourceURL = url else {
                    DispatchQueue.main.async { self.completion(nil) }
                    return
                }

                self.copyToTemp(from: sourceURL)
            }
        }

        // MARK: - UIDocumentPickerDelegate (Mac)
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            controller.dismiss(animated: true)
            
            guard let sourceURL = urls.first else {
                completion(nil)
                return
            }

            // For document picker, file is already accessible
            copyToTemp(from: sourceURL)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            controller.dismiss(animated: true)
            completion(nil)
        }

        // MARK: - Helper
        private nonisolated func copyToTemp(from sourceURL: URL) {
            do {
                let tempDir = FileManager.default.temporaryDirectory
                let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
                let destURL = tempDir.appendingPathComponent("\(UUID().uuidString).\(ext)")

                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destURL)

                DispatchQueue.main.async {
                    self.completion(destURL)
                }
            } catch {
                #if DEBUG
                print("VideoPicker copy error: \(error.localizedDescription)")
                #endif
                DispatchQueue.main.async {
                    self.completion(nil)
                }
            }
        }
    }
}
