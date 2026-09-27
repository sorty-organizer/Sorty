#if DEBUG && SORTY_HOT_RELOAD
import Combine
import Foundation
import SwiftUI
import InjectionLite

@MainActor
private final class SortyInjectionObserver: @MainActor ObservableObject {
    static let shared = SortyInjectionObserver()

    let objectWillChange = ObservableObjectPublisher()
    private var injectionSubscription: AnyCancellable?

    private init() {
        injectionSubscription = NotificationCenter.default
            .publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }
}

/// Invalidates a SwiftUI value when InjectionLite loads an updated implementation.
/// Only hot-reload builds participate in SwiftUI's dynamic-property update pass.
@propertyWrapper @MainActor
public struct SortyHotReload: DynamicProperty {
    public struct Observation: Sendable {
        fileprivate init() {}
    }

    @ObservedObject private var observer = SortyInjectionObserver.shared

    public init() {}

    public var wrappedValue: Observation {
        _ = observer
        return Observation()
    }
}
#else
/// Keeps view declarations source-compatible without enrolling production views
/// in SwiftUI's dynamic-property update pass.
@propertyWrapper
public struct SortyHotReload {
    public struct Observation: Sendable {
        fileprivate init() {}
    }

    public init() {}

    public var wrappedValue: Observation {
        Observation()
    }
}
#endif
