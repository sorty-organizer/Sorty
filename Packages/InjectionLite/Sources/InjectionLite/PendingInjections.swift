// Sorty modification to InjectionLite. See SORTY.md for provenance.
#if DEBUG || !SWIFT_PACKAGE
/// Confined to the file watcher's run loop. Process.waitUntilExit() can pump
/// that run loop while an injection is active, delivering more save callbacks.
/// Keep those saves pending until the current compile, load and sweep finish.
final class PendingInjections {
    private var sources: [String] = []
    private var isDraining = false

    func submit(_ changedSources: [String], inject: (String) -> Void) {
        for source in changedSources where !sources.contains(source) {
            sources.append(source)
        }
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while !sources.isEmpty {
            // Remove before compiling so a save of this file during compilation
            // schedules one more pass with its latest contents.
            let source = sources.removeFirst()
            inject(source)
        }
    }
}
#endif
