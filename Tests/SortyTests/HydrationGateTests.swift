import XCTest
import SortyFileSystem

@MainActor
final class HydrationGateTests: XCTestCase {
    func testSecondJoinSharesTheInFlightRead() async {
        let gate = HydrationGate<Int>()
        var starts = 0
        let first = gate.join { starts += 1; return Task { 7 } }
        let second = gate.join { starts += 1; return Task { 9 } }
        let firstValue = await first.task.value
        let secondValue = await second.task.value
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(firstValue, 7)
        XCTAssertEqual(secondValue, 7)
        XCTAssertTrue(gate.isCurrent(first.generation))
    }

    func testInvalidateMakesCapturedGenerationStaleAndAllowsFreshRead() async {
        let gate = HydrationGate<Int>()
        let first = gate.join { Task { 1 } }
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(first.generation))

        let second = gate.join { Task { 2 } }
        let value = await second.task.value
        XCTAssertEqual(value, 2)
        XCTAssertTrue(gate.isCurrent(second.generation))
    }

    func testFinishAllowsALaterRead() async {
        let gate = HydrationGate<Int>()
        _ = gate.join { Task { 1 } }
        gate.finish()
        let again = gate.join { Task { 3 } }
        let value = await again.task.value
        XCTAssertEqual(value, 3)
    }
}
