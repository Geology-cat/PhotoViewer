import XCTest
@testable import PhotoViewer_Legacy

final class SmokeTests: XCTestCase {
    func test起動できる() {
        XCTAssertNotNil(NSApplication.shared.delegate)
    }
}
