import XCTest
@testable import SortyOrganizer
@testable import SortyLib
@testable import SortyCore

final class OrganizationStateTransitionRegressionTests: XCTestCase {
    func testScanningCanReturnReadyForEmptyScans() {
        XCTAssertTrue(OrganizationState.canTransition(from: .scanning, to: .ready))
    }
}
