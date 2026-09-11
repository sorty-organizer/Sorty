import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import InjectionLite
#endif

final class PendingInjectionsTests: XCTestCase {
    func testSavesDuringLinkWaitDoNotReenterInjection() throws {
        let pending = PendingInjections()
        var processed: [String] = []
        var isInjecting = false
        var deliveredSave = false

        pending.submit(["A.swift", "B.swift"]) { source in
            XCTAssertFalse(isInjecting)
            isInjecting = true
            defer { isInjecting = false }
            processed.append(source)
            guard processed.count == 1 else { return }

            let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in
                deliveredSave = true
                pending.submit(["A.swift", "A.swift", "B.swift", "C.swift"]) { _ in
                    XCTFail("A nested save must wait for the active injection")
                }
            }
            defer { timer.invalidate() }
            // Reproduce the run-loop delivery in Process.waitUntilExit(), which
            // InjectionLite's linker invokes while its cache lock is held.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertTrue(deliveredSave)
            XCTAssertEqual(processed, ["A.swift"])
        }

        XCTAssertEqual(processed, ["A.swift", "B.swift", "A.swift", "C.swift"])
    }

    func testLaterBatchDrainsAfterPreviousBatchCompletes() {
        let pending = PendingInjections()
        var processed: [String] = []
        pending.submit([]) { processed.append($0) }
        pending.submit(["A.swift", "A.swift"]) { processed.append($0) }
        pending.submit(["A.swift", "B.swift"]) { processed.append($0) }
        XCTAssertEqual(processed, ["A.swift", "A.swift", "B.swift"])
    }
}
