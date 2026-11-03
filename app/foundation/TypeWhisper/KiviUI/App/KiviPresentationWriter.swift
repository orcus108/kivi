import Foundation

/// FIFO disk writes keep the newest preference snapshot last, without blocking clicks.
final class KiviPresentationWriter: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.vedant.kivi.presentation", qos: .utility)
    func write(_ data: Data, to url: URL, completion: @escaping @MainActor @Sendable (Error?) -> Void) {
        Self.queue.async {
            let error: Error?
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                error = nil
            } catch let failure { error = failure }
            Task { @MainActor in completion(error) }
        }
    }
    // Called only at application termination, never during ordinary interaction.
    static func flush() { queue.sync {} }
}
