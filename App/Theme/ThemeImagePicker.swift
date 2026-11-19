import SwiftUI
import UIKit
import UniformTypeIdentifiers
import PhotosUI

/// 回调只在主线程调用；用盒子把它们带过后台加载回调。
private final class PickerCallbacks: @unchecked Sendable {
    let picker: ThemePhotoPicker
    init(_ picker: ThemePhotoPicker) { self.picker = picker }
}

/// 从系统相册选择一张图片（无需相册权限）。选中后返回图片原始数据。
struct ThemePhotoPicker: UIViewControllerRepresentable {
    let onPick: (Data) -> Void
    let onCancel: () -> Void
    var onFailure: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: ThemePhotoPicker
        private var finished = false
        init(parent: ThemePhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            guard let provider = results.first?.itemProvider else {
                parent.onCancel()
                return
            }
            let box = PickerCallbacks(parent)
            let type = provider.registeredTypeIdentifiers.first {
                UTType($0)?.conforms(to: .image) == true
            } ?? UTType.image.identifier
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                DispatchQueue.main.async {
                    if let data, !data.isEmpty {
                        box.picker.onPick(data)
                    } else {
                        box.picker.onFailure("无法读取所选图片，请换一张试试。")
                    }
                }
            }
        }
    }
}

/// File-provider access and image validation are delegated to the owned asset store.
struct ThemeImagePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.loadViewIfNeeded()
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.title = "选择主题图片"
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        var onCancel: () -> Void
        private var finished = false
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !finished else { return }; finished = true
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard !finished else { return }; finished = true; onCancel()
        }
    }
}
