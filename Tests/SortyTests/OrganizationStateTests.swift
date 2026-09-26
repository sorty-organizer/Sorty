import XCTest
@testable import SortyLib

final class OrganizationStateTransitionRegressionTests: XCTestCase {
    func testScanningCanReturnReadyForEmptyScans() {
        XCTAssertTrue(OrganizationState.canTransition(from: .scanning, to: .ready))
    }
}
