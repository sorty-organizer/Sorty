import Foundation

public extension NotificationCenter {
    @discardableResult
    func addMainActorObserver(
        forName name: Notification.Name,
        object: Any? = nil,
        queue: OperationQueue? = .main,
        using block: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: name, object: object, queue: queue) { _ in
            Task { @MainActor in
                block()
            }
        }
    }
}