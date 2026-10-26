import Foundation

/// A long-running export the UI can start, watch and cancel.
public protocol MediaJob: AnyObject {
    var onProgress: ((Double, String) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }
    /// Runs synchronously; call from a background queue. Throws JobCancelled when cancelled.
    func run() throws
    func cancel()
}

extension Transcoder: MediaJob {}
extension LosslessJoiner: MediaJob {}
