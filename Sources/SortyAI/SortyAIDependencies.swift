import Synchronization

@_exported import SortyFileSystem
@_exported import SortyModels

/// Typed, content-free pipe events. Core installs the sink only with telemetry consent.
public enum AIPipeDiagnostics {
    public enum Operation: String, Sendable { case modelList, generation }
    public enum Phase: String, Sendable { case started, completed, failed }
    public typealias Sink = @Sendable (Operation, Phase, Int32?) -> Void
    private static let sink = Mutex<Sink?>(nil)

    public static func configure(_ handler: Sink?) {
        sink.withLock { $0 = handler }
    }

    static func record(_ operation: Operation, _ phase: Phase, errorCode: Int32? = nil) {
        let handler = sink.withLock { $0 }
        handler?(operation, phase, errorCode)
    }
}
