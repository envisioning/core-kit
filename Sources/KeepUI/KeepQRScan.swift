import KeepKit
import SwiftUI
import Vision

#if canImport(UIKit)
  import UIKit
  import VisionKit
#else
  import AppKit
  import UniformTypeIdentifiers
#endif

// Getting an `otpauth://` URI in without typing it. The phone points its
// camera at the QR the site shows; the Mac takes a picture of it (a
// screenshot, a photo) and reads the code out. Both hand back the text and
// nothing else; the editor decides what it means.

/// Reads a QR code out of an image with Vision. Nil when there is none.
func keepDecodeQR(in cgImage: CGImage) -> String? {
  let request = VNDetectBarcodesRequest()
  request.symbologies = [.qr]
  let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
  try? handler.perform([request])
  return request.results?.compactMap(\.payloadStringValue).first
}

#if os(iOS)
  /// The camera, looking for a QR. VisionKit's scanner: live, no capture
  /// session of our own, and it stops on the first code it sees.
  struct KeepQRCameraScanner: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
      DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
      let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true
      )
      scanner.delegate = context.coordinator
      try? scanner.startScanning()
      return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound, dismiss: { dismiss() }) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
      let onFound: (String) -> Void
      let dismiss: () -> Void
      private var delivered = false
      init(onFound: @escaping (String) -> Void, dismiss: @escaping () -> Void) {
        self.onFound = onFound
        self.dismiss = dismiss
      }
      func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        guard !delivered else { return }
        for item in addedItems {
          if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
            delivered = true
            dataScanner.stopScanning()
            onFound(payload)
            dismiss()
            return
          }
        }
      }
    }
  }

  /// The photo library, for a screenshot of the QR.
  struct KeepQRImagePicker: UIViewControllerRepresentable {
    let onFound: (String?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
      let picker = UIImagePickerController()
      picker.sourceType = .photoLibrary
      picker.delegate = context.coordinator
      return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
      let onFound: (String?) -> Void
      init(onFound: @escaping (String?) -> Void) { self.onFound = onFound }
      func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        let image = info[.originalImage] as? UIImage
        picker.dismiss(animated: true)
        onFound(image?.cgImage.flatMap(keepDecodeQR(in:)))
      }
      func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
      }
    }
  }
#endif

#if os(macOS)
  /// An open panel for a screenshot or photo of the QR.
  @MainActor
  func keepPickQRImage() -> String?? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.allowsMultipleSelection = false
    panel.message = "Choose a picture of the QR code"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    guard let image = NSImage(contentsOf: url), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return .some(nil)
    }
    return .some(keepDecodeQR(in: cgImage))
  }

  /// A QR from the clipboard — a screenshot taken with ⌃⇧⌘4.
  @MainActor
  func keepReadQRFromPasteboard() -> String? {
    guard let image = NSImage(pasteboard: .general), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    return keepDecodeQR(in: cgImage)
  }
#endif
