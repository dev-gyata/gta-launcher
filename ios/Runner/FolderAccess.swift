import Flutter
import UIKit
import UniformTypeIdentifiers

/// The Local source on iOS (channel "playgta5/storage"). The system folder picker returns a security-scoped URL: readable by path
/// (dart:io) while access is held, and kept across launches as a bookmark. The app's Documents folder is also shown in the Files app
/// and Finder (Info.plist: UIFileSharingEnabled, LSSupportsOpeningDocumentsInPlace), so the game data can be copied there instead.
final class FolderAccess: NSObject, UIDocumentPickerDelegate {
  static let channelName = "playgta5/storage"
  private var pending: FlutterResult?
  /// The folder whose access is held (released when another one is picked).
  private var held: URL?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFolder":
      pickFolder(result)
    case "resolveFolder":
      guard let base64 = call.arguments as? String, let data = Data(base64Encoded: base64) else { return result(nil) }
      result(resolve(data))
    case "documentsFolder":
      let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("game")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      result(dir.path)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func pickFolder(_ result: @escaping FlutterResult) {
    guard pending == nil, let root = Self.topViewController() else { return result(nil) }
    pending = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    root.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return finish(nil) }
    hold(url)
    let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    finish(["path": url.path, "bookmark": bookmark?.base64EncodedString() as Any])
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }

  private func finish(_ value: Any?) {
    pending?(value)
    pending = nil
  }

  /// A saved bookmark back to a readable path: [path, refreshed bookmark or nil], or nil when the folder is gone or access was refused.
  private func resolve(_ data: Data) -> [Any]? {
    var stale = false
    guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale), hold(url) else { return nil }
    let refreshed = stale ? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))?.base64EncodedString() : nil
    return [url.path, refreshed as Any]
  }

  @discardableResult
  private func hold(_ url: URL) -> Bool {
    if held == url { return true }
    held?.stopAccessingSecurityScopedResource()
    held = nil
    // false for folders that need no scope (inside the app's own container): still readable
    let scoped = url.startAccessingSecurityScopedResource()
    if scoped { held = url }
    return scoped || FileManager.default.isReadableFile(atPath: url.path)
  }

  private static func topViewController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }
}
