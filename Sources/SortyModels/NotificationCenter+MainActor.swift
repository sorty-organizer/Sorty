import Foundation

public extension NotificationCenter {
    @discardableResult
    func addMainActorObserver(
        forName name: Notification.Name,
        object: Any? = nil,
        // NOTE: Defaults to nil rather than .main: the block always hops to
        // the main actor itself, so main-queue delivery adds nothing, and an
        // explicit OperationQueue.main default trips module-interface
        // emission under -experimental-skip-non-inlinable-function-bodies.
        queue: OperationQueue? = nil,
        using block: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: name, object: object, queue: queue) { _ in
            Task { @MainActor in
                block()
            }
        }
    }
}